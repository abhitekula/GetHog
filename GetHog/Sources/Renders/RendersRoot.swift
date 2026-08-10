import GetHogKit
import GetHogUI
import SwiftUI

/// The render library: session recordings PostHog has turned into video files.
///
/// The tab says "Renders" rather than "Exports" for the reason `RecordingExport`
/// records — this endpoint represents session-recording videos, not chart CSVs
/// or dashboard PDFs. A screen called "Exports" would imply the wrong resource.
///
/// Read-only. GetHog lists and plays a render; queuing one is a write this app
/// does not offer, which is why the empty state points at PostHog rather than at a
/// button here.

/// The words this screen uses for its own subject.
let rendersCopy = ResourceCopy(
    subject: "Renders",
    itemNoun: "renders",
    emptyHint: "Nobody has exported a session recording to video in this project yet."
)

// MARK: - State presentation

extension RecordingExportState {

    /// A shape as well as a tint.
    ///
    /// Expired and failed are the two states most easily confused, and the
    /// difference matters more than any other pair here: an expired render was
    /// produced correctly and cleaned up on schedule, while a failed one never
    /// produced a file and never will. Neither is allowed to rest on colour, so
    /// each carries its own glyph and each row states its status as a word.
    var glyph: String {
        switch self {
        case .ready: "play.rectangle.fill"
        case .pending: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        case .expired: "clock.badge.xmark"
        }
    }

    /// Expiry is warm, not critical: it is the documented end of a retention
    /// window, not something that went wrong. Painting it the same red as a
    /// crashed render would make a tidy library look like a wall of errors.
    var tint: Color {
        switch self {
        case .ready: Theme.accent
        case .pending: .secondary
        case .failed: Theme.Status.critical
        case .expired: Theme.accentWarm
        }
    }

    /// Whether a video can be fetched for this render at all.
    ///
    /// The one question the play button asks. `.failed` and `.expired` are both
    /// false here for the same reason and by different routes, which is why the
    /// screen explains them separately.
    var isPlayable: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Filter

/// Narrowing by state, on the client.
///
/// `GET /exports/` takes no state filter, and the rows are already in memory —
/// re-requesting them narrowed would spend a request from an organisation-wide
/// budget to receive a subset of what is on screen.
enum RenderFilter: String, CaseIterable, Identifiable, Hashable {
    case all, ready, rendering, failed, expired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .ready: "Ready"
        case .rendering: "Rendering"
        case .failed: "Failed"
        case .expired: "Expired"
        }
    }

    func matches(_ state: RecordingExportState) -> Bool {
        switch (self, state) {
        case (.all, _): true
        case (.ready, .ready): true
        case (.rendering, .pending): true
        case (.failed, .failed): true
        case (.expired, .expired): true
        default: false
        }
    }
}

// MARK: - Store

/// Every value that changes which render library a response belongs to.
struct RendersRequestDescriptor: Hashable, Sendable {
    let authority: ResourceRequestAuthority
}

@MainActor
@Observable
final class RendersStore {
    private(set) var state: ResourceAccessState = .loading
    private(set) var exports: [RecordingExport] = []
    private(set) var loadedAt: Date?
    private(set) var isLoading = false
    private var requestGeneration: UInt64 = 0
    private var currentRequest: RendersRequestDescriptor?
    private var inFlight: InFlight?

    private struct InFlight {
        let id: UUID
        let generation: UInt64
        let request: RendersRequestDescriptor
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// The instant the whole screen is rendered against.
    ///
    /// Every state on this screen is a function of a date — `state(asOf:)` takes
    /// one precisely so the answer is reproducible — and a row that read the clock
    /// for itself could disagree with the row above it, or with its own detail
    /// screen, while someone was looking at both. One date per load, shared.
    private(set) var asOf = Date()

    var filter: RenderFilter = .all
    var search = ""

    var isEmpty: Bool { exports.isEmpty }

    func invalidate() {
        requestGeneration &+= 1
        currentRequest = nil
        releaseInFlightWaiters()
        state = .loading
        exports = []
        loadedAt = nil
        isLoading = false
    }

    /// One request. The list endpoint returns everything the screen needs —
    /// duration, size, failure text and the source recording all ride in
    /// `export_context` — so no row costs a follow-up.
    func load(client: PostHogClient, request: RendersRequestDescriptor) async {
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
            let page: Page<RecordingExport> = try await client.send(
                PostHogAPI.exports(projectID: request.authority.projectID)
            )
            guard owns(id: id, generation: generation, request: request) else { return }
            exports = page.results
            asOf = Date()
            loadedAt = asOf
            state = .resolved(rowCount: exports.count)
        } catch {
            // There is no `Capability` case for exports, so the wall is
            // classified from the failure rather than probed for in advance —
            // the same treatment Logs and Tracing give their ungated endpoints.
            guard owns(id: id, generation: generation, request: request) else { return }
            state = ResourceAccessState(failure: error, resource: "export", defaultScope: "export:read")
        }
    }

