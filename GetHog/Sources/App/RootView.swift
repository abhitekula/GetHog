import GetHogKit
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case dashboards, events, sessions, flags
    case webAnalytics, clickmap, people, sql
    case errorTracking, tracing, logs
    case inbox, signals, health
    case experiments, surveys, earlyAccess
    case llm, warehouse, pipelines, automation, actions, annotations
    case notebooks, max, renders
    case groups, taxonomy
    case settings
    /// One field over everything: the app's own screens, and every object in the
    /// project via PostHog's index.
    ///
    /// This is the fifth tab, and it is also the index of everything the phone's
    /// tab bar cannot hold — the two used to be separate and could not both fit.
    /// A phone's bar holds five items; four are product surfaces and the fifth
    /// has to be the way to the other 24 screens. Declaring search as a sixth
    /// `Tab` — even with `TabRole.search`, which reads as though it sits outside
    /// the bar — simply did not appear on iPhone 17 running iOS 26: the bar drew
    /// `Dashboards · Events · Sessions · Flags · More` and search was nowhere.
    ///
    /// So they are one surface. The index already had a search field over 24
    /// screen names; it now searches the project's objects in the same breath,
    /// which is one field where there were two and costs no product surface its
    /// slot. In regular width the sidebar lists every screen itself, so only the
    /// object half is shown there.
    case search

    var title: String {
        switch self {
        case .dashboards: "Dashboards"
        case .events: "Events"
        // Deliberately "Sessions", not "Replays": the tab must never promise
        // video before the player has loaded, and mobile-source recordings can
        // never be played at all.
        case .sessions: "Sessions"
        case .flags: "Flags"
        case .webAnalytics: "Web"
        // "Clickmap", not "Heatmap": without a page screenshot to overlay there
        // is no heat map, and naming it one would promise a picture this app
        // cannot draw.
        case .clickmap: "Clickmap"
        case .people: "People"
        case .sql: "SQL"
        case .errorTracking: "Errors"
        case .tracing: "Tracing"
        case .logs: "Logs"
        case .inbox: "Inbox"
        case .signals: "Signals"
        case .health: "Health"
        case .experiments: "Experiments"
        case .surveys: "Surveys"
        case .earlyAccess: "Early access"
        case .llm: "LLM"
        case .warehouse: "Warehouse"
        case .pipelines: "Pipelines"
        case .automation: "Automation"
        case .actions: "Actions"
        case .annotations: "Annotations"
        case .notebooks: "Notebooks"
        case .max: "Max"
        // "Renders", not "Exports": `GET /exports/` is named for chart exports
        // and returns none — every row is a video render of a session recording,
        // and a tab called "Exports" would promise CSVs that are not on it.
        case .renders: "Renders"
        case .groups: "Groups"
        case .taxonomy: "Taxonomy"
        case .settings: "Settings"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboards: "square.grid.2x2"
        case .events: "bolt"
        case .sessions: "rectangle.stack"
        case .flags: "flag"
        case .webAnalytics: "globe"
        case .clickmap: "cursorarrow.click.2"
        case .people: "person.2"
        case .sql: "terminal"
        case .errorTracking: "exclamationmark.triangle"
        case .tracing: "point.3.connected.trianglepath.dotted"
        case .logs: "text.alignleft"
        case .inbox: "tray.full"
        case .signals: "antenna.radiowaves.left.and.right"
        case .health: "stethoscope"
        case .experiments: "flask"
        case .surveys: "list.clipboard"
        case .earlyAccess: "sparkles"
        case .llm: "brain"
        case .warehouse: "cylinder.split.1x2"
        case .pipelines: "arrow.triangle.branch"
        case .automation: "gearshape.2"
        case .actions: "cursorarrow.rays"
        case .annotations: "note.text"
        case .notebooks: "book"
        case .max: "bubble.left.and.bubble.right"
        case .renders: "film"
        case .groups: "building.2"
        case .taxonomy: "list.bullet.indent"
        case .settings: "gearshape"
        case .search: "magnifyingglass"
        }
    }

    /// Whether the screen brings a navigation container of its own.
    ///
    /// The six list-and-detail screens are `NavigationSplitView`s, which *are* a
    /// navigation container: wrapping one in a `NavigationStack` puts a second,
    /// empty navigation bar above it on iPhone and breaks the two-column layout
    /// on iPad. Everything else is stack-less and gets its stack from whatever
    /// is showing it — a `Tab` in `RootView`, or the index behind "More".
    var ownsNavigationContainer: Bool {
        switch self {
        case .dashboards, .events, .sessions, .flags, .people, .errorTracking: true
        default: false
        }
    }
}

