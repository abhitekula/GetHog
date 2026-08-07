import GetHogKit
import GetHogUI
import SwiftUI

/// The Vision shell. The same one-`TabView` architecture as `RootView` and
/// `MacRootView`, and the same `AppTab.sections` source of truth — fourth
/// consumer — rendered as a sidebar by `.sidebarAdaptable`. Details push inline
/// as they do on the Mac: no sheet hoisting, no "More" index, no tab-slot
/// preference.
///
/// Three deliberate differences from the Mac shell, each commented where it
/// happens: Settings keeps a sidebar row, because visionOS has no `Settings`
/// scene to own ⌘,; there is no menu-bar observer and no `focusedSceneValue`,
/// because no command surface exists here to read one; and both halves of
/// `RootView`'s text-input rule apply, because Vision does have a software
/// keyboard to stop capitalising.
struct VisionRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @SceneStorage("selectedTab") private var selectedTab: AppTab = .dashboards
    /// The search tab's stack — heterogeneous for the reason the other two
    /// shells' are: screen results push `AppTab`, links push `PostHogLink`.
    @State private var searchPath = NavigationPath()
    @State private var openDetails = OpenDetails()
    /// One object above list and detail, as on iOS — see `RootView` for the
    /// disagreement this prevents.
    @State private var surveyLifecycle = SurveyLifecycleController()
    @State private var experimentLifecycle = ExperimentLifecycleController()
    /// The same store key, and the same `customizationID`s below it, as the
    /// iPad and Mac sidebars. The stored value does not travel between
    /// platforms — `@AppStorage` reads this process's own `UserDefaults` — so
    /// what the shared vocabulary buys is that one key cannot come to mean two
    /// arrangements.
    @AppStorage("sidebarCustomization") private var sidebarCustomization = TabViewCustomization()
    /// Set only when a link could not do what it said. Success is silent.
    @State private var linkNotice: LinkNotice?
    @State private var hasAppliedDebugTab = false

    /// The sidebar's shape, named statically so shell tests can pin it without
    /// mounting a view: Search loose at the top, then every section, then
    /// Settings loose at the bottom.
    static let looseTabs: [AppTab] = [.search]
    static let sections: [AppTabSection] = AppTab.sections
    static let utilityTabs: [AppTab] = AppTab.utility

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
            utilitySection
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($sidebarCustomization)
        // Nothing typed into this app is a sentence by default — see
        // `RootView` for the measurement across ~29 search fields. Unlike the
        // Mac, both halves of that rule apply here: Vision has a software
        // keyboard, so there is something to stop capitalising.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .environment(openDetails)
        .onAppear {
            // Cold launch: a URL that started the app arrived before this body
            // existed, so it is waiting rather than lost.
            routePendingLinks()
            #if DEBUG
            // Last, for the reason `RootView` records: the mailbox above can
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
        // The notification above only ever arrives from inside this process. An
        // intent runs in one the system picked, so its hand-off is a write to
        // shared defaults and nothing more — the only moment the app can notice
        // is coming forward.
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
                            // Which destination is showing, for scene
                            // restoration; the stack cannot be read back.
                            .onAppear { selectedTab = tab }
                    }
                    // Where a link lands. On this stack rather than one of its
                    // own because a link and a search result open the same
                    // objects — see `RootView`'s twin.
                    .navigationDestination(for: PostHogLink.self) { LinkDestinationView(link: $0) }
            }
        }
    }

    /// Written as `@TabContentBuilder<AppTab>` members rather than inline, for
    /// the reason the other two shells write theirs that way: the builder
    /// cannot infer one tab value type across a loose `Tab` and a `ForEach` of
    /// sections.
    @TabContentBuilder<AppTab>
    private var sidebarSections: some TabContent<AppTab> {
        // Every section, unfiltered — there are no loose product tabs here to
        // exclude, so `AppTab.sections` is used directly rather than through
        // `groupedScreens(excluding:)`.
        ForEach(Self.sections) { section in
            TabSection(section.title) {
                tabItems(for: section.tabs)
            }
            // The same ids as the iPad and Mac sidebars, so one stored
            // arrangement means the same thing on all three.
            .customizationID("section.\(section.title)")
        }
    }

    /// Settings, below the sections rather than inside one — the iPad's
    /// `AppTab.utility` convention, and the difference from the Mac shell,
    /// which has a `Settings` scene on ⌘, to route to instead. visionOS has no
    /// such scene, so a row is the only way in.
    @TabContentBuilder<AppTab>
    private var utilitySection: some TabContent<AppTab> {
        tabItems(for: Self.utilityTabs)
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

    /// Vision windows are regular width today, but unlike the Mac — where
    /// `MacAdaptations` pins the size class to a constant — nothing here says
    /// so, so the live environment answers. Same guard as `RootView`, for the
    /// same measured silent failures.
    @ViewBuilder
    private func container(for tab: AppTab) -> some View {
        if tab.ownsNavigationContainer(compact: sizeClass == .compact) {
            TabRootView(tab: tab)
        } else {
            NavigationStack {
                inlineDetailHost(for: tab)
            }
        }
    }

    /// The non-iOS ending of the sheet-hoisting story: the four screens that
    /// write a detail into `OpenDetails` and stop get that detail *pushed* here
    /// — same `DetailSheetView` switch, same clear-on-dismiss contract (a pop
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

    /// Goes to a destination by name — from a link or from `GETHOG_TAB`.
    /// Settings has a sidebar row here, so unlike the Mac it is just a
    /// selection with no ⌘, special case.
    private func open(_ tab: AppTab) {
        selectedTab = tab
        // Asking for search means the field, not whatever the stack last held —
        // same reset, same reason, as the other two shells.
        if tab == .search { searchPath = NavigationPath() }
    }

    /// Drains everything waiting to be navigated to.
    private func routePendingLinks() {
        // The same `PendingOpen` record a widget writes on iOS, consumed under
        // `RootView`'s rules because it is the same record: the metric routes
        // to the dashboard it was read from, carried with the project the
        // snapshot names so `open(_:)` refuses rather than showing another
        // project's dashboard under the same number; an unknown id routes one
        // honest level up; and it is consumed either way, so a stale request
        // cannot redirect a later launch. Nothing writes it on visionOS yet —
        // this shell is simply already correct when something does.
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

    /// Goes where a link points, or explains why it can't — see `RootView`'s
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
