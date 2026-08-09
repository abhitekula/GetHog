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

@MainActor
@Observable
final class DashboardsStore {
    private struct LoadFlight {
        let id: Int
        let projectID: Int
        let task: Task<Void, Never>
    }

    var dashboards: [DashboardSummary] = []
    var isLoading = true
    var error: String?
    var loadedAt: Date?
    private var loadedProjectID: Int?
    private var generation = 0
    private var nextLoadFlightID = 0
    private var loadFlight: LoadFlight?

    func load(client: PostHogClient, projectID: Int) async {
        if let loadFlight, loadFlight.projectID == projectID {
            await loadFlight.task.value
            return
        }

        nextLoadFlightID += 1
        let flightID = nextLoadFlightID
        let task = Task { @MainActor in
            await self.performLoad(client: client, projectID: projectID)
        }
        loadFlight = LoadFlight(id: flightID, projectID: projectID, task: task)
        await task.value
        if loadFlight?.id == flightID {
            loadFlight = nil
        }
    }

    private func performLoad(client: PostHogClient, projectID: Int) async {
        generation += 1
        let token = generation
        if loadedProjectID != projectID {
            loadedProjectID = projectID
            dashboards = []
            error = nil
            loadedAt = nil
        }
        isLoading = true
        defer {
            if token == generation, loadedProjectID == projectID { isLoading = false }
        }
        do {
            let page: Page<DashboardSummary> = try await client.send(
                PostHogAPI.dashboards(projectID: projectID)
            )
            guard token == generation, loadedProjectID == projectID else { return }
            dashboards = page.results.filter { !$0.title.isEmpty }
            loadedAt = Date()
            error = nil
        } catch {
            guard token == generation, loadedProjectID == projectID else { return }
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
    let projectID: Int?
    let isAvailable: Bool

    init(projectID: Int?, isAvailable: Bool) {
        self.projectID = projectID
        self.isAvailable = isAvailable
    }

    @MainActor
    func load(store: DashboardsStore, client: PostHogClient?) async {
        guard isAvailable, let projectID, let client else { return }
        await store.load(client: client, projectID: projectID)
    }
}

enum DashboardNavigationPath {
    static func path(for selection: Int?) -> [Int] {
        selection.map { [$0] } ?? []
    }

    static func selection(from path: [Int]) -> Int? {
        path.last
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
    @State private var pinnedPreviewStore = PinnedDashboardPreviewStore()
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

    /// The navigation stack is only a presentation of `OpenDetails`; it must
    /// not become a second selection owner when this screen crosses widths.
    private var regularPath: Binding<[Int]> {
        Binding(
            get: { DashboardNavigationPath.path(for: selectedID.wrappedValue) },
            set: { selectedID.wrappedValue = DashboardNavigationPath.selection(from: $0) }
        )
    }

    private var selection: DashboardSummary? {
        selectedID.wrappedValue.flatMap { id in store.dashboards.first { $0.id == id } }
    }

    private var loadScope: DashboardListLoadScope {
        DashboardListLoadScope(
            projectID: model.projectID,
            isAvailable: model.isAvailable(.dashboards)
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
                        if let summary = store.dashboards.first(where: { $0.id == id }) {
                            DashboardDetailView(
                                summary: summary,
                                store: openDetails.dashboardStores.store(
                                    for: id,
                                    projectID: model.projectID
                                )
                            )
                            .id("project-\(model.projectID ?? -1)-dashboard-\(id)")
                        }
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
    }

    /// One regular-width stack keeps the project signal, pinned preview and
    /// dashboard cards on one scroll surface. `regularPath` remains derived
    /// from `OpenDetails`, so restoration and a width crossing keep the same
    /// selected dashboard.
    private var regularHub: some View {
        NavigationStack(path: regularPath) {
            regularLanding
                .navigationDestination(for: Int.self) { id in
                    dashboardDetail(id: id)
                }
        }
    }

    private var regularLanding: some View {
        regularLandingContent
            .navigationTitle("Dashboards")
#if os(macOS)
            .toolbar(id: "dashboards") {
                PinnedProjectSwitcher()
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
#if !os(tvOS)
            .searchable(text: $search, prompt: "Search dashboards")
#endif
            .screenRefreshable { await load() }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            EmptyView()
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
            .navigationTitle("Dashboards")
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
            #if !os(tvOS)
            .searchable(text: $search, prompt: "Search dashboards")
            #endif
            .screenRefreshable { await load() }
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
        case .loading, .loaded:
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
            dashboardRowContent(dashboard)
        }
        .dashboardRowSurface()
        .listRowSeparator(.hidden)
        .contextMenu { dashboardContextMenu(dashboard) }
    }

    private func dashboardHubRow(_ dashboard: DashboardSummary) -> some View {
        Button {
            selectedID.wrappedValue = dashboard.id
        } label: {
            Card(
                padding: Theme.Space.m,
                accent: dashboard.creationMode == .template ? Theme.accentWarm : Theme.accent
            ) {
                dashboardRowContent(dashboard)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { dashboardContextMenu(dashboard) }
        .accessibilityIdentifier("gethog.dashboard-card.\(dashboard.id)")
    }

    private func dashboardRowContent(_ dashboard: DashboardSummary) -> some View {
        DataRow(
            glyph: dashboard.creationMode == .template ? "wand.and.stars" : "square.grid.2x2",
            brandGlyph: DashboardBrandAppearance.glyph(for: dashboard.creationMode),
            tint: dashboard.creationMode == .template ? Theme.accentWarm : Theme.accent,
            title: dashboard.title,
            subtitle: dashboard.description,
            footnote: dashboard.lastRefresh.map {
                "Updated \($0.formatted(.relative(presentation: .named)))"
            },
            accessory: .none
        )
    }

    @ViewBuilder
    private func dashboardContextMenu(_ dashboard: DashboardSummary) -> some View {
            // The detail's own toolbar has offered this since the tear-off
            // landed; the row it was opened from did not, which put the one
            // affordance a Mac user reaches for behind a navigation step.
            // iOS keeps the menu it had — iPad parity is a separate question
            // about where a torn-off window belongs on a touch device.
            #if os(macOS)
            Button {
                openWindow(value: WindowTarget.dashboard(id: dashboard.id))
            } label: {
                Label("Open in new window", systemImage: "macwindow.badge.plus")
            }
            #endif
            #if !os(tvOS)
            // Both entries need something tvOS does not have: a browser to open
            // the link in, and a pasteboard to copy it to. `Link` compiles
            // there and silently does nothing when pressed, which on a focus
            // platform is worse than absence — it is a stop on the focus walk
            // that leads nowhere.
            if let url = model.webURL(path: "dashboard/\(dashboard.id)") {
                Link(destination: url) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("Copy link", systemImage: "link")
                }
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
                .padding(.vertical, 1)
        )
        #endif
    }
}