/// One labelled group of destinations.
struct AppTabSection: Identifiable {
    let title: String
    let tabs: [AppTab]

    var id: String { title }
}

extension AppTab {

    /// The four that hold the iPhone tab bar. They stay loose so they occupy it
    /// directly, which is what keeps the surface growable without crowding the
    /// phone.
    static let primary: [AppTab] = [.dashboards, .events, .sessions, .flags]

    /// Everything with a tab of its own at *both* widths — the five a phone's
    /// bar can hold.
    ///
    /// Search is separate from `primary` because it is not a product surface:
    /// it is the fifth slot, and it is where the other 24 screens are reached.
    static let alwaysVisible: [AppTab] = primary + [.search]

    /// Everything else, grouped.
    ///
    /// One array, two consumers: the iPad sidebar builds its `TabSection`s from
    /// it and the iPhone index builds its list from it. Written out twice these
    /// would drift the first time a screen was added to one and not the other,
    /// and the difference would only ever show up on one of the two devices.
    static let sections: [AppTabSection] = [
        AppTabSection(title: "Analyze", tabs: [.webAnalytics, .clickmap, .people, .groups, .sql]),
        AppTabSection(
            title: "Monitor",
            tabs: [.errorTracking, .llm, .tracing, .logs, .inbox, .signals, .health]
        ),
        AppTabSection(
            title: "Data",
            tabs: [.warehouse, .pipelines, .automation, .actions, .annotations, .taxonomy]
        ),
        AppTabSection(title: "Experiment", tabs: [.experiments, .surveys, .earlyAccess]),
        // Renders sit with the other saved artefacts rather than with Sessions:
        // the screen is a library of files somebody kept, not a live analysis
        // surface, and this app can only read it.
        AppTabSection(title: "Workspace", tabs: [.notebooks, .max, .renders]),
    ]

    /// Sits below the sections rather than inside one, in the sidebar and in the
    /// index alike: settings are about the app, not about a part of PostHog.
    static let utility: [AppTab] = [.settings]

    /// Everything the phone reaches through the index rather than the tab bar.
    static let secondary: [AppTab] = sections.flatMap(\.tabs) + utility
}

/// The screen a tab names.
///
/// One switch rather than a view written into each `Tab` declaration: the iPad
/// sidebar and the iPhone index both resolve tabs through here, and a second
/// mapping would be a second thing to keep in step.
struct TabRootView: View {
    let tab: AppTab

