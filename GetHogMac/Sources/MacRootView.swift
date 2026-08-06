import GetHogKit
import SwiftUI

/// The Mac shell. The same one-`TabView` architecture as `RootView` — and the
/// same `AppTab.sections` source of truth, third consumer — rendered as a real
/// sidebar by `.sidebarAdaptable`, with every compact-width mechanism deleted
/// rather than ported: no sheet hoisting (details push inline), no "More"
/// index, no tab-slot preference. Settings has no sidebar row; the `Settings`
/// scene owns ⌘,.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @SceneStorage("selectedTab") private var selectedTab: AppTab = .dashboards
    /// The search tab's stack — heterogeneous for the reason RootView's is:
    /// screen results push `AppTab`, links push `PostHogLink`.
    @State private var searchPath = NavigationPath()
    @State private var openDetails = OpenDetails()
    /// One object above list and detail, as on iOS — see RootView for the
    /// disagreement this prevents.
    @State private var surveyLifecycle = SurveyLifecycleController()
    @State private var experimentLifecycle = ExperimentLifecycleController()
    /// Same store key as the iPad sidebar, per the spec: one arrangement
    /// preference, whichever platform is looking at it.
    @AppStorage("sidebarCustomization") private var sidebarCustomization = TabViewCustomization()
    /// Set only when a link could not do what it said. Success is silent.
    @State private var linkNotice: LinkNotice?
    @State private var hasAppliedDebugTab = false

    /// The sidebar's shape, named statically so shell tests can pin it without
    /// mounting a view: Search loose at the top, then every section, Settings
    /// nowhere.
    static let looseTabs: [AppTab] = [.search]
    static let sections: [AppTabSection] = AppTab.sections

    var body: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: Theme.Space.m) {
                BrandConnectingAccent()
                ProgressView("Connecting…")
                    .controlSize(.large)
            }

        case .onboarding:
            OnboardingView()

        case .ready:
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            searchTab
            sidebarSections
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($sidebarCustomization)
        // Nothing typed into this app is a sentence by default — see RootView's
        // note for the measurement. The Mac half of that pair is autocorrection;
        // there is no software keyboard to stop capitalising.
        .autocorrectionDisabled()
        .environment(openDetails)
        // The Go menu's whole surface (Task 5). Published from the ready phase
        // only, so the menu items are correctly disabled while the app is still
        // connecting or asking for a key.
        .focusedSceneValue(\.openTab, OpenTabAction { open($0) })
        .onAppear {
            // Scene storage can only hold what this shell wrote, but the guard
            // costs one line and a selection with no sidebar row costs a launch.
            if selectedTab == .settings { selectedTab = .dashboards }
            // Cold launch: a URL that started the app arrived before this body
            // existed, so it is waiting rather than lost.
            routePendingLinks()
            #if DEBUG
            // Last, for the reason RootView records: the mailbox above can
            // navigate, and an explicitly requested launch destination is the
            // most specific instruction the process has.
            if !hasAppliedDebugTab {
                hasAppliedDebugTab = true
                if let raw = DebugLaunch.initialTab, let tab = AppTab(rawValue: raw) {
                    open(tab)
                }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: LinkInbox.didChangeNotification)) { _ in
            routePendingLinks()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: IntentNavigationTarget.didChangeNotification
            )
        ) { _ in
            routePendingLinks()
        }
        // The menu bar's poke. Needed because a popover click does not
        // foreground the app the way opening it from the Dock would, so unlike
        // every other entrance there is no scene-phase change below to
        // piggyback on — the record would otherwise sit unread until something
        // else woke this shell.
        .onReceive(
            NotificationCenter.default.publisher(for: MacMenuBar.pendingOpenNotification)
        ) { _ in
            routePendingLinks()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { routePendingLinks() }
        }
        .alert(
            linkNotice?.title ?? "",
            isPresented: Binding(
                get: { linkNotice != nil },
                set: { if !$0 { linkNotice = nil } }
            ),
            presenting: linkNotice
        ) { notice in
            if let url = notice.webURL {
                Button("Open in PostHog") { openURL(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        // Beside the link notice for the same reason it is: a failed
        // organization switch has no screen of its own to report on, and the
        // switcher that started it is a menu that has already dismissed itself.
        .alert(
            "Couldn't switch organization",
            isPresented: Binding(
                get: { model.organizationError != nil },
                set: { if !$0 { model.organizationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.organizationError ?? "")
        }
        .environment(surveyLifecycle)
        .environment(experimentLifecycle)
    }

    // MARK: - Structure

    private var searchTab: some TabContent<AppTab> {
        Tab(AppTab.search.title, systemImage: AppTab.search.systemImage, value: AppTab.search) {
            NavigationStack(path: $searchPath) {
                ProjectSearchView()
                    .navigationDestination(for: AppTab.self) { tab in
                        TabRootView(tab: tab)
                            .onAppear { selectedTab = tab }
                    }
                    // Where a link lands. On this stack rather than one of its
                    // own because a link and a search result open the same
                    // objects — see RootView's twin.
                    .navigationDestination(for: PostHogLink.self) { LinkDestinationView(link: $0) }
            }
        }
    }

    /// Written as `@TabContentBuilder<AppTab>` members rather than inline, for
    /// the reason `RootView` writes its own that way: the builder cannot infer
    /// one tab value type across a loose `Tab` and a `ForEach` of sections.
    @TabContentBuilder<AppTab>
    private var sidebarSections: some TabContent<AppTab> {
        // Every section, unfiltered — the Mac has no loose product tabs to
        // exclude, so `AppTab.sections` is used directly rather than through
        // `groupedScreens(excluding:)`.
        ForEach(Self.sections) { section in
            TabSection(section.title) {
                tabItems(for: section.tabs)
            }
            // The same ids as the iPad sidebar, so one stored arrangement means
            // the same thing on both.
            .customizationID("section.\(section.title)")
        }
    }

    @TabContentBuilder<AppTab>
    private func tabItems(for tabs: [AppTab]) -> some TabContent<AppTab> {
        ForEach(tabs, id: \.self) { tab in
            Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                container(for: tab)
            }
            .customizationID(tab.rawValue)
        }
    }

    /// Every Mac window is regular width (`MacAdaptations` pins the size
    /// class), so the seven split-view screens always own their container.
    @ViewBuilder
    private func container(for tab: AppTab) -> some View {
        if tab.ownsNavigationContainer(compact: false) {
            TabRootView(tab: tab)
        } else {
            NavigationStack {
                inlineDetailHost(for: tab)
            }
        }
    }

    /// The Mac ending of the sheet-hoisting story: the four screens that write
    /// a detail into `OpenDetails` and stop get that detail *pushed* here —
    /// same `DetailSheetView` switch, same clear-on-dismiss contract (a pop
    /// writes nil back through the binding), no sheet.
    @ViewBuilder
    private func inlineDetailHost(for tab: AppTab) -> some View {
        if tab.presentsDetailAsSheet {
            TabRootView(tab: tab)
                .navigationDestination(item: detailBinding(for: tab)) { detail in
                    DetailSheetView(presented: PresentedDetail(tab: tab, detail: detail))
                }
        } else {
            TabRootView(tab: tab)
        }
    }

    private func detailBinding(for tab: AppTab) -> Binding<AnyHashable?> {
        Binding(
            get: { openDetails[tab] },
            set: { openDetails[tab] = $0 }
        )
    }

    // MARK: - Navigation

    /// Goes to a destination by name — from the Go menu (through `\.openTab`),
    /// a link, or `GETHOG_TAB`. Settings has no row; ⌘, territory.
    private func open(_ tab: AppTab) {
        guard tab != .settings else {
            openSettings()
            return
        }
        selectedTab = tab
        // Asking for search means the field, not whatever the stack last held —
        // same reset, same reason, as RootView.
        if tab == .search { searchPath = NavigationPath() }
    }

    /// Drains everything waiting to be navigated to.
    private func routePendingLinks() {
        // The menu bar extra's landing path — the same `PendingOpen` record a
        // widget writes on iOS, consumed under `RootView`'s rules because it is
        // the same record: the metric routes to the dashboard it was read from,
        // carried with the project the snapshot names so `open(_:)` refuses
        // rather than showing another project's dashboard under the same
        // number; an unknown id routes one honest level up; and it is consumed
        // either way, so a stale request cannot redirect a later launch.
        if let pending = SharedSnapshotStore.shared.pendingOpen() {
            SharedSnapshotStore.shared.clearPendingOpen()
            let snapshot = SharedSnapshotStore.shared.loadOrNil()
            if let metricID = pending.metricID,
               let dashboardID = snapshot?.metric(id: metricID)?.dashboardID,
               let projectID = snapshot?.projectID {
                open(PostHogLinkTarget(projectID: projectID, link: .dashboard(id: dashboardID)))
            } else {
                open(.dashboards)
            }
        }
        if let target = IntentNavigationTarget.consume() {
            if let staged = target.stagedQuery {
                LinkInbox.stage(query: staged.term, for: staged.tab)
            }
            open(target.linkTarget)
        }
        if let url = LinkInbox.consume() {
            guard let target = PostHogLinkParser.parse(url) else {
                linkNotice = .unrecognised(url)
                return
            }
            open(target)
        }
    }

    /// Goes where a link points, or explains why it can't — see RootView's
    /// twin for the project-first rationale.
    private func open(_ target: PostHogLinkTarget) {
        if let projectID = target.projectID, case .inaccessible = model.selectProject(id: projectID) {
            linkNotice = .inaccessibleProject(id: projectID)
            return
        }

        switch target.link {
        case .screen(let tab):
            open(tab)
        default:
            guard target.link.opensInApp else {
                linkNotice = .noScreen(
                    link: target.link,
                    webURL: target.link.webPath.flatMap(model.webURL(path:))
                )
                return
            }
            selectedTab = .search
            var path = NavigationPath()
            path.append(target.link)
            searchPath = path
        }
    }
}
