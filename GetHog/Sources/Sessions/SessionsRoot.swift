import GetHogKit
import GetHogUI
import SwiftUI

struct SessionsRefreshPresentation: Equatable {
    let message: String
    let actionTitle: String

    static func resolve(recordingCount: Int, error: String?) -> Self? {
        guard recordingCount > 0, let error else { return nil }
        return Self(
            message: "Couldn't refresh sessions. \(error)",
            actionTitle: "Try again"
        )
    }
}

@MainActor
@Observable
final class SessionsStore {
    var recordings: [SessionRecording] = []
    private(set) var summariesBySessionID: [String: ReplayVisionSummaryDigest] = [:]
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    /// A next-page failure is not a failure of the rows already on screen. It
    /// stays separate so the footer can retry without replacing the list.
    var pagingError: String?
    var loadedAt: Date?
    /// Whether the API said another page exists. There is no `count` in the
    /// response, so this is the only thing that can be known about what is left.
    var hasMore = false

    /// Server-side. The whole filter, including the person search behind the
    /// navigation bar's field.
    var filter = SessionRecordingFilter() {
        didSet {
            if Self.signature(for: oldValue) != requestSignature {
                invalidateRequestProvenanceIfNeeded()
            }
            persistDurableProjectionIfNeeded()
        }
    }

    @ObservationIgnored private let preferences: SessionsPreferences
    @ObservationIgnored private var durableValue = SessionsPreferences.Value()
    private var activeScope: ProjectPreferenceScope?

    private var offset = 0
    private let pageSize = 50

    /// Bumped on every fresh load so a page that was already in flight when the
    /// filter changed cannot append its rows onto the new filter's results.
    private var generation = 0
    private var preparedAuthority: ResourceRequestAuthority?
    private var loadedAuthority: ResourceRequestAuthority?
    private var loadedScope: ProjectPreferenceScope?
    private var loadedRequestSignature: String?

    init(preferences: SessionsPreferences = SessionsPreferences()) {
        self.preferences = preferences
    }

    func activate(scope: ProjectPreferenceScope) {
        guard activeScope != scope else { return }
        let value = preferences.value(for: scope)
        activeScope = scope
        durableValue = value
        var destinationFilter = SessionRecordingFilter()
        value.apply(to: &destinationFilter)
        filter = destinationFilter
    }

    func replaceFilter(_ replacement: SessionRecordingFilter) {
        filter = replacement
    }

    func clearFilters() {
        var cleared = SessionRecordingFilter()
        cleared.order = filter.order
        filter = cleared
    }

    /// Changes in host, project, or credential epoch are ownership boundaries.
    /// Clear synchronously so the old authority is never drawn beneath a new
    /// project subtitle while its replacement request is still suspended.
    func prepare(authority: ResourceRequestAuthority?) {
        guard preparedAuthority != authority else { return }
        preparedAuthority = authority
        generation += 1
        loadedAuthority = nil
        loadedScope = nil
        loadedRequestSignature = nil
        recordings = []
        summariesBySessionID = [:]
        hasMore = false
        offset = 0
        loadedAt = nil
        error = nil
        pagingError = nil
        isLoadingMore = false
        isLoading = authority != nil

        if let authority {
            activate(scope: ProjectPreferenceScope(
                projectID: authority.projectID,
                region: authority.region
            ))
        }
    }

    private func persistDurableProjectionIfNeeded() {
        guard let activeScope else { return }
        let value = SessionsPreferences.Value(filter: filter)
        guard value != durableValue else { return }
        durableValue = value
        preferences.set(value, for: activeScope)
    }

    /// A filter edit becomes visible synchronously, while its replacing request
    /// may be debounced. Retire the preceding request at that same boundary so
    /// its rows cannot sit beneath the new summary or publish after the edit.
    private func invalidateRequestProvenanceIfNeeded() {
        guard loadedScope != nil else { return }
        generation += 1
        recordings = []
        summariesBySessionID = [:]
        hasMore = false
        offset = 0
        loadedAt = nil
        error = nil
        pagingError = nil
        isLoadingMore = false
        loadedRequestSignature = nil
        isLoading = true
    }