    var body: some View {
        switch tab {
        case .dashboards: DashboardsRoot()
        case .events: EventsRoot()
        case .sessions: SessionsRoot()
        case .flags: FlagsRoot()
        case .webAnalytics: WebAnalyticsRoot()
        case .clickmap: HeatmapsRoot()
        case .people: PeopleRoot()
        case .groups: GroupsRoot()
        case .sql: SQLConsoleRoot()
        case .errorTracking: ErrorTrackingRoot()
        case .llm: LLMAnalyticsRoot()
        case .tracing: TracingRoot()
        case .logs: LogsRoot()
        case .inbox: InboxRoot()
        case .signals: SignalsRoot()
        case .health: HealthRoot()
        case .warehouse: WarehouseRoot()
        case .pipelines: PipelinesRoot()
        case .automation: AutomationRoot()
        case .actions: ActionsRoot()
        case .annotations: AnnotationsRoot()
        case .taxonomy: TaxonomyRoot()
        case .experiments: ExperimentsRoot()
        case .surveys: SurveysRoot()
        case .earlyAccess: EarlyAccessRoot()
        case .notebooks: NotebooksRoot()
        case .max: ConversationsRoot()
        case .renders: RendersRoot()
        case .settings: SettingsRoot()
        case .search:
            // Reached through `RootView.searchTab`, which owns the stack this
            // screen's own rows push into. Nothing ever pushes `.search` itself,
            // so this case exists only to keep the switch honest.
            ProjectSearchView()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("selectedTab") private var selectedTab: AppTab = .dashboards
    /// The search tab's stack. Heterogeneous — a screen result pushes an
    /// `AppTab`, the root it lands on then pushes its own issues, logs and
    /// traces into the same stack, and an object result pushes a dashboard or a
    /// flag — so no typed path can hold it.
    @State private var searchPath = NavigationPath()
    @State private var hasAppliedDebugTab = false
    /// Set only when a link could not do what it said. Success is silent; see
    /// `LinkNotice`.
    @State private var linkNotice: LinkNotice?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Connecting…")
                .controlSize(.large)

        case .onboarding:
            OnboardingView()

        case .ready:
            tabs
                .tabViewStyle(.sidebarAdaptable)
                // Gives the tab bar's height back to the data while reading down a
                // long list, which is most of what this app is. It restores itself
                // on the first upward scroll, so nothing becomes unreachable.
                .tabBarMinimizeBehavior(.onScrollDown)
                // Only the four loose tabs get a number: they are the ones always
                // present in the tab bar. Settings takes the platform-conventional
                // comma rather than a fifth number it would have to compete for.
                .keyboardActions([
                    KeyboardAction(key: "1", title: AppTab.dashboards.title) { open(.dashboards) },
                    KeyboardAction(key: "2", title: AppTab.events.title) { open(.events) },
                    KeyboardAction(key: "3", title: AppTab.sessions.title) { open(.sessions) },
                    KeyboardAction(key: "4", title: AppTab.flags.title) { open(.flags) },
                    KeyboardAction(key: ",", title: AppTab.settings.title) { open(.settings) },
                ])
                .onAppear {
                    #if DEBUG
                    // Applied once: `@SceneStorage` would otherwise fight a user who
                    // switched tabs after launch.
                    if !hasAppliedDebugTab {
                        hasAppliedDebugTab = true
                        if let raw = DebugLaunch.initialTab, let tab = AppTab(rawValue: raw) {
                            open(tab)
                        }
                    }
                    #endif
                    restorePushedTab()
                    // Cold launch: a quick action or a URL that started the app
                    // arrived before this body existed, so it is waiting rather
                    // than lost.
                    routePendingLinks()
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
                // The notification above only ever arrives from inside this
                // process. An intent runs in one the system picked, so its
                // hand-off is a write to shared defaults and nothing more — the
                // only moment the app can notice is coming forward.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { routePendingLinks() }
                }
                .onChange(of: model.projectID) { _, id in
                    // The dynamic quick actions name objects in one project, so
                    // they have to be rebuilt whenever that project changes —
                    // otherwise a long-press offers the previous project's
                    // dashboard and opens it against this one's data.
                    QuickActions.refresh(projectID: id)
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
                // A Max-size iPhone in landscape and an iPad in narrow
                // multitasking both cross the size-class boundary while running,
                // which moves a destination between the sidebar and the index.
                .onChange(of: sizeClass) { _, _ in restorePushedTab() }
                .onChange(of: searchPath.isEmpty) { _, isEmpty in
                    // Popping back leaves `selectedTab` naming a screen that is no
                    // longer showing, which the sidebar would then restore on the
                    // next rotation into regular width. At the root it is `.search`.
                    if isEmpty { selectedTab = .search }
                }
        }
    }

    // MARK: - Structure

    /// One `TabView` across both widths rather than two.
    ///
    /// Only the trailing content differs, so the four primary tabs keep their
    /// identity — and therefore their loaded data and scroll position — when a
    /// Max-size iPhone is rotated across the size-class boundary. Two separate
    /// `TabView`s threw all of that away on every rotation.
    private var tabs: some View {
        TabView(selection: tabSelection) {
            tabItems(for: AppTab.primary)

            searchTab

            if sizeClass != .compact {
                sidebarSections
                tabItems(for: AppTab.utility)
            }
        }
    }

    /// The fifth tab, at both widths: an ordinary `Tab`, because that is the only
    /// arrangement observed to actually draw on iPhone.
    ///
    /// It owns the stack, our list, our chrome. SwiftUI's generated "More" list
    /// is what this replaces; `ScreenIndexSections` records what that list cost.
    private var searchTab: some TabContent<AppTab> {
        Tab(
            AppTab.search.title,
            systemImage: AppTab.search.systemImage,
            value: AppTab.search
        ) {
            NavigationStack(path: $searchPath) {
                ProjectSearchView()
                    .navigationDestination(for: AppTab.self) { tab in
                        TabRootView(tab: tab)
                            // Which destination is showing, for the sidebar to
                            // select if this scene becomes regular width, and for
                            // scene restoration. The stack cannot be read back.
                            .onAppear { selectedTab = tab }
                    }
                    // Where a link lands. Registered on this stack rather than a
                    // stack of its own because a link and a search result open
                    // the same objects, and two stacks would mean two back
                    // buttons that behave differently for the same dashboard.
                    .navigationDestination(for: PostHogLink.self) { LinkDestinationView(link: $0) }
            }
        }
    }

    @TabContentBuilder<AppTab>
    private func tabItems(for tabs: [AppTab]) -> some TabContent<AppTab> {
        ForEach(tabs, id: \.self) { tab in
            Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                container(for: tab)
            }
        }
    }

