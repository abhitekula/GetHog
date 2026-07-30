import GetHogKit
import SwiftUI

/// The words the logs screen uses for its own subject.
let logsCopy = ResourceCopy(
    subject: "Logs",
    itemNoun: "log lines",
    emptyHint: "No log lines matched in this window."
)

/// The log viewer.
///
/// Like `TracingRoot`, this screen's *blocked* state is the one that has been
/// seen against the real API: this organisation has no `viewer` access to the
/// `logs` resource, and PostHog reports that as an HTTP 400 rather than a 403.
/// Left to a generic error path it would read as "GetHog sent a malformed
/// request" and send someone hunting for a bug in the client. So every state
/// here is named and explicit rather than inferred from an empty list, and the
/// denial is separated from a missing key scope because the two have different
/// fixes — an admin granting role access versus the user editing their own key.

// MARK: - Filters

/// Windows offered for a log search.
///
/// Short by default. Log volume dwarfs event volume, and every one of these
/// queries is billed against a rate-limit budget shared by the whole
/// organisation.
enum LogsWindow: String, CaseIterable, Identifiable, Hashable {
    case lastHour = "-1h"
    case sixHours = "-6h"
    case day = "-24h"
    case week = "-7d"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }
}

extension LogSeverity {
    /// Always paired with the severity's name — this is a pill with text in it,
    /// never a bare coloured dot.
    var tint: Color {
        switch self {
        case .fatal, .error: Theme.Status.critical
        case .warn: Theme.accentWarm
        case .info, .debug: Theme.accent
        case .trace, .unknown: .secondary
        }
    }

    /// A second, non-colour encoding of severity, so the shape of a row's glyph
    /// separates a fatal from an info before its pill has been read.
    var glyph: String {
        switch self {
        case .fatal: "exclamationmark.octagon.fill"
        case .error: "exclamationmark.triangle.fill"
        case .warn: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        case .debug, .trace: "ladybug.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class LogsStore {
    private(set) var state: ResourceAccessState = .loading
    private(set) var rows: [LogRow] = []
    private(set) var loadedAt: Date?
    private(set) var isLoading = false

    // Held here rather than in the view so a project switch or a pull-to-refresh
    // reuses whatever the reader last chose.
    var window: LogsWindow = .day
    var search = ""
    var problemsOnly = false

    var isEmpty: Bool { rows.isEmpty }

    /// Severity filtering is done on the client.
    ///
    /// The alternative is a fresh `/query/` call every time the toggle moves,
    /// against an organisation-wide budget, to re-fetch a subset of rows already
    /// in memory. Narrowing what is already here costs nothing.
    var visibleRows: [LogRow] {
        let filtered = problemsOnly ? rows.filter(\.severity.isProblem) : rows
        return filtered.sorted { lhs, rhs in
            // Newest first, which is what a log reader expects; severity breaks
            // ties so a fatal never hides under an info from the same instant.
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?) where l != r: return l > r
            default: return lhs.severity.rank < rhs.severity.rank
            }
        }
    }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.logs(
                    projectID: projectID,
                    dateFrom: window.rawValue,
                    search: search
                )
            )
            rows = LogRow.rows(from: response)
            state = .resolved(rowCount: rows.count)
            loadedAt = Date()
        } catch {
            state = ResourceAccessState(failure: error, resource: "logs", defaultScope: "logs:read")
            rows = []
        }
    }
}

// MARK: - Root

