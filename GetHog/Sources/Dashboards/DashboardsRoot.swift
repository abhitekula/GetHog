import GetHogKit
import GetHogUI
import SwiftUI

enum DashboardCollectionContentState: Equatable {
    case unavailable
    case loading
    case failed(String)
    case empty
    case loaded
}

struct DashboardListRefreshPresentation: Equatable {
    let message: String
    let actionTitle: String

    static func resolve(dashboardCount: Int, error: String?) -> Self? {
        guard dashboardCount > 0, let error else { return nil }
        return Self(
            message: "Couldn't refresh dashboards. \(error)",
            actionTitle: "Try again"
        )
    }
}

enum DashboardNavigationTopology {
    static var showsExplicitReturnControl: Bool {
        #if os(macOS) || os(visionOS)
        true
        #else
        false
        #endif
    }
}

enum DashboardRowContainer {
    case navigationLink
    case button

    var showsAuthoredChevron: Bool {
        switch self {
        case .navigationLink: false
        case .button: true
        }
    }
}

@MainActor
@Observable
final class DashboardsStore {
    private struct LoadFlight {
        let id: Int
        let scope: ProjectPreferenceScope
        let task: Task<Void, Never>
    }

    var dashboards: [DashboardSummary] = []
    var isLoading = true
    var error: String?
    var loadedAt: Date?
    private var loadedScope: ProjectPreferenceScope?
    private var generation = 0
    private var nextLoadFlightID = 0
    private var loadFlight: LoadFlight?

    func load(client: PostHogClient, projectID: Int) async {
        let scope = ProjectPreferenceScope(projectID: projectID, region: client.region)
        if let loadFlight, loadFlight.scope == scope {
            await loadFlight.task.value
            return
        }

        nextLoadFlightID += 1
        let flightID = nextLoadFlightID
        let task = Task { @MainActor in
            await self.performLoad(client: client, scope: scope)
        }
        loadFlight = LoadFlight(id: flightID, scope: scope, task: task)
        await task.value
        if loadFlight?.id == flightID {
            loadFlight = nil
        }
    }