    /// `.sidebarAdaptable` turns these into the iPad sidebar. That arrangement
    /// is good and must stay; only compact width swaps them for the index inside
    /// the search tab.
    @TabContentBuilder<AppTab>
    private var sidebarSections: some TabContent<AppTab> {
        ForEach(AppTab.sections) { section in
            TabSection(section.title) {
                tabItems(for: section.tabs)
            }
        }
    }

    /// The stack a screen navigates in.
    ///
    /// Ownership sits here rather than in the roots because a root that carried
    /// its own stack drew a second navigation bar the moment anything pushed it —
    /// which is what "More" did to 24 screens on iPhone.
    @ViewBuilder
    private func container(for tab: AppTab) -> some View {
        if tab.ownsNavigationContainer {
            TabRootView(tab: tab)
        } else {
            NavigationStack {
                TabRootView(tab: tab)
            }
        }
    }

    // MARK: - Selection

    /// `selectedTab` names a destination; the tab bar and the sidebar can each
    /// show only the subset they have a row for.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: {
                if sizeClass == .compact {
                    // Nothing past the fifth has a tab of its own on a phone;
                    // those destinations sit on the search tab's stack, and
                    // search is the tab selected while one of them is showing.
                    AppTab.alwaysVisible.contains(selectedTab) ? selectedTab : .search
                } else {
                    // Every tab has a sidebar row of its own in regular width,
                    // search included, so nothing needs translating here.
                    selectedTab
                }
            },
            set: { selectedTab = $0 }
        )
    }

    /// Goes to a destination by name, from a keyboard shortcut or `GETHOG_TAB`.
    ///
    /// In compact width a secondary destination means selecting search *and*
    /// pushing, replacing whatever was pushed before rather than landing behind
    /// it: `⌘,` has to reach Settings from anywhere.
    private func open(_ tab: AppTab) {
        selectedTab = tab
        guard sizeClass == .compact else { return }
        if AppTab.secondary.contains(tab) {
            var path = NavigationPath()
            path.append(tab)
            searchPath = path
        } else if tab == .search {
            // `GETHOG_TAB=search` means the field, so it has to clear anything
            // standing in front of it — search is this stack's *root*, and
            // leaving a pushed screen there would show that screen instead, under
            // a second navigation bar.
            searchPath = NavigationPath()
        }
    }

    // MARK: - Links

    /// Drains everything waiting to be navigated to.
    ///
    /// Both mailboxes, because an intent that opens the app and a tapped link
    /// are the same request as far as this view is concerned: go somewhere.
    private func routePendingLinks() {
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

    /// Goes where a link points, or explains why it can't.
    ///
    /// The project is settled before the object, and a project this key cannot
    /// see stops the whole thing. Resolving the object id against whichever
    /// project happened to be selected would draw one project's dashboard 128
    /// from another project's data — which is the reason the project switcher is
    /// on every screen in the first place.
    ///
    /// A *successful* switch says nothing. The project's name is the navigation
    /// subtitle of every screen in this app, so an alert announcing it would
    /// interrupt the user to repeat what the screen behind the alert already
    /// says.
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
            // Replaces rather than stacks, for the same reason `⌘,` does: a link
            // has to arrive at its destination from wherever the app was, not
            // behind whatever was already pushed.
            var path = NavigationPath()
            path.append(target.link)
            searchPath = path
        }
    }

    /// Puts a secondary destination back on the search tab's stack.
    ///
    /// `selectedTab` is scene storage and survives a relaunch; the stack is
    /// `@State` and does not. Without this, `GETHOG_TAB=errorTracking` — and
    /// a restored scene — would select search and stop there instead of landing
    /// on the screen.
    private func restorePushedTab() {
        guard sizeClass == .compact,
              searchPath.isEmpty,
              AppTab.secondary.contains(selectedTab)
        else { return }
        searchPath.append(selectedTab)
    }
}

/// Always-visible project context.
///
/// Showing one project's numbers under another project's name is a correctness
/// bug, not a cosmetic one, so this sits in the toolbar of every root screen.
struct ProjectSwitcher: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Project", selection: Binding(
                    get: { model.selectedProject?.id ?? -1 },
                    set: { id in
                        model.selectedProject = model.projects.first { $0.id == id }
                    }
                )) {
                    ForEach(model.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                if let org = model.me?.organization?.name {
                    Divider()
                    Text(org)
                }
            } label: {
                // A glyph, not the project name. The name is permanently
                // visible as the navigation subtitle, and repeating it here
                // made the item wide enough that it could not share the bar
                // with a back button — costing a whole row of chrome on every
                // pushed screen.
                Image(systemName: "building.2")
            }
            .accessibilityLabel("Current project: \(model.selectedProject?.name ?? "none"). Double tap to switch.")
        }
    }
}
