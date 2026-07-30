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
    /// The index of everything the phone's tab bar cannot hold. A container,
    /// not a product surface, and never selectable in regular width — the
    /// sidebar gives every destination a row of its own there.
    case more

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
        case .more: "More"
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
        case .more: "ellipsis"
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
        case .more:
            // A container, not a destination: nothing ever pushes `.more`.
            EmptyView()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("selectedTab") private var selectedTab: AppTab = .dashboards
    /// The index's stack. Heterogeneous — the index pushes an `AppTab`, and the
    /// root it lands on then pushes its own issues, logs and traces into the
    /// same stack — so a typed `[AppTab]` path cannot hold it.
    @State private var morePath = NavigationPath()
    @State private var hasAppliedDebugTab = false

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
                }
                // A Max-size iPhone in landscape and an iPad in narrow
                // multitasking both cross the size-class boundary while running,
                // which moves a destination between the sidebar and the index.
                .onChange(of: sizeClass) { _, _ in restorePushedTab() }
                .onChange(of: morePath.isEmpty) { _, isEmpty in
                    // Popping back leaves `selectedTab` naming a screen that is no
                    // longer showing, which the sidebar would then restore on the
                    // next rotation into regular width. At the index it is `.more`.
                    if isEmpty { selectedTab = .more }
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

            if sizeClass == .compact {
                moreTab
            } else {
                sidebarSections
                tabItems(for: AppTab.utility)
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

    /// One tab, our list, our stack. SwiftUI's generated "More" list is what
    /// this replaces; `MoreIndexView` records what that list cost.
    private var moreTab: some TabContent<AppTab> {
        Tab(AppTab.more.title, systemImage: AppTab.more.systemImage, value: AppTab.more) {
            NavigationStack(path: $morePath) {
                MoreIndexView()
                    .navigationDestination(for: AppTab.self) { tab in
                        TabRootView(tab: tab)
                            // Which destination is showing, for the sidebar to
                            // select if this scene becomes regular width, and for
                            // scene restoration. The stack cannot be read back.
                            .onAppear { selectedTab = tab }
                    }
            }
        }
    }

    /// `.sidebarAdaptable` turns these into the iPad sidebar. That arrangement
    /// is good and must stay; only compact width swaps them for the index.
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
                    // Nothing past the fourth has a tab of its own on a phone;
                    // those destinations sit on the index's stack, and the index
                    // is the tab that is selected while one of them is showing.
                    AppTab.primary.contains(selectedTab) ? selectedTab : .more
                } else {
                    // The index does not exist in regular width, and selecting a
                    // tab that isn't there leaves the whole detail area blank.
                    selectedTab == .more ? .dashboards : selectedTab
                }
            },
            set: { selectedTab = $0 }
        )
    }

    /// Goes to a destination by name, from a keyboard shortcut or `GETHOG_TAB`.
    ///
    /// In compact width that means selecting the index *and* pushing, and it
    /// replaces whatever the index had pushed before rather than landing behind
    /// it: `⌘,` has to reach Settings from anywhere.
    private func open(_ tab: AppTab) {
        selectedTab = tab
        guard sizeClass == .compact, AppTab.secondary.contains(tab) else { return }
        var path = NavigationPath()
        path.append(tab)
        morePath = path
    }

    /// Puts a secondary destination back on the index's stack.
    ///
    /// `selectedTab` is scene storage and survives a relaunch; the stack is
    /// `@State` and does not. Without this, `GETHOG_TAB=errorTracking` — and
    /// a restored scene — would select the index and stop there instead of
    /// landing on the screen.
    private func restorePushedTab() {
        guard sizeClass == .compact,
              morePath.isEmpty,
              AppTab.secondary.contains(selectedTab)
        else { return }
        morePath.append(selectedTab)
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