    private func performLoad(client: PostHogClient, scope: ProjectPreferenceScope) async {
        generation += 1
        let token = generation
        if loadedScope != scope {
            loadedScope = scope
            dashboards = []
            error = nil
            loadedAt = nil
        }
        isLoading = true
        defer {
            if token == generation, loadedScope == scope { isLoading = false }
        }
        do {
            let page: Page<DashboardSummary> = try await client.send(
                PostHogAPI.dashboards(projectID: scope.projectID)
            )
            guard token == generation, loadedScope == scope else { return }
            dashboards = page.results.filter { !$0.title.isEmpty }
            loadedAt = Date()
            error = nil
        } catch {
            guard token == generation, loadedScope == scope else { return }
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    var pinned: [DashboardSummary] { dashboards.filter(\.pinned) }
    var others: [DashboardSummary] { dashboards.filter { !$0.pinned } }

    func contentState(isAvailable: Bool) -> DashboardCollectionContentState {
        guard isAvailable else { return .unavailable }
        if isLoading { return .loading }
        if dashboards.isEmpty, let error { return .failed(error) }
        return dashboards.isEmpty ? .empty : .loaded
    }
}

/// Everything that changes whether the dashboard list may issue a request.
/// Using the whole value as the SwiftUI task id makes capability discovery
/// restart a previously guarded task without requiring a project switch.
struct DashboardListLoadScope: Hashable {
    let scope: ProjectPreferenceScope?
    let isAvailable: Bool

    init(projectID: Int?, region: PostHogRegion?, isAvailable: Bool) {
        scope = if let projectID, let region {
            ProjectPreferenceScope(projectID: projectID, region: region)
        } else {
            nil
        }
        self.isAvailable = isAvailable
    }

    @MainActor
    func load(store: DashboardsStore, client: PostHogClient?) async {
        guard isAvailable, let scope, let client else { return }
        await store.load(client: client, projectID: scope.projectID)
    }
}

struct DashboardsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(OpenDetails.self) private var openDetails
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var store = DashboardsStore()
    @State private var pinnedPreviewStore = DashboardPreviewStore()
    @State private var quickPreviewStore = DashboardPreviewStore()
    @State private var search = ""

    /// The open dashboard's id, and deliberately **not** `@State`.
    ///
    /// See `FlagsRoot.selectedID` for the measurement. Since the tab bar became
    /// a preference this screen can be demoted, a demoted screen is pushed onto
    /// the search tab's stack, and a `NavigationSplitView` nested in a
    /// `NavigationStack` has nowhere to put its detail - so the row opened
    /// nothing at all.
    private var selectedID: Binding<Int?> {
        Binding(
            get: { openDetails[.dashboards] as? Int },
            set: { openDetails[.dashboards] = $0.map(AnyHashable.init) }
        )
    }

    private var selection: DashboardSummary? {
        selectedID.wrappedValue.flatMap { id in store.dashboards.first { $0.id == id } }
    }

    private var loadScope: DashboardListLoadScope {
        DashboardListLoadScope(
            projectID: model.projectID,
            region: model.client?.region,
            isAvailable: model.isAvailable(.dashboards)
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
        Group {
            if sizeClass == .compact {
                // No split view in compact, and that is the fix: this screen is
                // hosted either by its own tab or - since the bar became a
                // preference - by a push on the search tab's stack, and a split
                // view nested in that stack could open nothing at all.
                listChrome
                    .navigationDestination(item: selectedID) { id in
                        dashboardDetail(id: id)
                    }
            } else {
                regularHub
            }
        }
        // Teaches Siri which dashboard this person actually opens.
        //
        // Here rather than in `DashboardDetailView`: the detail screen is also
        // drawn by a restored window, by a deep link, and by
        // `applyDebugSelectionIfNeeded` under the UI tests, none of which is
        // somebody choosing a dashboard.
        .onChange(of: selection) { _, opened in
            guard let opened else { return }
            IntentDonations.dashboardOpened(opened)
        }
        .onChange(of: requestAuthority, initial: true) { _, _ in
            quickPreviewStore.invalidate()
        }
    }

    /// One regular-width stack keeps the project signal, pinned preview and
    /// dashboard cards on one scroll surface. `OpenDetails` remains the only
    /// selection owner, so restoration and a width crossing keep the same
    /// selected dashboard.
    private var regularHub: some View {
        NavigationStack {
            regularLanding
                .navigationDestination(item: selectedID) { id in
                    dashboardDetail(id: id)
                }
        }
    }

    private var regularLanding: some View {
        regularLandingContent
            .topLevelNavigationTitle("Dashboards")
#if os(macOS)
            .toolbar(id: "dashboards") {
                PinnedProjectSwitcher()
                ToolbarSpacer(.flexible)
                ToolbarItem(id: "refresh", placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh dashboards")
                }
            }
#else
            .toolbar { ProjectSwitcher() }
#endif
            .projectSubtitle()
            .screenRefreshable { await load() }
#if !os(tvOS)
            .searchable(text: $search, prompt: "Search dashboards")
#endif
            .task(id: loadScope) {
                await loadScope.load(store: store, client: model.client)
                applyDebugSelectionIfNeeded()
            }
    }

    @ViewBuilder
    private var regularLandingContent: some View {
        switch store.contentState(isAvailable: loadScope.isAvailable) {
        case .unavailable:
            dashboardUnavailable
        case .loading:
            ProgressView("Loading dashboards…")
                .appGround()
        case .failed(let error):
            dashboardLoadFailure(error)
        case .empty:
            EmptyStateView(
                title: "No dashboards",
                systemImage: "square.grid.2x2",
                illustration: .dashboard,
                message: "This project doesn't have any dashboards yet."
            )
        case .loaded:
            VStack(spacing: 0) {
                dashboardListRefreshFailure
                DashboardHub(
                    dashboards: store.dashboards,
                    pinned: store.pinned,
                    others: store.others,
                    loadedAt: store.loadedAt,
                    pinnedPreviewStore: pinnedPreviewStore,
                    search: $search
                ) { dashboard in
                    dashboardHubRow(dashboard)
                }
            }
        }
    }

    @ViewBuilder
    private func dashboardDetail(id: Int) -> some View {
        if let summary = store.dashboards.first(where: { $0.id == id }) {
            DashboardDetailView(
                summary: summary,
                store: openDetails.dashboardStores.store(
                    for: id,
                    projectID: model.projectID
                ),
                onReturnToDashboards: { selectedID.wrappedValue = nil }
            )
                .id("project-\(model.projectID ?? -1)-dashboard-\(id)")
        } else {
            EmptyStateView(
                title: "Dashboard unavailable",
                systemImage: "square.grid.2x2",
                message: "This dashboard is no longer available in the current project.",
                actionTitle: "Back to dashboards",
                action: { selectedID.wrappedValue = nil }
            )
        }
    }

    /// Compact keeps its existing list-to-detail presentation and one list load
    /// task. Regular width owns equivalent chrome in `regularLanding`.
    private var listChrome: some View {
        content
            // Left to its own devices the sidebar took 340pt of an 834pt
            // iPad, leaving the grid too narrow for two columns. The list
            // is titles and one line of description; it does not need more
            // than this, and the charts do.
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            // The tab sidebar already puts a toggle in this bar; the split
            // view added a second, identical one beside it.
            //
            // Removing it is only safe because the column is pinned `.all`
            // rather than left to resolve. The earlier reasoning here — that
            // `InsightPanelOpenKey` drives the column, so the button was
            // redundant — was the bug: the preference only ever *closes* the
            // column, and the reopening path it assumed existed was
            // `.automatic`, which in iPad portrait resolves to detail-only.
            .toolbar(removing: .sidebarToggle)
            .topLevelNavigationTitle("Dashboards")
#if os(macOS)
            // The whole bar in one declaration, and that is load-bearing rather
            // than tidy: a plain `.toolbar { }` beside a `.toolbar(id:)` leaves
            // the window's toolbar refusing customization, which is what greyed
            // out "Customize Toolbar…" here. `PinnedProjectSwitcher` is the
            // switcher rejoining this declaration as an item nobody can move or
            // remove — the measurement is recorded there.
            //
            // Refresh earns a visible control because pull-to-refresh does not
            // exist on the Mac — this and ⌘R are the same closure wearing two
            // coats.
            .toolbar(id: "dashboards") {
                PinnedProjectSwitcher()
                ToolbarSpacer(.flexible)
                ToolbarItem(id: "refresh", placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh dashboards")
                }
            }
#else
            .toolbar { ProjectSwitcher() }
#endif
            .projectSubtitle()
            // **Measured, not reasoned.** `.searchable` compiles on tvOS and
            // is the wrong shape there, and the screenshot of the first build
            // says so plainly: the field is the topmost focusable thing on the
            // screen, so it takes initial focus, and a focused search field on
            // tvOS raises the full-screen grid keyboard. The app opened onto a
            // keyboard covering its own dashboards, before anybody had asked
            // to search anything.
            //
            // Search on tvOS is a destination, not a field above a list — the
            // platform's own shape for it is `Tab(role: .search)`. This target
            // does not compile `Search/`, so there is no destination to point
            // at in v1 and the honest answer is absence: the lists are short,
            // sorted and focus-navigable, and filtering them by picking
            // letters off a grid with a remote was never the affordance that
            // justified covering the screen. The same seam is on every ridden
            // root, each pointing here.
            .screenRefreshable { await load() }
            #if !os(tvOS)
            .searchable(text: $search, prompt: "Search dashboards")
            #endif
            .task(id: loadScope) {
                await loadScope.load(store: store, client: model.client)
                applyDebugSelectionIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.contentState(isAvailable: loadScope.isAvailable) {
        case .unavailable:
            if sizeClass == .compact {
                dashboardUnavailable
            } else {
                // The regular detail column owns the full locked state.
                list
            }
        case .loading:
            if sizeClass == .compact {
                dashboardLoading
            } else {
                list
            }
        case .loaded:
            list
        case .failed(let error):
            if sizeClass == .compact {
                dashboardLoadFailure(error)
            } else {
                // The regular detail column owns the full failure and retry.
                list
            }
        case .empty:
            if sizeClass == .compact {
                EmptyStateView(
                    title: "No dashboards",
                    systemImage: "square.grid.2x2",
                    illustration: .dashboard,
                    message: "This project doesn't have any dashboards yet."
                )
            } else {
                // The regular detail column owns the full branded state.
                list
            }
        }
    }

    private var list: some View {
        List(selection: selectedID) {
            if let presentation = DashboardListRefreshPresentation.resolve(
                dashboardCount: store.dashboards.count,
                error: store.error
            ) {
                dashboardListRefreshFailure(presentation: presentation)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !filtered(store.pinned).isEmpty {
                Section {
                    ForEach(filtered(store.pinned), id: \.self) { row($0) }
                } header: {
                    SectionLabel(text: "Pinned", productMark: .dashboard)
                }
            }
            Section {
                ForEach(filtered(store.others), id: \.self) { row($0) }
            } header: {
                if !filtered(store.pinned).isEmpty {
                    SectionLabel(text: "All dashboards", productMark: .dashboard)
                }
            }
            if let loadedAt = store.loadedAt {
                FreshnessLabel(date: loadedAt)
                    .listRowBackground(Color.clear)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(
            loadScope.isAvailable && store.isLoading && store.dashboards.isEmpty
        )
        // Same shape as the flags list. Without it, a query matching nothing
        // emptied both sections and left the freshness label floating over
        // ~1,600pt of bare page — a blank screen after typing reads as a
        // crash, on the landing tab.
        .overlay {
            if !search.isEmpty,
               filtered(store.pinned).isEmpty,
               filtered(store.others).isEmpty {
                EmptyStateView(
                    title: "No matching dashboards",
                    systemImage: "magnifyingglass",
                    message: "No dashboard title matched “\(search)”."
                )
            }
        }
    }

    private func row(_ dashboard: DashboardSummary) -> some View {
        NavigationLink(value: dashboard.id) {
            dashboardQuickPreview(dashboard) {
                dashboardRowContent(dashboard, in: .navigationLink)
            }
        }
        .dashboardRowSurface()
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("gethog.dashboard-card.\(dashboard.id)")
    }

    private func dashboardHubRow(_ dashboard: DashboardSummary) -> some View {
        Button {
            selectedID.wrappedValue = dashboard.id
        } label: {
            dashboardQuickPreview(dashboard) {
                Card(
                    padding: Theme.Space.m,
                    accent: dashboard.creationMode == .template ? Theme.accentWarm : Theme.accent
                ) {
                    dashboardRowContent(dashboard, in: .button)
                }
            }
        }
        .buttonStyle(.plain)
        .pointerHighlight(cornerRadius: Theme.Radius.medium)
        .accessibilityIdentifier("gethog.dashboard-card.\(dashboard.id)")
    }

    private func dashboardQuickPreview<Row: View>(
        _ dashboard: DashboardSummary,
        @ViewBuilder row: () -> Row
    ) -> some View {
        let scope = requestAuthority.map {
            DashboardPreviewScope(authority: $0, dashboardID: dashboard.id)
        }
        return row().quickPreview {
            DashboardQuickPreview(
                summary: dashboard,
                state: quickPreviewStore.state(for: scope)
            )
                .task(id: scope) {
                    await quickPreviewStore.activate(client: model.client, scope: scope)
                }
        } menuItems: {
            dashboardContextMenu(dashboard)
        }
    }

    private func dashboardRowContent(
        _ dashboard: DashboardSummary,
        in container: DashboardRowContainer
    ) -> some View {
        DataRow(
            glyph: dashboard.creationMode == .template ? "wand.and.stars" : "square.grid.2x2",
            brandGlyph: DashboardBrandAppearance.glyph(for: dashboard.creationMode),
            tint: dashboard.creationMode == .template ? Theme.accentWarm : Theme.accent,
            title: dashboard.title,
            subtitle: dashboard.description,
            footnote: dashboard.lastRefresh.map {
                "Updated \($0.formatted(.relative(presentation: .named)))"
            },
            accessory: container.showsAuthoredChevron ? .chevron : .none,
            // The compact television list uses the native NavigationLink
            // focus slab, which becomes bright and therefore needs semantic
            // foregrounds to follow that effective appearance. Card-style TV
            // rows keep DataRow's stable dark palette instead.
            usesNativeTelevisionFocusSurface: true
        )
    }

    @ViewBuilder
    private func dashboardContextMenu(_ dashboard: DashboardSummary) -> some View {
        Button {
            selectedID.wrappedValue = dashboard.id
        } label: {
            Label("Open Dashboard", systemImage: "arrow.right.circle")
        }
        // The detail's own toolbar has offered this since the tear-off
        // landed; the row it was opened from did not, which put the one
        // affordance a Mac user reaches for behind a navigation step.
        // iOS keeps the menu it had — iPad parity is a separate question
        // about where a torn-off window belongs on a touch device.
        #if os(macOS)
        Button {
            openWindow(value: WindowTarget.dashboard(id: dashboard.id))
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        #endif
    }

    private func filtered(_ items: [DashboardSummary]) -> [DashboardSummary] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func dashboardLoadFailure(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load dashboards", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Try again") { Task { await load() } }
        }
    }

    @ViewBuilder
    private var dashboardListRefreshFailure: some View {
        if let presentation = DashboardListRefreshPresentation.resolve(
            dashboardCount: store.dashboards.count,
            error: store.error
        ) {
            dashboardListRefreshFailure(presentation: presentation)
        }
    }

    private func dashboardListRefreshFailure(presentation: DashboardListRefreshPresentation) -> some View {
        SectionEmptyState(
            text: presentation.message,
            systemImage: "exclamationmark.triangle",
            actionTitle: presentation.actionTitle
        ) {
            Task { await load() }
        }
        .padding(.horizontal, Theme.Space.l)
    }

    private var dashboardLoading: some View {
        ContentUnavailableView(
            "Loading dashboards…",
            systemImage: "square.grid.2x2",
            description: Text("Fetching this project's dashboard list.")
        )
        .accessibilityIdentifier("gethog.load-state.loading")
    }

    private var dashboardUnavailable: some View {
        LockedCapabilityView(
            capability: .dashboards,
            scope: model.lockedScope(for: .dashboards)
        ) {
            Task { await model.refreshCapabilities() }
        }
    }

    private func load() async {
        await loadScope.load(store: store, client: model.client)
    }

    private func applyDebugSelectionIfNeeded() {
        #if DEBUG
        switch DebugLaunch.dashboard {
        case .first:
            selectedID.wrappedValue = (store.pinned.first ?? store.dashboards.first)?.id
        case .id(let id):
            selectedID.wrappedValue = store.dashboards.first { $0.id == id }?.id
        case nil:
            break
        }
        #endif
    }
}

private extension View {
    /// tvOS supplies the focused row surface and matching foreground together.
    /// Painting the iOS card underneath kept the foreground transition while
    /// hiding its light focus fill, producing near-black text on a dark card.
    @ViewBuilder
    func dashboardRowSurface() -> some View {
        #if os(tvOS)
        self
        #else
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
        )
        #endif
    }
}
