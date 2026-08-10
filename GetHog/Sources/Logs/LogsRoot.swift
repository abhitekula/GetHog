import GetHogKit
import GetHogUI
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

/// The complete security namespace in which a read response may publish.
/// Numeric project ids can repeat between hosts, and a replacement credential
/// invalidates work even when both host and project number stay unchanged.
struct ResourceRequestAuthority: Hashable, Sendable {
    let projectID: Int
    let region: PostHogRegion
    let authSessionID: UUID
}

/// Every value that changes the meaning of one Logs response.
struct LogsRequestDescriptor: Hashable, Sendable {
    let authority: ResourceRequestAuthority
    let window: LogsWindow
    let search: String
}

@MainActor
@Observable
final class LogsStore {
    /// The `limit` this screen sends with every `LogsQuery`, held here so the
    /// number in the request and the number the row count is measured against
    /// are the same one.
    static let limit = 100

    private(set) var state: ResourceAccessState = .loading
    private(set) var rows: [LogRow] = []
    private(set) var loadedAt: Date?
    private(set) var isLoading = false

    /// Rows PostHog returned, which is not `rows.count`: `LogRow.rows(from:)`
    /// drops what it cannot read, and a page one row short of its ceiling is
    /// indistinguishable from a page that was never full.
    private(set) var rowsReturned = 0

    /// Whether this window holds more lines than the page below.
    ///
    /// `LogsQuery` sends its own `limit`, so the reasoning recorded on
    /// `QueryResponse.isTruncated` applies: an envelope reports the cap PostHog
    /// chose, and says nothing about one the caller asked for. The row count is
    /// therefore the evidence at our own ceiling and the flag is OR'd in for a
    /// cap applied below it — the pattern `SessionTimelineStore` and
    /// `SchemaStore` are the worked examples of.
    ///
    /// `LogsQuery` is a query node rather than HogQL and may omit `hasMore`.
    /// Comparing the row count with the requested ceiling remains conservative,
    /// while an envelope flag is honored whenever it arrives.
    private(set) var isTruncated = false

    private var requestGeneration: UInt64 = 0
    private var currentRequest: LogsRequestDescriptor?
    private var inFlight: InFlight?

    private struct InFlight {
        let id: UUID
        let generation: UInt64
        let request: LogsRequestDescriptor
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    // Held here rather than in the view so a project switch or a pull-to-refresh
    // reuses whatever the reader last chose.
    var window: LogsWindow = .day {
        didSet {
            if window != oldValue { invalidateFilterAuthority() }
        }
    }
    var search = "" {
        didSet {
            if search != oldValue { invalidateFilterAuthority() }
        }
    }
    var problemsOnly = false

    var isEmpty: Bool { rows.isEmpty }

    /// The rows a VoiceOver rotor jumps between, in the order they are drawn.
    ///
    /// Derived from `visibleRows` rather than from `rows`: a rotor that offered
    /// a line the list is not currently showing would be a jump to nothing.
    var problemRows: [LogRow] { visibleRows.filter(\.severity.isProblem) }

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

    func invalidate() {
        requestGeneration &+= 1
        currentRequest = nil
        releaseInFlightWaiters()
        state = .loading
        rows = []
        rowsReturned = 0
        isTruncated = false
        loadedAt = nil
        isLoading = false
    }

    func load(client: PostHogClient, request: LogsRequestDescriptor) async {
        prepare(for: request)
        if inFlight?.request == request {
            await withCheckedContinuation { continuation in
                guard var active = inFlight, active.request == request else {
                    continuation.resume()
                    return
                }
                active.waiters.append(continuation)
                inFlight = active
            }
            return
        }

        let id = UUID()
        let generation = requestGeneration
        inFlight = InFlight(id: id, generation: generation, request: request)
        isLoading = true
        defer { completeInFlight(id: id) }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.logs(
                    projectID: request.authority.projectID,
                    dateFrom: request.window.rawValue,
                    search: request.search,
                    limit: Self.limit
                )
            )
            guard owns(id: id, generation: generation, request: request) else { return }
            rows = LogRow.rows(from: response)
            rowsReturned = response.rows.count
            isTruncated = response.isTruncated || rowsReturned >= Self.limit
            state = .resolved(rowCount: rows.count)
            loadedAt = Date()
        } catch {
            guard owns(id: id, generation: generation, request: request) else { return }
            state = ResourceAccessState(failure: error, resource: "logs", defaultScope: "logs:read")
        }
    }

    private func prepare(for request: LogsRequestDescriptor) {
        guard currentRequest != request else { return }
        requestGeneration &+= 1
        currentRequest = request
        releaseInFlightWaiters()
        state = .loading
        rows = []
        rowsReturned = 0
        isTruncated = false
        loadedAt = nil
    }

    private func invalidateFilterAuthority() {
        guard currentRequest != nil || inFlight != nil else { return }
        requestGeneration &+= 1
        currentRequest = nil
        releaseInFlightWaiters()
        state = .loading
        rows = []
        rowsReturned = 0
        isTruncated = false
        loadedAt = nil
        isLoading = false
    }

    private func owns(
        id: UUID,
        generation: UInt64,
        request: LogsRequestDescriptor
    ) -> Bool {
        inFlight?.id == id
            && generation == requestGeneration
            && currentRequest == request
    }

    private func completeInFlight(id: UUID) {
        guard inFlight?.id == id else { return }
        releaseInFlightWaiters()
        isLoading = false
    }

    private func releaseInFlightWaiters() {
        let waiters = inFlight?.waiters ?? []
        inFlight = nil
        for waiter in waiters { waiter.resume() }
    }
}

