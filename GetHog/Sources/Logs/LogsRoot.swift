import GetHogKit
import SwiftUI

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
        case .info: Theme.accent
        case .debug, .trace, .unknown: .secondary
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class LogsStore {
    private(set) var state: LogsState = .loading
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
            state = LogsState(failure: error)
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

        NavigationStack {
            content
                .navigationTitle("Logs")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $store.search, prompt: "Search log messages")
                .onSubmit(of: .search) { Task { await load() } }
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
        }
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
            case .denied, .missingScope:
                LogsLockedView(state: store.state) {
                    Task { await model.refreshCapabilities(); await load() }
                }

            case .failed(let message):
                ContentUnavailableView {
                    Label(store.state.headline, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }

            case .empty:
                VStack(spacing: 0) {
                    filterBar
                    ContentUnavailableView(
                        // Short on purpose: the title truncates to one line.
                        store.state.headline,
                        systemImage: "text.alignleft",
                        description: Text(emptyDescription)
                    )
                    .frame(maxHeight: .infinity)
                }
                .background(Theme.pageBackground)

            case .loading, .loaded:
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
    private var emptyDescription: String {
        var clauses = ["Nothing was logged in the last \(store.window.title.lowercased())"]
        if !store.search.isEmpty { clauses.append("matching “\(store.search)”") }
        if store.problemsOnly { clauses.append("at error or fatal severity") }
        return clauses.joined(separator: " ") + "."
    }

    private var filterBar: some View {
        @Bindable var store = store

        return ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.s) {
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
            }
            .padding(.horizontal, Theme.Space.l)
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
                    Text("No error or fatal lines in the last \(store.window.title.lowercased()).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.visibleRows) { row in
                        LogRowView(row: row)
                    }
                }
            } header: {
                Text("\(store.visibleRows.count) line\(store.visibleRows.count == 1 ? "" : "s")")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
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
    let state: LogsState
    var onRecheck: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(state.headline, systemImage: "lock")
        } description: {
            VStack(spacing: Theme.Space.s) {
                Text(state.detail)
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
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                StatusPill(text: row.severity.title, tint: row.severity.tint)

                Spacer(minLength: Theme.Space.s)

                if let timestamp = row.timestamp {
                    Text(timestamp, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Monospaced and selectable: a log line is something you copy into a
            // search box, and alignment carries meaning in structured output.
            Text(row.body)
                .font(.caption.monospaced())
                .lineLimit(6)
                .textSelection(.enabled)

            if row.serviceName != nil || row.traceID != nil {
                HStack(spacing: Theme.Space.m) {
                    if let service = row.serviceName {
                        Text(service)
                    }
                    if let traceID = row.traceID {
                        Text(traceID.prefix(12))
                            .font(.caption2.monospaced())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
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