    private func prepare(for request: RendersRequestDescriptor) {
        guard currentRequest != request else { return }
        requestGeneration &+= 1
        currentRequest = request
        releaseInFlightWaiters()
        state = .loading
        exports = []
        loadedAt = nil
    }

    private func owns(
        id: UUID,
        generation: UInt64,
        request: RendersRequestDescriptor
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

    var visibleExports: [RecordingExport] {
        exports.filter { export in
            guard filter.matches(export.state(asOf: asOf)) else { return false }
            guard !search.isEmpty else { return true }
            let haystack = [export.filename ?? "", export.sessionRecordingID ?? "", String(export.id)]
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(search)
        }
    }

    /// How many renders each filter would show, for the picker's labels.
    ///
    /// Counted over everything rather than over the visible rows: a filter whose
    /// own count changed when it was selected would be describing itself.
    func count(for filter: RenderFilter) -> Int {
        exports.filter { filter.matches($0.state(asOf: asOf)) }.count
    }
}

// MARK: - Root

struct RendersRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = RendersStore()

    /// The open render, held in `OpenDetails` rather than pushed as a value onto
    /// the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it, and a value
    /// pushed onto the host's stack goes when the host does.
    ///
    /// `LinkedSession` below stays a path value on purpose. It is a link *out*
    /// of this screen into a session recording — one level deeper than the
    /// render this screen has open — and restoring a whole stack is not what
    /// `OpenDetails` promises.
    private var selection: Binding<RecordingExport?> {
        Binding(
            get: { openDetails[.renders] as? RecordingExport },
            set: { openDetails[.renders] = $0.map(AnyHashable.init) }
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
            .navigationTitle("Renders")
            .navigationDestination(item: selection) {
                RenderDetailView(export: $0, asOf: store.asOf)
            }
            .navigationDestination(for: LinkedSession.self) {
                LinkedSessionView(recordingID: $0.recordingID)
            }
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $store.search, prompt: "Search filename or session")
            .screenRefreshable { await load() }
            .onChange(of: requestAuthority, initial: true) { _, _ in store.invalidate() }
            .task(id: requestAuthority) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case _ where store.state.isBlocked:
            RendersLockedView(state: store.state) {
                Task { await model.refreshCapabilities(); await load() }
            }

        case .failed(let message) where !store.exports.isEmpty:
            VStack(spacing: 0) {
                filterBar
                SectionEmptyState(
                    text: "Couldn't refresh renders. \(message)",
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Try again"
                ) { Task { await load() } }
                .padding(.horizontal, Theme.Space.l)
                list
            }
            .background(Theme.pageBackground)

        case .failed(let message):
            EmptyStateView(
                title: store.state.headline(rendersCopy),
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )

        case .empty:
            EmptyStateView(
                title: store.state.headline(rendersCopy),
                systemImage: "film",
                // No action: this app cannot queue a render, and a button that
                // did nothing would be worse than saying where the button is.
                message: rendersCopy.emptyHint
                    + " Export one from the replay player in PostHog and it will appear here."
            )
            .background(Theme.pageBackground)

        default:
            VStack(spacing: 0) {
                filterBar
                list
            }
            .background(Theme.pageBackground)
        }
    }

    /// No scroll view around it, deliberately.
    ///
    /// This bar used to ride a horizontal `ScrollView` so its controls could grow
    /// with Dynamic Type without clipping. Measured on iPhone: it claimed roughly
    /// 230pt of height for a single menu button, leaving a dead band between the
    /// title and the first row — and this screen's search field, which every
    /// neighbouring screen draws in exactly that band, was not on screen at all.
    /// A horizontal scroll view being the first scrollable thing under a
    /// `.searchable` is the likeliest reason for the second half of that; either
    /// way one `.menu` picker never needed one, since a menu label truncates and
    /// stays tappable, and the list below is the scroll view the field belongs to.
    private var filterBar: some View {
        @Bindable var store = store

        return GlassFilterBar {
            Picker("Show", selection: $store.filter) {
                ForEach(RenderFilter.allCases) { filter in
                    Text("\(filter.title) (\(store.count(for: filter)))").tag(filter)
                }
            }
            .pickerStyle(.menu)
            .lineLimit(1)
            // The bar hugs its content, and a menu is narrow; without this it
            // collapses to a pill centred in the screen.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.s)
        .background(Theme.pageBackground)
    }

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` displays it.
    private var list: some View {
        List(selection: selection) {
            Section {
                if store.visibleExports.isEmpty && !store.isLoading {
                    // Reached only by the client-side filter: the renders exist,
                    // none of them are in the state being asked for. Saying so
                    // beats an empty list that reads as a failed load.
                    EmptyStateView(
                        title: noMatchesTitle,
                        systemImage: "line.3.horizontal.decrease.circle",
                        message: noMatchesMessage
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.visibleExports) { export in
                        NavigationLink(value: export) {
                            RenderRowView(export: export, asOf: store.asOf)
                        }
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
                    text: "\(store.visibleExports.count) render\(store.visibleExports.count == 1 ? "" : "s")",
                    systemImage: "film"
                )
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    /// Names whichever of the two client-side narrowings is doing the hiding, so
    /// "nothing here" is never mistaken for "nothing was rendered". Both can be on
    /// at once, and the search is the one the reader just typed.
    private var noMatchesTitle: String {
        store.search.isEmpty ? "No \(store.filter.title.lowercased()) renders" : "No matches"
    }

    private var noMatchesMessage: String {
        guard !store.search.isEmpty else {
            // Unreachable with `.all` selected: an empty search on every state
            // can only be empty when the project is, which the screen above
            // already answered.
            return "This project has \(store.exports.count) renders, none of them \(store.filter.title.lowercased())."
        }
        return store.filter == .all
            ? "Nothing here is called “\(store.search)”."
            : "Nothing called “\(store.search)” is \(store.filter.title.lowercased())."
    }

    private func load() async {
        guard let client = model.client, let authority = requestAuthority else {
            store.invalidate()
            return
        }
        await store.load(
            client: client,
            request: RendersRequestDescriptor(authority: authority)
        )
    }
}

// MARK: - Locked

/// The locked state, named.
///
/// Deliberately the same treatment as `LogsLockedView`: same lock symbol, same
/// monospaced resource chip, same "re-check" rather than "try again", because all
/// three screens report the same class of problem and should be recognisable as
/// such. It is separate from `LockedCapabilityView` because the remedies differ —
/// a missing key *scope* is fixed by the user, a denied *resource* by an admin.
struct RendersLockedView: View {
    let state: ResourceAccessState
    var onRecheck: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(state.headline(rendersCopy), systemImage: "lock")
        } description: {
            VStack(spacing: Theme.Space.s) {
                Text(state.detail(rendersCopy))
                if case .denied(let resource) = state {
                    Text(resource)
                        .font(.footnote.monospaced())
                        // The scope PostHog named, not prose — same idiom and
                        // same measurement as the identical chip on Logs.
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
                    // photographed** — the demo Renders screen lists exports
                    // rather than reaching its denied state. The "Play" button
                    // on `RenderDetailView`, which is where the 2.09:1 was
                    // sampled, is the same construction one screen along.
                    .foregroundStyle(Theme.inkOnAccent)
            }
        }
    }
}

// MARK: - Row

struct RenderRowView: View {
    let export: RecordingExport
    let asOf: Date

    private var state: RecordingExportState { export.state(asOf: asOf) }

    var body: some View {
        DataRow(
            glyph: state.glyph,
            tint: state.tint,
            title: title,
            subtitle: subtitle,
            footnote: footnote,
            // Two lines only for a failure, where the subtitle is PostHog's own
            // exception text and the first line is usually just the error class.
            subtitleLineLimit: isFailure ? 2 : 1,
            accessory: .pill(export.statusText(asOf: asOf), state.tint)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    /// A render with no file has no filename either, so the id stands in — it is
    /// what PostHog's own URLs use and what a support thread would quote.
    private var title: String {
        export.filename ?? "Render \(export.id)"
    }

    /// The failure text displaces the size and duration because there is no size
    /// and no duration: a failed render measured nothing.
    private var subtitle: String? {
        if case .failed(let reason) = state { return reason }
        return export.summary
    }

    private var footnote: String? {
        var parts: [String] = []
        if let created = export.createdAt {
            parts.append(created.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        if let expires = export.expiresAfter {
            parts.append(
                export.hasExpired(asOf: asOf)
                    ? "deleted \(expires.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))"
                    : "expires \(expires.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var parts = [title, export.statusText(asOf: asOf)]
        if case .failed(let reason) = state {
            parts.append(reason)
        } else {
            parts.append(export.summary)
        }
        if let footnote { parts.append(footnote) }
        return parts.joined(separator: ", ")
    }
}