// MARK: - Root

struct LogsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = LogsStore()

    /// The open log line, held in `OpenDetails` rather than pushed as a value onto
    /// the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it, and a value on
    /// the host's stack goes when the host does.
    private var selection: Binding<LogRow?> {
        Binding(
            get: { openDetails[.logs] as? LogRow },
            set: { openDetails[.logs] = $0.map(AnyHashable.init) }
        )
    }

    private var requestAuthority: ResourceRequestAuthority? {
        guard
            let client = model.client,
            let projectID = model.projectID,
            let authSessionID = model.authSessionID
        else { return nil }
        return ResourceRequestAuthority(
            projectID: projectID,
            region: client.region,
            authSessionID: authSessionID
        )
    }

    var body: some View {
        @Bindable var store = store

        content
            .navigationTitle("Logs")
            .navigationDestination(item: selection) { LogDetailView(row: $0) }
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $store.search, prompt: "Search log messages")
            .onSubmit(of: .search) { Task { await load() } }
            .screenRefreshable { await load() }
            .onChange(of: requestAuthority, initial: true) { _, _ in store.invalidate() }
            .task(id: requestAuthority) { await load() }
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

            case .failed(let message) where !store.rows.isEmpty:
                VStack(spacing: 0) {
                    filterBar
                    SectionEmptyState(
                        text: "Couldn't refresh logs. \(message)",
                        systemImage: "exclamationmark.triangle",
                        actionTitle: "Try again"
                    ) { Task { await load() } }
                    .padding(.horizontal, Theme.Space.l)
                    list
                }
                .background(Theme.pageBackground)

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

    /// No scroll view around it, deliberately — the same correction `RendersRoot`
    /// records, arrived at from the other end.
    ///
    /// This bar used to ride a horizontal `ScrollView` so its controls could grow
    /// with Dynamic Type without being clipped. Reachable is not the same as
    /// legible: at AX5 the screenshot sweep caught the severity toggle scrolled
    /// almost entirely out of the bar, leaving a bare teal `!` glyph about 5px
    /// from the trailing edge with its word — the only thing that says what the
    /// control filters — off-screen and behind a gesture nothing announces.
    ///
    /// `GlassFilterBar` now stacks its controls past the accessibility threshold,
    /// which is what the scroll view was standing in for, so both controls are on
    /// screen with their labels intact and the list below is the only scroll view
    /// on the screen again.
    private var filterBar: some View {
        @Bindable var store = store

        return GlassFilterBar {
            Picker("Time range", selection: $store.window) {
                ForEach(LogsWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: store.window) { Task { await load() } }
            // Takes the row's slack so the toggle sits at the trailing edge, and
            // the whole line once the bar stacks.
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .background(Theme.pageBackground)
    }

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` displays it.
    private var list: some View {
        List(selection: selection) {
            Section {
                if store.visibleRows.isEmpty && !store.isLoading {
                    // Reached only by the client-side severity filter: the rows
                    // exist, none of them are problems. Saying so beats an empty
                    // list that looks like a failed load.
                    //
                    // But *which* rows matters, and this used to claim more than
                    // it could. The filter runs over the page in memory, and the
                    // page is the newest 100 lines of the window — so "no error
                    // or fatal lines in the last 24 hours" was a project-wide
                    // absence asserted from a recency slice, and a fatal at line
                    // 101 reads here as a clean bill of health. That is a wrong
                    // answer rather than a partial one, which is the whole point
                    // of the distinction: the sentence now scopes itself to what
                    // was actually read.
                    EmptyStateView(
                        title: "No problems in what was read",
                        systemImage: "checkmark.circle",
                        message: store.isTruncated
                            ? "None of the \(store.rowsReturned.formatted()) newest lines in the last \(store.window.title.lowercased()) are errors or fatals. This screen reads at most \(LogsStore.limit) lines and reached that ceiling, so older ones in the window went unread."
                            : "No error or fatal lines among the \(store.rowsReturned.formatted()) this window holds."
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
            } footer: {
                // The heading counts what is on screen, which is right for a
                // heading and is not an answer to "how much was logged". A log
                // viewer is read as a window onto everything in the period, and
                // a full page with nothing under it says the period held exactly
                // this — so when the page is full, the footer says what it is a
                // page of.
                //
                // Only when the ceiling was reached. `LIMIT 100` matching
                // eleven lines is the ordinary outcome of a quiet window, and
                // crying truncation over it would train the reader to ignore the
                // one notice that matters — the same reason the SQL console
                // stays silent about a limit its reader wrote.
                if store.isTruncated {
                    Text("The \(store.rowsReturned.formatted()) newest lines in the last \(store.window.title.lowercased()). This screen reads at most \(LogsStore.limit) and reached that ceiling, so the window holds more than these — narrow the range or search to see further back.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
        // The reason this screen earns a rotor and a short list would not: the
        // one thing anybody opens a log viewer to find is the failure, and the
        // "Errors only" toggle in the bar above is a *filter* — it throws away
        // the surrounding lines, which are the context that makes the failure
        // legible. A rotor is the same question asked without destroying the
        // answer: jump error to error, and swipe either way to read what
        // happened around it.
        //
        // Entry ids are `LogRow.id`, which is exactly the identity the `ForEach`
        // above uses, so each entry resolves to a row that is really on screen.
        .logsRotor(problems: store.problemRows)
    }

    private func load() async {
        guard let client = model.client, let authority = requestAuthority else {
            store.invalidate()
            return
        }
        await store.load(
            client: client,
            request: LogsRequestDescriptor(
                authority: authority,
                window: store.window,
                search: store.search
            )
        )
    }
}

// MARK: - Rotor

extension View {

    /// The logs list's rotor, as one named thing.
    ///
    /// Split out of `LogsRoot.list` so it can be applied to a list of real
    /// `LogRowView`s in a test and the rotor read back off the rendered tree.
    /// Demo mode carries no logs fixture, so the screen itself renders no rows
    /// there and cannot be measured; this is the declaration under test, called
    /// by the screen and by nothing else.
    func logsRotor(problems: [LogRow]) -> some View {
        accessibilityRotor(
            Text("Errors and fatals"),
            entries: problems,
            entryID: \.id,
            entryLabel: \.rotorLabel
        )
    }
}

// MARK: - Rotor labels

extension LogRow {

    /// What the rotor speaks for this line.
    ///
    /// Deliberately shorter than `LogRowView`'s own accessibility label: a rotor
    /// entry is read while the user is *scanning*, and the whole point of the
    /// jump is to hear enough to decide whether to stop. Severity leads because
    /// it is what the rotor is selecting on, then the service, then as much of
    /// the message as fits a spoken phrase.
    var rotorLabel: String {
        var parts = [severity.title]
        if let serviceName { parts.append(serviceName) }
        parts.append(body.rotorSnippet)
        return parts.joined(separator: ", ")
    }
}

extension String {

    /// The first line, capped, for a rotor entry.
    ///
    /// Log bodies and exception messages both arrive multi-line and unbounded;
    /// a rotor entry that reads a whole stack trace aloud is worse than no rotor
    /// at all, because the user cannot get out of it without listening to the
    /// end.
    var rotorSnippet: String {
        let firstLine = split(separator: "\n", maxSplits: 1).first.map(String.init) ?? self
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 90 else { return trimmed }
        return trimmed.prefix(90).trimmingCharacters(in: .whitespaces) + "…"
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
                        // A scope string PostHog named, not prose: measured at
                        // AX5 in a narrow chip, `zxx`-less text acquires a real
                        // hyphen at a case boundary — `UnhandledRejection` set as
                        // `Unhandled-` / `Rejection` — and nobody can tell an
                        // invented hyphen from one the scope contains. `zxx` is
                        // the ISO code for "no linguistic content".
                        .typesettingLanguage(Locale.Language(identifier: "zxx"))
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
                    // See `Theme.inkOnAccent`: a prominent button's default
                    // white label is 2.09:1 on the dark accent. **Not
                    // photographed** — the demo Logs screen renders its
                    // no-lines state, never the denied one, so this branch has
                    // no capture. Same construction as SQL's "Run", which does.
                    .foregroundStyle(Theme.inkOnAccent)
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