    /// Loads the first page for the current filter, **replacing** what is shown.
    func load(client: PostHogClient, authority: ResourceRequestAuthority) async {
        prepare(authority: authority)
        guard preparedAuthority == authority, client.region == authority.region else { return }
        let projectID = authority.projectID
        let scope = ProjectPreferenceScope(projectID: projectID, region: authority.region)
        activate(scope: scope)
        let requestSignature = self.requestSignature
        generation += 1
        let token = generation
        let authorityChanged = loadedAuthority != authority
        let requestChanged = loadedRequestSignature != requestSignature
        loadedAuthority = authority
        loadedScope = scope
        pagingError = nil
        // Every replacement invalidates any page request from the preceding
        // generation, even when the project stayed the same and only its filter
        // changed. That stale request's guarded defer cannot clear this flag
        // after `generation` advances, so the new generation must own the reset.
        isLoadingMore = false
        if authorityChanged {
            // A project is a data-ownership boundary, not merely another
            // filter. Clear before the request suspends so the replacement can
            // never present old-project recordings as its loading state.
            recordings = []
            summariesBySessionID = [:]
            error = nil
            loadedAt = nil
            hasMore = false
        }
        isLoading = true
        defer {
            if token == generation,
               preparedAuthority == authority,
               loadedAuthority == authority {
                isLoading = false
            }
        }

        do {
            let list: RecordingList = try await client.send(
                PostHogAPI.sessionRecordings(
                    projectID: projectID, limit: pageSize, offset: 0, filter: filter
                )
            )
            guard token == generation,
                  preparedAuthority == authority,
                  loadedAuthority == authority
            else { return }
            recordings = list.results
            hasMore = list.hasNext
            offset = list.results.count
            loadedAt = Date()
            error = nil
            pagingError = nil
            loadedRequestSignature = requestSignature
            await enrichSummaries(
                client: client,
                projectID: projectID,
                sessionIDs: list.results.map(\.id),
                token: token,
                authority: authority,
                scope: scope,
                requestSignature: requestSignature,
                replacing: true
            )
        } catch {
            guard token == generation,
                  preparedAuthority == authority,
                  loadedAuthority == authority
            else { return }
            let retainsLastGoodRows = !authorityChanged
                && !requestChanged
                && loadedRequestSignature == requestSignature
                && !recordings.isEmpty
            if !retainsLastGoodRows {
                // A failed narrowing must not leave the previous filter's rows
                // on screen looking like the answer to the new question.
                recordings = []
                summariesBySessionID = [:]
                hasMore = false
                offset = 0
                loadedAt = nil
            }
            pagingError = nil
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Appends the next page. Never runs while a fresh load is in flight, and
    /// discards its result if the filter changed underneath it.
    func loadMore(client: PostHogClient, authority: ResourceRequestAuthority) async {
        guard client.region == authority.region else { return }
        let projectID = authority.projectID
        let scope = ProjectPreferenceScope(projectID: projectID, region: authority.region)
        let requestSignature = self.requestSignature
        guard preparedAuthority == authority,
              loadedAuthority == authority,
              loadedScope == scope,
              activeScope == scope,
              loadedRequestSignature == requestSignature,
              hasMore,
              !isLoading,
              !isLoadingMore
        else { return }
        let token = generation
        pagingError = nil
        isLoadingMore = true
        defer {
            if token == generation,
               preparedAuthority == authority,
               loadedAuthority == authority {
                isLoadingMore = false
            }
        }

        do {
            let list: RecordingList = try await client.send(
                PostHogAPI.sessionRecordings(
                    projectID: projectID, limit: pageSize, offset: offset, filter: filter
                )
            )
            guard token == generation,
                  preparedAuthority == authority,
                  loadedAuthority == authority,
                  loadedScope == scope,
                  loadedRequestSignature == requestSignature,
                  self.requestSignature == requestSignature
            else { return }
            // Offset paging over a live, time-ordered table can repeat a row
            // when a new recording lands between pages.
            let known = Set(recordings.map(\.id))
            let appended = list.results.filter { !known.contains($0.id) }
            recordings.append(contentsOf: appended)
            hasMore = list.hasNext
            offset += list.results.count
            loadedAt = Date()
            pagingError = nil
            await enrichSummaries(
                client: client,
                projectID: projectID,
                sessionIDs: appended.map(\.id),
                token: token,
                authority: authority,
                scope: scope,
                requestSignature: requestSignature,
                replacing: false
            )
        } catch {
            guard token == generation,
                  preparedAuthority == authority,
                  loadedAuthority == authority,
                  loadedScope == scope,
                  loadedRequestSignature == requestSignature,
                  self.requestSignature == requestSignature
            else { return }
            // Keep both the loaded rows and the server's assertion that another
            // page exists. Turning `hasMore` off here removes the only retry
            // control and converts a transient page failure into a false end.
            pagingError = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    func summary(for sessionID: String) -> ReplayVisionSummaryDigest? {
        summariesBySessionID[sessionID]
    }

    func publish(
        summary observation: ReplayVisionObservation,
        authority: ResourceRequestAuthority
    ) {
        guard preparedAuthority == authority,
              let digest = ReplayVisionSummaryDigest(observation: observation)
        else { return }
        mergeSummaries([digest])
    }

    func mergeSummaries(_ digests: [ReplayVisionSummaryDigest]) {
        for digest in digests {
            if let current = summariesBySessionID[digest.id],
               !Self.isAtLeastAsRecent(digest, as: current) {
                continue
            }
            summariesBySessionID[digest.id] = digest
        }
    }

    private static func isAtLeastAsRecent(
        _ incoming: ReplayVisionSummaryDigest,
        as current: ReplayVisionSummaryDigest
    ) -> Bool {
        switch (incoming.completedAt, current.completedAt) {
        case let (incoming?, current?): incoming >= current
        case (.some, .none): true
        case (.none, .some), (.none, .none): false
        }
    }

    /// Replay Vision enrichment is optional context on an otherwise valid
    /// recording list. It is one query for the whole page, and a failure here
    /// never turns successful `/session_recordings/` rows into an error state.
    private func enrichSummaries(
        client: PostHogClient,
        projectID: Int,
        sessionIDs: [String],
        token: Int,
        authority: ResourceRequestAuthority,
        scope: ProjectPreferenceScope,
        requestSignature: String,
        replacing: Bool
    ) async {
        if replacing { summariesBySessionID = [:] }
        guard !sessionIDs.isEmpty else {
            return
        }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.replayVisionSummaryDigests(
                    projectID: projectID,
                    sessionIDs: sessionIDs,
                    limit: sessionIDs.count
                )
            )
            guard token == generation,
                  preparedAuthority == authority,
                  loadedAuthority == authority,
                  loadedScope == scope,
                  loadedRequestSignature == requestSignature,
                  self.requestSignature == requestSignature
            else { return }
            let digests = ReplayVisionSummaryDigest.rows(from: response)
            mergeSummaries(digests)
        } catch {
            // The recordings request already succeeded. Summary enrichment is
            // intentionally best-effort and leaves the list usable.
        }
    }

    /// A stable key for the current request. Driving `.task(id:)` with this is
    /// what makes a filter change cancel the in-flight request and start a
    /// replacing load, rather than racing it.
    private static func signature(for filter: SessionRecordingFilter) -> String {
        filter.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    var requestSignature: String { Self.signature(for: filter) }

    func requestSignature(for scope: ProjectPreferenceScope) -> String {
        if activeScope == scope { return requestSignature }
        var destinationFilter = SessionRecordingFilter()
        preferences.value(for: scope).apply(to: &destinationFilter)
        return Self.signature(for: destinationFilter)
    }
}

struct SessionsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.screenNavigationPlacement) private var navigationPlacement
    @Environment(OpenDetails.self) private var openDetails
    #if os(macOS) || os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var store = SessionsStore()
    @State private var showsFilters = false
    /// The current page tail only while it remains on screen. A visibility
    /// callback can arrive while Replay Vision enrichment still owns the page
    /// load; remembering it lets the load-state transition retry instead of
    /// permanently consuming that edge.
    @State private var visiblePaginationTailID: String?
    #if os(macOS)
    @State private var showsPlaylists = false
    #endif

    /// The open recording's id, and deliberately **not** `@State`.
    ///
    /// See `FlagsRoot.selectedID` for the measurement. Since the tab bar became
    /// a preference this screen can be demoted, a demoted screen is pushed onto
    /// the search tab's stack, and a `NavigationSplitView` nested in a
    /// `NavigationStack` has nowhere to put its detail - so the row opened
    /// nothing at all.
    private var selectedID: Binding<String?> {
        Binding(
            get: { openDetails[.sessions] as? String },
            set: { openDetails[.sessions] = $0.map(AnyHashable.init) }
        )
    }

    private var selection: SessionRecording? {
        selectedID.wrappedValue.flatMap { id in store.recordings.first { $0.id == id } }
    }

    private var usesHostNavigation: Bool {
        sizeClass == .compact || navigationPlacement == .visionSectionDetail
    }

    #if os(macOS)
    @Environment(\.macRegularListWidth) private var macRegularListWidth
    #endif

    private var preferenceScope: ProjectPreferenceScope? {
        guard let authority = requestAuthority else { return nil }
        return ProjectPreferenceScope(
            projectID: authority.projectID,
            region: authority.region
        )
    }

    private var requestAuthority: ResourceRequestAuthority? {
        guard let client = model.client,
              let projectID = model.projectID,
              let authSessionID = model.authSessionID
        else { return nil }
        return .init(
            projectID: projectID,
            region: client.region,
            authSessionID: authSessionID
        )
    }

    private var loadTaskID: String {
        guard let scope = preferenceScope else { return "sessions.none" }
        guard let authority = requestAuthority else { return "sessions.none" }
        return "\(scope.storageKeyComponent)|auth:\(authority.authSessionID.uuidString)|\(store.requestSignature(for: scope))"
    }

    var body: some View {
        Group {
            if usesHostNavigation {
                listChrome
                    .navigationDestination(item: selectedID) { id in
                        if let recording = store.recordings.first(where: { $0.id == id }) {
                            sessionDetail(recording).id(id)
                        }
                    }
                    #if os(macOS)
                    .navigationDestination(isPresented: $showsPlaylists) {
                        PlaylistsView { filter in
                            store.replaceFilter(filter)
                            showsPlaylists = false
                        }
                    }
                    #endif
            } else {
                #if os(macOS)
                NavigationStack {
                    MacRegularListDetailSplit(
                        accessibilityIdentifier: "gethog.mac-product-divider.sessions",
                        accessibilityLabel: "Sessions list width",
                        minimumListWidth: 300,
                        idealListWidth: 380,
                        maximumListWidth: 440,
                        preferredListWidth: macRegularListWidth
                    ) {
                        listChrome
                    } detail: {
                        detailPane
                    }
                    .navigationDestination(isPresented: $showsPlaylists) {
                        PlaylistsView { filter in
                            store.replaceFilter(filter)
                            showsPlaylists = false
                        }
                    }
                }
                #else
                NavigationSplitView {
                    listChrome
                        // Sized to the row's caption line, which is the longest
                        // thing here: "0:42 · 12 clicks · 3 errors · Mobile,
                        // not playable · 2d" needs ~300pt, and the glyph plus
                        // row insets take another ~90 before it starts. At the
                        // ~320pt the column took by default the caveat that a
                        // recording cannot be played was being truncated away.
                        .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 440)
                        // The tab sidebar already puts a toggle in this bar; the
                        // split view added a second, identical one beside it.
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    detailPane
                }
                #endif
            }
        }
        #if os(macOS)
        .onChange(of: usesHostNavigation) { _, _ in
            showsPlaylists = false
        }
        #endif
    }