struct LogsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = LogsStore()

    var body: some View {
        @Bindable var store = store

        content
            .navigationTitle("Logs")
            .navigationDestination(for: LogRow.self) { LogDetailView(row: $0) }
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $store.search, prompt: "Search log messages")
            .onSubmit(of: .search) { Task { await load() } }
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Approximate, and deliberately so: there is no `.logs` capability,
            // and logs ride the same `/query/` endpoint, so the events probe is
            // the closest honest gate. It cannot see the resource-level denial
            // below, which is why that is handled separately.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else {
            switch store.state {
            case _ where store.state.isBlocked:
                LogsLockedView(state: store.state) {
                    Task { await model.refreshCapabilities(); await load() }
                }

            case .failed(let message):
                EmptyStateView(
                    title: store.state.headline(logsCopy),
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )

            case .empty:
                VStack(spacing: 0) {
                    filterBar
                    EmptyStateView(
                        // Short on purpose: the title truncates to one line.
                        title: store.state.headline(logsCopy),
                        systemImage: "text.alignleft",
                        message: emptyDescription
                    )
                    .frame(maxHeight: .infinity)
                }
                .background(Theme.pageBackground)

            default:
                VStack(spacing: 0) {
                    filterBar
                    list
                }
                .background(Theme.pageBackground)
            }
        }
    }

    /// Names the filters that are narrowing the result, so "nothing here" is not
    /// mistaken for "nothing was logged" when it is really "nothing matched".
    /// Reports the absence, and — when nothing is narrowing the window — says
    /// what the screen would hold.
    ///
    /// The unfiltered case used to stop at "Nothing was logged", which tells a
    /// first-time reader neither what a log line is here nor what would make one
    /// appear. Notebooks, Actions and Pipelines all answer both; this now does
    /// too. With a filter applied the sentence stays as it was: the filter is the
    /// explanation, and a product blurb underneath it would only be in the way.
    private var emptyDescription: String {
        var clauses = ["Nothing was logged in the last \(store.window.title.lowercased())"]
        if !store.search.isEmpty { clauses.append("matching “\(store.search)”") }
        if store.problemsOnly { clauses.append("at error or fatal severity") }
        let sentence = clauses.joined(separator: " ") + "."
        guard clauses.count == 1 else { return sentence }
        return sentence + " Logs are the lines your own services send to PostHog over OpenTelemetry, carrying a severity, a service name and the trace they belong to."
    }

    /// The glass bar rides a horizontal scroll view because its controls grow
    /// with Dynamic Type and would otherwise be clipped rather than reachable.
    private var filterBar: some View {
        @Bindable var store = store

        return ScrollView(.horizontal) {
            GlassFilterBar {
                Picker("Time range", selection: $store.window) {
                    ForEach(LogsWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: store.window) { Task { await load() } }

                Toggle(isOn: $store.problemsOnly) {
                    Label("Errors only", systemImage: "exclamationmark.octagon")
                }
                .toggleStyle(.button)
                .font(.footnote)
                // Measured 84.3×14.3pt: wide enough, and a third of the height a
                // fingertip needs — `.footnote` set the line height and the
                // button chrome added almost nothing to it. The identical
                // control on Tracing measured the same. A bordered style fills
                // the size it is offered, so this grows the visible capsule to
                // the standard control height without touching its font or tint.
                .minimumHitTarget()
            }
            .padding(.vertical, Theme.Space.s)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground)
    }

    private var list: some View {
        List {
            Section {
                if store.visibleRows.isEmpty && !store.isLoading {
                    // Reached only by the client-side severity filter: the rows
                    // exist, none of them are problems. Saying so beats an empty
                    // list that looks like a failed load.
                    EmptyStateView(
                        title: "No problems in this window",
                        systemImage: "checkmark.circle",
                        message: "No error or fatal lines in the last \(store.window.title.lowercased())."
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.visibleRows) { row in
                        NavigationLink(value: row) { LogRowView(row: row) }
                            .listRowBackground(
                                Theme.cardBackground
                                    .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                    .padding(.vertical, 1)
                            )
                            .listRowSeparator(.hidden)
                    }
                }
            } header: {
                SectionLabel(
                    text: "\(store.visibleRows.count) line\(store.visibleRows.count == 1 ? "" : "s")",
                    systemImage: "text.alignleft"
                )
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Locked

/// The locked state, named.
///
/// Deliberately the same treatment as `TracingLockedView`: same lock symbol,
/// same monospaced resource chip, same "re-check" action rather than "try
/// again", because both screens are reporting the same class of problem and
/// should be recognisable as such. It is distinct from `LockedCapabilityView`
/// because the fix differs — a missing *scope* is repaired by the user editing
/// their own API key, a denied *resource* needs an organisation admin.
struct LogsLockedView: View {
    let state: ResourceAccessState
    var onRecheck: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(state.headline(logsCopy), systemImage: "lock")
        } description: {
            VStack(spacing: Theme.Space.s) {
                Text(state.detail(logsCopy))
                if case .denied(let resource) = state {
                    Text(resource)
                        .font(.footnote.monospaced())
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.xs)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                        .accessibilityLabel("Denied resource: \(resource)")
                }
            }
        } actions: {
            if let onRecheck {
                Button("Re-check access", action: onRecheck)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Rows

struct LogRowView: View {
    let row: LogRow

    var body: some View {
        DataRow(
            glyph: row.severity.glyph,
            tint: row.severity.tint,
            title: row.serviceName ?? "Unknown service",
            subtitle: row.body,
            footnote: provenance,
            // Alignment carries meaning in structured output, so the line keeps
            // code type here as well as on the detail screen.
            isSubtitleMonospaced: true,
            // Three, against the shared default of one. A log message *is* the
            // row's content rather than a caption under it, and one line turned
            // every error into an unreadable fragment. Three is where a list
            // still scans; the rest is behind the row.
            subtitleLineLimit: 3,
            accessory: .pill(row.severity.title, row.severity.tint)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// When it happened and which trace it belongs to — the two things needed to
    /// find the same line again in the web console.
    private var provenance: String {
        var parts: [String] = []
        if let timestamp = row.timestamp {
            parts.append(timestamp.formatted(.relative(presentation: .named)))
        }
        if let traceID = row.traceID {
            parts.append(String(traceID.prefix(12)))
        }
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = [row.severity.title, row.body]
        if let service = row.serviceName { parts.append("service \(service)") }
        if let timestamp = row.timestamp {
            parts.append(timestamp.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: ", ")
    }
}