    /// The list and everything attached to it, shared by both widths so the two
    /// arrangements cannot drift in what they load, search or filter.
    private var listChrome: some View {
        @Bindable var store = store

        return content
                .topLevelNavigationTitle("Sessions")
#if os(macOS)
                // The whole bar in one declaration — what "Customize Toolbar…"
                // rearranges: the same two controls the iOS bar pins, made
                // rearrangeable, plus the Mac-only Refresh, since
                // pull-to-refresh does not exist here. One declaration and not
                // two because a plain `.toolbar { }` beside a `.toolbar(id:)`
                // leaves the window's toolbar refusing customization outright;
                // `PinnedProjectSwitcher` is the switcher rejoining this
                // declaration as an item nobody can move or remove, and carries
                // the measurement.
                .toolbar(id: "sessions") {
                    PinnedProjectSwitcher()
                    ToolbarSpacer(.flexible)
                    ToolbarItem(id: "filter", placement: .primaryAction) { filterButton }
                    ToolbarItem(id: "playlists", placement: .primaryAction) { playlistsButton }
                    ToolbarItem(id: "refresh", placement: .primaryAction) {
                        Button {
                            Task { await load() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh sessions")
                    }
                }
#else
                .toolbar {
                    ProjectSwitcher()
                    ToolbarItem(placement: .topBarTrailing) { filterButton }
                    ToolbarItem(placement: .topBarTrailing) { playlistsLink }
                }
#endif
                .projectSubtitle()
                // Placement is pinned rather than left to `.automatic`, for the
                // reason recorded on `EventsRoot`: measured on iPad, the
                // automatic placement drew no field at all in the list column.
                //
                // The text now goes to the server. It used to filter the loaded
                // page for a substring of the person *or* the start URL; that
                // matched within 50 rows and disagreed with the duration picker
                // beside it, which also filtered locally. Both are server-side
                // now, and the URL half moved to its own field on the filter
                // sheet — one text box cannot drive two AND'd clauses.
                // Absent on tvOS for the reason `DashboardsRoot` records in
                // full: the field takes initial focus there and raises the
                // full-screen grid keyboard over the list it filters.
                #if !os(tvOS)
                .searchable(
                    text: Binding(
                        get: { store.filter.personSearch ?? "" },
                        set: { store.filter.personSearch = $0.isEmpty ? nil : $0 }
                    ),
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search person email"
                )
                #endif
                .screenRefreshable { await load() }
                .onChange(of: requestAuthority, initial: true) { _, authority in
                    visiblePaginationTailID = nil
                    store.prepare(authority: authority)
                }
                // One task covers project switches, typing and every control on
                // the filter sheet. `.task(id:)` cancels the previous one, so a
                // burst of keystrokes costs one request, and a filter change
                // always *replaces* the paging state rather than extending it.
                .task(id: loadTaskID) {
                    if store.filter.trimmedPersonSearch != nil
                        || store.filter.trimmedURLSearch != nil {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                    }
                    await load()
                }
                .onChange(of: store.requestSignature) { _, _ in
                    visiblePaginationTailID = nil
                    selectedID.wrappedValue = nil
                }
                .onChange(of: store.isLoading || store.isLoadingMore) { wasBusy, isBusy in
                    if wasBusy, !isBusy {
                        requestMoreIfVisible()
                    }
                }
                #if os(macOS)
                .onChange(of: model.projectID) { _, _ in
                    showsPlaylists = false
                }
                #endif
                .sheet(isPresented: $showsFilters) {
                    SessionFilterSheet(filter: $store.filter, onClear: store.clearFilters)
                        .presentationDetents([.medium, .large])
                }
    }

    /// The detail column: the chosen recording, or a summary of the product when
    /// nothing is chosen yet.
    ///
    /// The no-selection branch mirrors the list's own states rather than summarising thin air: a locked
    /// key and a project with replay switched off are both normal outcomes, and
    /// a grid of zeroes would misreport either one.
    @ViewBuilder
    private var detailPane: some View {
        if let selection {
            sessionDetail(selection).id(selection.id)
        } else if !model.isAvailable(.sessions) {
            LockedCapabilityView(capability: .sessions, scope: model.lockedScope(for: .sessions)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.recordings.isEmpty {
            EmptyStateView(
                title: "Couldn't load sessions",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.recordings.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.large)
            } else {
                emptyState
            }
        } else {
            SessionsOverview(
                recordings: store.recordings,
                loadedAt: store.loadedAt,
                selection: selectedID
            )
        }
    }

    @ViewBuilder
    private func sessionDetail(_ recording: SessionRecording) -> some View {
        #if os(visionOS)
        SessionDetailView(
            recording: recording,
            onOpenInNewWindow: {
                openWindow(value: WindowTarget.recording(id: recording.id))
            },
            onSummaryGenerated: { observation, authority in
                store.publish(summary: observation, authority: authority)
            }
        )
        #else
        SessionDetailView(
            recording: recording,
            onSummaryGenerated: { observation, authority in
                store.publish(summary: observation, authority: authority)
            }
        )
        #endif
    }

    /// Empty means one of two different things, and they need different words.
    /// An unfiltered empty project is a fact about the project; an empty result
    /// under a filter is a fact about the filter, and the way out is to widen
    /// it — so that state offers the control that would.
    private var emptyState: some View {
        Group {
            if store.filter.isNarrowed {
                EmptyStateView(
                    title: "No matching sessions",
                    systemImage: "line.3.horizontal.decrease.circle",
                    message: "No recordings match \(store.filter.activeCount) active filter\(store.filter.activeCount == 1 ? "" : "s").",
                    actionTitle: "Clear filters",
                    action: store.clearFilters
                )
            } else {
                EmptyStateView(
                    title: "No sessions",
                    systemImage: "rectangle.stack",
                    illustration: .sessions,
                    message: "No session recordings in this project yet."
                )
            }
        }
    }

    /// Badged, because a narrowed list and an empty project look identical
    /// otherwise. The count is also spoken, so the state does not depend on
    /// noticing a coloured dot.
    private var filterButton: some View {
        Button {
            showsFilters = true
        } label: {
            #if os(tvOS)
            Label(
                store.filter.isNarrowed ? "Filter (\(store.filter.activeCount))" : "Filter",
                systemImage: store.filter.isNarrowed
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
            .labelStyle(.titleAndIcon)
            #else
            Image(systemName: store.filter.isNarrowed
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
            #endif
        }
        .televisionAccentControlInk()
        .accessibilityLabel(
            store.filter.isNarrowed
                ? "Filter sessions, \(store.filter.activeCount) active"
                : "Filter sessions"
        )
    }

    /// Playlists are saved views over these same recordings, so they live here
    /// rather than competing for a tab.
    #if os(macOS)
    private var playlistsButton: some View {
        Button {
            showsPlaylists = true
        } label: {
            Image(systemName: "list.star")
        }
        .accessibilityLabel("Playlists")
    }
    #endif

    /// Non-Mac navigation containers resolve the link directly. The Mac uses
    /// explicit route state above because a customizable window-toolbar link
    /// does not inherit the regular screen's nested navigation stack.
    private var playlistsLink: some View {
        NavigationLink {
            PlaylistsView { store.replaceFilter($0) }
        } label: {
            #if os(tvOS)
            Label("Playlists", systemImage: "list.star")
                .labelStyle(.titleAndIcon)
            #else
            Image(systemName: "list.star")
            #endif
        }
        .televisionAccentControlInk()
        .accessibilityLabel("Playlists")
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.sessions) {
            LockedCapabilityView(capability: .sessions, scope: model.lockedScope(for: .sessions)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.recordings.isEmpty {
            EmptyStateView(
                title: "Couldn't load sessions",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.recordings.isEmpty && !store.isLoading {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: selectedID) {
            if let presentation = SessionsRefreshPresentation.resolve(
                recordingCount: store.recordings.count,
                error: store.error
            ) {
                SectionEmptyState(
                    text: presentation.message,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: presentation.actionTitle
                ) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if store.filter.isNarrowed {
                ActiveFilterSummary(filter: store.filter, onClear: store.clearFilters)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(store.recordings) { recording in
                sessionRow(recording)
            }

            if store.hasMore {
                // The tail row starts ordinary scroll-driven paging. Keep an
                // explicit control as well so keyboard and VoiceOver readers
                // can request the next page without depending on scroll state,
                // and so a failed page has somewhere stable to retry.
                Group {
                    if store.isLoadingMore {
                        ProgressView()
                    } else if let pagingError = store.pagingError {
                        VStack(spacing: Theme.Space.xs) {
                            Text(pagingError)
                                .font(.footnote)
                                .foregroundStyle(Theme.Status.criticalInk)
                                .multilineTextAlignment(.center)
                            Button("Try loading more again") { Task { await loadMore() } }
                        }
                    } else {
                        Button("Load more sessions") { Task { await loadMore() } }
                    }
                }
                .frame(maxWidth: .infinity)
                .minimumHitTarget()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .accessibilityIdentifier("gethog.sessions-list")
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.recordings.isEmpty)
    }

    /// One row construction serves the host-navigation and split-view list
    /// arrangements, keeping preview actions identical at both widths.
    private func sessionRow(_ recording: SessionRecording) -> some View {
        NavigationLink(value: recording.id) {
            SessionRowView(
                recording: recording,
                summary: store.summary(for: recording.id)
            )
            .quickPreview {
                SessionQuickPreview(
                    recording: recording,
                    digest: store.summary(for: recording.id)
                )
            } menuItems: {
                Button {
                    selectedID.wrappedValue = recording.id
                } label: {
                    Label("Open Session", systemImage: "arrow.right.circle")
                }
                #if os(macOS)
                Button {
                    openWindow(value: WindowTarget.recording(id: recording.id))
                } label: {
                    Label("Open in new window", systemImage: "macwindow.badge.plus")
                }
                #endif
            }
        }
        .accessibilityIdentifier("gethog.session-card.\(recording.id)")
        // `List` may construct rows beyond the viewport while the first page is
        // still loading. Visibility avoids spending a page on that prefetch.
        // Keep the visible tail id across optional summary enrichment so its
        // busy-to-idle transition can retry an edge that arrived in-flight.
        // A new last id appears after every successful page, while the store
        // owns the duplicate, filter, authority and end guards.
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            if visible {
                guard recording.id == store.recordings.last?.id else { return }
                visiblePaginationTailID = recording.id
                requestMoreIfVisible()
            } else if visiblePaginationTailID == recording.id {
                visiblePaginationTailID = nil
            }
        }
        #if os(macOS)
        .listRowInsets(EdgeInsets(
            top: Theme.Space.xs / 2,
            leading: Theme.Space.s,
            bottom: Theme.Space.xs / 2,
            trailing: Theme.Space.s
        ))
        #endif
        .listCardBackground(route: "sessions", id: recording.id)
        .listRowSeparator(.hidden)
    }

    private func load() async {
        guard let client = model.client, let authority = requestAuthority else { return }
        await store.load(client: client, authority: authority)
    }

    private func loadMore() async {
        guard let client = model.client, let authority = requestAuthority else { return }
        await store.loadMore(client: client, authority: authority)
    }

    private func requestMoreIfVisible() {
        guard store.hasMore,
              store.pagingError == nil,
              !store.isLoading,
              !store.isLoadingMore,
              visiblePaginationTailID == store.recordings.last?.id
        else { return }
        Task { await loadMore() }
    }
}

/// A plain-language sentence for what the list is currently showing.
///
/// Sits above the rows rather than in the toolbar because the badge on the
/// filter button says *that* the list is narrowed and this says *how* — and
/// "why am I only seeing four sessions" is a question asked while looking at
/// the list, not at the toolbar.
/// Not `SectionEmptyState`, which is documented for a section that has nothing
/// in it — this describes a section that has something in it, and borrowing
/// that component would have made its contract mean two things.
///
/// **Not `ViewThatFits` either**, which is the obvious answer and does not work
/// here. Rendered and looked at: a wrapping `Text` reports that it fits any
/// width, so the horizontal candidate always won and the vertical fallback was
/// unreachable. At accessibility sizes that produced a "Clear" button floating
/// beside the first word with six lines of sentence flowing underneath it.
/// The size class is asked directly instead — the same test `PeopleRoot` uses.
struct ActiveFilterSummary: View {
    let filter: SessionRecordingFilter
    var onClear: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    sentence
                    clearButton
                }
            } else {
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    sentence
                    Spacer(minLength: Theme.Space.s)
                    clearButton
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The icon and sentence share a text baseline. The outer row itself is
    /// centred so the visible `Clear` glyph—not the top edge of its 44-point
    /// hit target—aligns with a one-line sentence.
    private var sentence: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(filter.summarySentence)
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)
                // Wraps rather than truncates: this is the explanation for a
                // short list, and half an explanation is not one. It is kept
                // short at the source instead — see `summarySentence`.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clearButton: some View {
        Button("Clear", action: onClear)
            .font(.subheadline.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .minimumHitTarget()
            .accessibilityLabel("Clear all session filters")
    }
}

extension SessionRecordingFilter {
    /// The active narrowings, in the order the sheet lists them.
    ///
    /// Capped at three named clauses with the rest counted. Rendered at
    /// accessibility sizes, the uncapped version ran to eight lines and pushed
    /// the first recording off the screen — the sentence exists to explain a
    /// short list, and it had become longer than the list.
    var summarySentence: String {
        var parts: [String] = []
        if filterTestAccounts { parts.append("excluding test users") }
        if let signal { parts.append(signal.title.lowercased()) }
        if dateWindow != .allTime { parts.append(dateWindow.title.lowercased()) }
        if let minimum = minimumDuration, minimum > 0 {
            // The metric is named because the two numbers differ by an order of
            // magnitude on the same recording.
            let measured = durationMetric == .active ? "active" : "long"
            let length = Duration.seconds(minimum)
                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            parts.append("\(length)+ \(measured)")
        }
        if source == .web { parts.append("playable only") }
        if let term = trimmedPersonSearch { parts.append("person “\(term)”") }
        if let term = trimmedURLSearch { parts.append("URL “\(term)”") }
        if !inheritedProperties.isEmpty {
            let count = inheritedProperties.count
            parts.append("\(count) saved clause\(count == 1 ? "" : "s")")
        }

        guard !parts.isEmpty else { return "Showing all sessions." }
        let named = parts.prefix(Self.namedSummaryClauses)
        let remainder = parts.count - named.count
        let tail = remainder > 0 ? " +\(remainder) more" : ""
        return "Showing " + named.joined(separator: " · ") + tail + "."
    }

    /// Three fits two lines at the largest non-accessibility size, measured.
    private static var namedSummaryClauses: Int { 3 }
}

struct SessionRowView: View {
    let recording: SessionRecording
    var summary: ReplayVisionSummaryDigest? = nil

    private var presentation: SessionRowPresentation {
        SessionRowPresentation(recording: recording, summary: summary)
    }

    var body: some View {
        DataRow(
            glyph: glyph,
            brandGlyph: SessionBrandAppearance.glyph(
                hasErrors: recording.hasErrors,
                isReplayable: recording.isReplayable,
                hasFriction: presentation.hasFriction
            ),
            tint: tint,
            title: recording.personDisplayName,
            subtitle: recording.pathComponent,
            supplement: presentation.summaryLine,
            footnote: stats,
            // The start URL's path is an identifier, and a column of aligned
            // paths is what makes one session's entry point comparable to the
            // next one's.
            isSubtitleMonospaced: true,
            // Usually an email; wrapping stranded an orphan `m` on its own
            // line in the iPad sidebar. See `PersonRowView`.
            titleTruncatesMiddle: true,
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityDescription)
    }

    /// The glyph carries whatever is unusual about the session — errors first,
    /// then the mobile recordings this app cannot play — so the list can be
    /// triaged by shape before a name is read.
    private var glyph: String {
        if recording.hasErrors { return "exclamationmark.triangle.fill" }
        if !recording.isReplayable { return "iphone" }
        return "play.rectangle"
    }

    private var tint: Color {
        recording.hasErrors ? Theme.Status.critical : Theme.accent
    }

    /// Duration, activity and the caveats on the row's one caption line. The
    /// error count used to be a bare number behind a red triangle, so it says
    /// "errors" now; and the order puts what is worth acting on ahead of the
    /// timestamp, which is the part that gets truncated away first.
    private var stats: String {
        var parts = [recording.durationText, "\(recording.clickCount) clicks"]
        if recording.hasErrors { parts.append("\(recording.consoleErrorCount) errors") }
        // Set expectations in the list, not after a failed load.
        if !recording.isReplayable { parts.append("Mobile, not playable") }
        if let start = recording.startTime {
            parts.append(start.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        return parts.joined(separator: " · ")
    }

}

struct SessionRowPresentation {
    let recording: SessionRecording
    let summary: ReplayVisionSummaryDigest?

    var summaryLine: String? { summary?.cardSummary }
    var hasFriction: Bool { summary?.hasFriction == true }

    var accessibilityDescription: String {
        var parts = [
            recording.personDisplayName,
            "duration \(recording.durationText)",
            "\(recording.clickCount) clicks",
        ]
        if let summaryLine { parts.append(summaryLine) }
        if recording.hasErrors {
            parts.append("\(recording.consoleErrorCount) console errors")
        }
        if hasFriction { parts.append("Replay Vision friction") }
        if !recording.isReplayable { parts.append("mobile recording, not playable") }
        return parts.joined(separator: ", ")
    }
}
