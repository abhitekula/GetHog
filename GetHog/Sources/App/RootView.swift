import GetHogKit
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case dashboards, events, sessions, flags
    /// The saved-insight library.
    ///
    /// A screen of its own rather than a corner of Dashboards, because saved
    /// insights and dashboards are different collections. An insight saved from
    /// the console's own editor can belong to no dashboard at all, so before
    /// this tab existed the app could not reach it by any route.
    case insights
    case webAnalytics, clickmap, people, sql
    case errorTracking, sessionSummaries, tracing, logs
    case support, inbox, signals, health, ingestion
    case experiments, surveys, earlyAccess
    case llm, warehouse, pipelines, automation, actions, annotations
    case notebooks, max, renders, templates
    case groups, taxonomy
    case settings
    /// One field over everything: the app's own screens, and every object in the
    /// project via PostHog's index.
    ///
    /// This is the fifth tab, and it is also the index of everything the phone's
    /// tab bar cannot hold — the two used to be separate and could not both fit.
    /// A phone's bar holds five items; four are product surfaces and the fifth
    /// has to be the way to every screen in `AppTab.secondary` — Settings
    /// included, since the index is the only route to it on a phone.
    ///
    /// Screens are named through the array rather than counted in prose, so the
    /// explanation stays current as screens are added.
    ///
    /// So they are one surface. The index already had a search field over the
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
        // "Insights", the console's own word for the collection. Deliberately
        // not "Charts": a saved insight is a saved *question*, and five of this
        // project's are HogQL queries this app draws no chart for at all.
        case .insights: "Insights"
        case .webAnalytics: "Web"
        // "Clickmap", not "Heatmap" — and the reason has changed, so the old one
        // is not left standing. It used to be that no page screenshot existed to
        // overlay. One does now, and the app draws it.
        //
        // The name stays for three reasons that survive that: a render exists
        // only for URLs somebody saved in the web console (one, here, against a
        // whole site's traffic), the aggregate charts span *every* URL so no
        // single page image backs them, and what is drawn is discrete points
        // rather than a smoothed density field. "Heatmap" would promise the
        // picture on every visit and deliver it almost never.
        case .clickmap: "Clickmap"
        case .people: "People"
        case .sql: "SQL"
        case .errorTracking: "Errors"
        // "Summaries", not "AI summaries": the screen's own header says a model
        // wrote them, and the tab has to fit a sidebar row beside "Ingestion".
        case .sessionSummaries: "Summaries"
        case .tracing: "Tracing"
        case .logs: "Logs"
        // "Support", the name PostHog's own console gives the product at
        // `/support/tickets`. Deliberately not "Conversations", which is the API
        // prefix it shares with Max — two products, one namespace, and the tab
        // bar is the last place to reproduce that ambiguity.
        case .support: "Support"
        case .inbox: "Inbox"
        case .signals: "Signals"
        case .health: "Health"
        // "Ingestion", not "Warnings": the screen answers "is my data arriving
        // intact", and a tab called Warnings sits next to Health and Errors
        // saying nothing about which of the three it is.
        case .ingestion: "Ingestion"
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
        // "Templates", not "Dashboard templates": the word already sits under a
        // sidebar heading, and the longer name is the one that truncates.
        case .templates: "Templates"
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
        // The same glyph used for line-chart tiles and verified by
        // `SymbolNameTests`.
        case .insights: "chart.xyaxis.line"
        case .webAnalytics: "globe"
        case .clickmap: "cursorarrow.click.2"
        case .people: "person.2"
        case .sql: "terminal"
        case .errorTracking: "exclamationmark.triangle"
        // The Sessions glyph with sparkles on it: these *are* sessions, read by
        // a model, and the family resemblance is the point.
        case .sessionSummaries: "sparkles.rectangle.stack"
        case .tracing: "point.3.connected.trianglepath.dotted"
        case .logs: "text.alignleft"
        case .support: "lifepreserver"
        case .inbox: "tray.full"
        case .signals: "antenna.radiowaves.left.and.right"
        case .health: "stethoscope"
        // `arrow.down.circle.badge.exclamationmark` does not exist — the badge
        // family only runs to `.pause` and `.xmark` — so this tab rendered an
        // empty tile. `bolt.trianglebadge.exclamationmark` is real, and it is
        // the Events glyph with a warning on it, which is what an ingestion
        // warning is. `MonitorRoots` names the same symbol for the same reason.
        case .ingestion: "bolt.trianglebadge.exclamationmark"
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
        case .templates: "rectangle.on.rectangle.angled"
        case .groups: "building.2"
        case .taxonomy: "list.bullet.indent"
        case .settings: "gearshape"
        case .search: "magnifyingglass"
        }
    }

    /// Whether the screen shows its open detail in a **sheet**, presented by
    /// `RootView` rather than by the screen itself.
    ///
    /// These four are the ones whose detail is a short read-only summary — a
    /// survey's questions, an experiment's variants — where a second column
    /// would be mostly empty and a push would promise a screen's worth of
    /// content that isn't there.
    ///
    /// The presentation is hoisted because a sheet **cannot** be driven from
    /// inside a secondary screen across the size-class boundary. See
    /// `RootView.presentedDetail` for the shared presentation rationale.
    var presentsDetailAsSheet: Bool {
        switch self {
        case .llm, .pipelines, .experiments, .surveys: true
        default: false
        }
    }

    /// Whether the screen brings a navigation container of its own.
    ///
    /// The seven list-and-detail screens are `NavigationSplitView`s, which *are* a
    /// navigation container: wrapping one in a `NavigationStack` puts a second,
    /// empty navigation bar above it on iPhone and breaks the two-column layout
    /// on iPad. Everything else is stack-less and gets its stack from whatever
    /// is showing it — a `Tab` in `RootView`, or the index behind "More".
    var ownsNavigationContainer: Bool {
        switch self {
        case .dashboards, .events, .sessions, .flags, .people, .errorTracking, .insights: true
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
    /// it is the fifth slot, and it is where every screen in `secondary` is
    /// reached — see the note on `case search` for why that is the array's name
    /// and not a number.
    static let alwaysVisible: [AppTab] = primary + [.search]

    /// Everything else, grouped.
    ///
    /// One array, two consumers: the iPad sidebar builds its `TabSection`s from
    /// it and the iPhone index builds its list from it. Written out twice these
    /// would drift the first time a screen was added to one and not the other,
    /// and the difference would only ever show up on one of the two devices.
    static let sections: [AppTabSection] = [
        // Insights leads Analyze rather than sitting beside the saved artefacts
        // in Workspace: a saved insight is a live analysis surface — it is
        // recomputed on open, scrubbed and exported — where a render or a
        // dashboard template is a file somebody kept. It sits first in the group
        // because it is the direct neighbour of the Dashboards tab above it, and
        // the two answer the same question at different granularities.
        AppTabSection(
            title: "Analyze",
            tabs: [.insights, .webAnalytics, .clickmap, .people, .groups, .sql]
        ),
        AppTabSection(
            title: "Monitor",
            // Ingestion sits beside Health rather than under Data: it answers
            // "is my instrumentation working", which is a monitoring question,
            // and Health's own `ingestion_warning` issue kind is the summary
            // this screen is the detail of.
            // Support sits beside Inbox rather than in Workspace with Max, and
            // the two placements are the same decision made twice. Monitor is
            // the "what needs my attention now" group — Errors is what the
            // machines noticed, Inbox is what the agents filed, Signals is what
            // the scouts found. A support ticket is the same question asked by a
            // *person*, with a deadline attached, and it is read in the same
            // posture: a triage pass, usually not at a desk.
            //
            // Max stays in Workspace, which is where things you read at leisure
            // live. Keeping the two `conversations`-prefixed products in
            // different sections is a bonus rather than the reason, but it is a
            // real one: the sidebar is where a reader would otherwise most
            // easily confuse them.
            // Summaries sits beside Errors rather than with Sessions: both
            // answer "what went wrong, and where", and `?outcome=failure` makes
            // this a triage queue in exactly the sense the rest of the group is.
            // Sessions stays a primary tab for browsing; this is for reading the
            // ones already known to have gone badly.
            tabs: [
                .errorTracking, .sessionSummaries, .llm, .tracing, .logs,
                .support, .inbox, .signals, .health, .ingestion,
            ]
        ),
        AppTabSection(
            title: "Data",
            tabs: [.warehouse, .pipelines, .automation, .actions, .annotations, .taxonomy]
        ),
        AppTabSection(title: "Experiment", tabs: [.experiments, .surveys, .earlyAccess]),
        // Renders sit with the other saved artefacts rather than with Sessions:
        // the screen is a library of files somebody kept, not a live analysis
        // surface, and this app can only read it.
        // Templates join them for the same reason: the screen is a library of
        // ready-made dashboards to read, not a live analysis surface, and this
        // app can only read it.
        AppTabSection(title: "Workspace", tabs: [.notebooks, .max, .renders, .templates]),
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
        case .insights: InsightsRoot()
        case .events: EventsRoot()
        case .sessions: SessionsRoot()
        case .flags: FlagsRoot()
        case .webAnalytics: WebAnalyticsRoot()
        case .clickmap: HeatmapsRoot()
        case .people: PeopleRoot()
        case .groups: GroupsRoot()
        case .sql: SQLConsoleRoot()
        case .errorTracking: ErrorTrackingRoot()
        case .sessionSummaries: SessionSummariesRoot()
        case .llm: LLMAnalyticsRoot()
        case .tracing: TracingRoot()
        case .logs: LogsRoot()
        case .support: SupportRoot()
        case .inbox: InboxRoot()
        case .signals: SignalsRoot()
        case .health: HealthRoot()
        case .ingestion: IngestionWarningsRoot()
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
        case .templates: DashboardTemplatesRoot()
        case .settings: SettingsRoot()
        case .search:
            // Reached through `RootView.searchTab`, which owns the stack this
            // screen's own rows push into. Nothing ever pushes `.search` itself,
            // so this case exists only to keep the switch honest.
            ProjectSearchView()
        }
    }
}

/// Where a secondary screen keeps the detail it currently has open.
///
/// A secondary screen is hosted **twice**. Above the size-class boundary it is
/// a `Tab` of its own, because `sidebarSections` is declared only there; below
/// it, that `Tab` does not exist and the screen is a destination pushed on the
/// search tab's stack. Crossing the boundary swaps hosts, so SwiftUI builds
/// `TabRootView` — and every `@State` in the screen underneath it — from
/// scratch.
///
/// Moving between size classes rebuilds the secondary host. Without shared
/// state, the open detail disappears in both directions while primary tabs,
/// which retain one host, keep their selection. That localises the fault to the
/// double-hosting boundary rather than to split-view navigation itself.
///
/// This object is owned by `RootView`, which straddles the boundary, so the two
/// hosts can hand the open detail to each other. `AnyHashable` because every
/// screen in `AppTab.secondary` has a detail type of its own and this file must
/// not know any of them.
///
/// **One box, two presenters.** Every secondary screen keeps its open detail
/// here; what differs is who turns that value back into a visible screen.
///
/// * A screen that *pushes* presents it itself, with
///   `navigationDestination(item:)` bound to this box. The destination lives in
///   whichever stack currently hosts the screen, and it is rebuilt from the
///   value on the far side of a resize. Tearing down the stack does **not** write
///   `nil` through the item binding, so the value survives the host swap.
/// * A screen that shows a **sheet** cannot present it itself. A sheet is a
///   presented view controller, its dismissal is a real event, and the resize
///   dismisses it — writing `nil` back through whatever drove it and destroying
///   the record meant to survive. Those four screens only *write* here;
///   `RootView` does the presenting, from above the boundary, where nothing
///   tears the presentation down.
///
/// `level` exists for the one screen that nests: Groups pushes a group type and
/// then a group inside it, and both have to come back.
@MainActor
@Observable
final class OpenDetails {
    private struct Slot: Hashable {
        let tab: AppTab
        let level: Int
    }

    private var byTab: [Slot: AnyHashable] = [:]

    subscript(tab: AppTab) -> AnyHashable? {
        get { byTab[Slot(tab: tab, level: 0)] }
        set { byTab[Slot(tab: tab, level: 0)] = newValue }
    }

    /// A deeper push on the same screen. Level 0 is the screen's own detail and
    /// is what the subscript above reaches.
    subscript(tab: AppTab, level level: Int) -> AnyHashable? {
        get { byTab[Slot(tab: tab, level: level)] }
        set { byTab[Slot(tab: tab, level: level)] = newValue }
    }
}

/// A sheet detail and the screen it belongs to.
///
/// `Identifiable` off the whole value rather than off the detail alone, so the
/// sheet is rebuilt when the screen changes even in the impossible case that two
/// screens' details compare equal.
struct PresentedDetail: Hashable, Identifiable {
    let tab: AppTab
    let detail: AnyHashable

    var id: Self { self }
}

/// The sheet a secondary screen has open, built from the tab that owns it.
///
/// One switch rather than a closure stored beside the value, for the reason
/// `TabRootView` is one switch: a stored `() -> AnyView` would make `OpenDetails`
/// hold view-building code for four screens, and the box has to stay a box — it
/// is shared with every screen that pushes, and with the split views that
/// adopted it first.
struct DetailSheetView: View {
    let presented: PresentedDetail

    @Environment(AppModel.self) private var model

    var body: some View {
        switch presented.tab {
        case .surveys:
            if let survey = presented.detail as? Survey {
                SurveyDetailSheet(
                    survey: survey,
                    webURL: model.webURL(path: "surveys/\(survey.id)")
                )
            }
        case .experiments:
            if let experiment = presented.detail as? Experiment {
                ExperimentDetailSheet(
                    experiment: experiment,
                    webURL: model.webURL(path: "experiments/\(experiment.id)")
                )
            }
        case .llm:
            if let trace = presented.detail as? LLMTrace {
                LLMTraceDetailSheet(
                    trace: trace,
                    webURL: model.webURL(path: "llm-analytics/traces/\(trace.id)")
                )
            }
        case .pipelines:
            if let function = presented.detail as? HogFunction {
                PipelineDetailSheet(
                    function: function,
                    webURL: model.webURL(path: pipelineWebPath(for: function))
                )
            }
        default:
            // Unreachable: `presentedDetail` only builds a `PresentedDetail` for
            // a tab whose `presentsDetailAsSheet` is true. Drawing nothing beats
            // a `fatalError` for a case a future tab could add by omission.
            EmptyView()
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
    /// Held here rather than in the screens themselves: this view is the only
    /// thing in the tree that survives a size-class change intact.
    @State private var openDetails = OpenDetails()
    /// The optimistic state behind the survey and experiment writes, owned here
    /// for two reasons that are the same reason `openDetails` is.
    ///
    /// The detail *sheets* for both are presented from this view — see
    /// `presentedDetail` — while the lists that opened them live in a secondary
    /// screen hosted twice across the size-class boundary. A controller declared
    /// as `@State` in either place would be a different object from the other's,
    /// so a survey stopped in the sheet would leave the row behind it reading
    /// "Running", and a rotation would discard whichever copy the resize rebuilt.
    /// One object above both, injected into both, is the only arrangement where
    /// the list and the sheet cannot disagree.
    @State private var surveyLifecycle = SurveyLifecycleController()
    @State private var experimentLifecycle = ExperimentLifecycleController()
    @State private var hasAppliedDebugTab = false
    /// Set only when a link could not do what it said. Success is silent; see
    /// `LinkNotice`.
    @State private var linkNotice: LinkNotice?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

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
                .environment(openDetails)
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
                // Attached **here**, to the one view in the tree that a resize
                // never rebuilds, rather than inside the four screens that own
                // these details. See `presentedDetail`.
                //
                // The lifecycle controllers are injected before `.sheet` because
                // a presented view inherits the environment at the modifier site.
                // Attaching the sheet outside those injections would leave its
                // content without the required lifecycle controllers.
                .sheet(item: presentedDetail) { DetailSheetView(presented: $0) }
                .onAppear {
                    restorePushedTab()
                    // Cold launch: a quick action or a URL that started the app
                    // arrived before this body existed, so it is waiting rather
                    // than lost.
                    routePendingLinks()
                    #if DEBUG
                    // Last, not first. Both mailboxes above can navigate, and
                    // they are drained from storage shared with the widgets and
                    // the intent extension — so a target left over from an
                    // earlier run used to arrive *after* `GETHOG_TAB` had been
                    // honoured and quietly overrule it. An explicitly requested
                    // launch destination is the most specific instruction the
                    // process has; it now wins.
                    //
                    // Applied once: `@SceneStorage` would otherwise fight a user who
                    // switched tabs after launch.
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
                // Attached beside the link notice for the same reason it is: a
                // failed organization switch has no screen of its own to report
                // on, and the switcher that started it is a menu that has already
                // dismissed itself by the time the request comes back. Nothing
                // moved when this fires — the projects, the project and the
                // subtitle are all still the organization the user was in — so
                // the alert is the whole of the feedback and has to carry the
                // reason.
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
                // **Outermost, and that is load-bearing.** Both the tab tree and
                // the `.sheet` above have to see these, and only a modifier that
                // encloses the sheet supplies it — see the note on `.sheet`, which
                // records the crash that established this. Placing them here means
                // the survey list and the survey sheet read one object, so a
                // survey stopped in the sheet cannot leave the row behind it
                // reading "Running".
                .environment(surveyLifecycle)
                .environment(experimentLifecycle)
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

    /// The index tab uses an ordinary `Tab` at both widths.
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
    /// its own stack would draw a redundant navigation bar when content pushed.
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

    // MARK: - Sheet details

    /// The sheet the showing screen has open, if that screen shows sheets.
    ///
    /// **Why this is here and not in the four screens.** Everything else a
    /// secondary screen opens is a *push*, and a push can be driven from inside
    /// the screen: `navigationDestination(item:)` reads `OpenDetails`, and when
    /// the size class swaps hosts the destination is simply rebuilt from the
    /// value on the other side. A sheet cannot be driven that way, and two
    /// nested presentation would clear its state when the host sheet is
    /// dismissed during a size-class transition.
    ///
    /// Both failures are the same fact — a sheet's teardown is indistinguishable
    /// from a user dismissing it, and the teardown happens on a beat the screen
    /// does not control. So the presentation moves to the one place a resize
    /// never tears down. `RootView` straddles the boundary; only the *content*
    /// of its `TabView` changes shape when the size class does. Nothing dismisses
    /// this sheet but a user, and a user's dismissal is the only `nil` it writes.
    ///
    /// Keyed on `selectedTab` because that is what names the showing screen at
    /// both widths — the sidebar selects it in regular width and the search
    /// stack's destination sets it in compact. Navigating away therefore closes
    /// the sheet without clearing it, and coming back re-presents it. That is
    /// the same promise every pushing screen makes — `OpenDetails` is what
    /// a screen *has open*, and a screen you return to is where you left it —
    /// and it is reachable only by a link arriving from outside, since a sheet
    /// covers the app and there is nothing else to tap while one is up.
    ///
    /// A read, and only a read: no `onChange` clears this. Every clearing path
    /// that ran off something other than the user's own dismissal is what broke
    /// the two attempts above.
    private var presentedDetail: Binding<PresentedDetail?> {
        Binding(
            get: {
                guard selectedTab.presentsDetailAsSheet,
                      let detail = openDetails[selectedTab]
                else { return nil }
                return PresentedDetail(tab: selectedTab, detail: detail)
            },
            set: { newValue in
                // `.sheet(item:)` only ever writes `nil` here, and it means the
                // user dismissed it. Cleared across all four rather than for
                // `selectedTab` alone: the write can land after the selection
                // has already moved on, and clearing the tab that happens to be
                // showing *then* would leave the dismissed screen's detail set
                // and reopen its sheet the moment it came back.
                guard newValue == nil else { return }
                for tab in AppTab.allCases where tab.presentsDetailAsSheet {
                    openDetails[tab] = nil
                }
            }
        )
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

        // Asking for search means the field, at *both* widths. The reset used to
        // sit behind the compact guard below, so in regular width selecting
        // search showed whatever had last been pushed onto this stack — a link's
        // destination, or a screen restored from a rotation — instead of the
        // search root. The stack is shared with links precisely so a back button
        // behaves once; that sharing is what makes clearing it necessary here.
        if tab == .search { searchPath = NavigationPath() }

        // Everything past this point is compact-only: in regular width every
        // destination has a sidebar row of its own, so selecting it is the whole
        // job and nothing needs pushing.
        guard sizeClass == .compact else { return }
        if AppTab.secondary.contains(tab) {
            var path = NavigationPath()
            path.append(tab)
            searchPath = path
        }
    }

    // MARK: - Links

    /// Drains everything waiting to be navigated to.
    ///
    /// Both mailboxes, because an intent that opens the app and a tapped link
    /// are the same request as far as this view is concerned: go somewhere.
    private func routePendingLinks() {
        // The Control Center dashboard button writes this and, until now,
        // nothing read it. Its intent sets `openAppWhenRun`, so the app came to
        // the front and stopped — on whatever screen you happened to leave it.
        // Pressing a control labelled with a *metric* and landing on Settings is
        // the control silently failing at the only job it has.
        //
        // The landing is the dashboard the metric was read from, and it stays
        // that way now that `.insight` opens in the app.
        //
        // The old reasoning here was that this app had no screen for a lone
        // insight, so a dashboard was the deepest it could go. That reason is
        // gone — `InsightsRoot` and `SavedInsightDetailView` exist and
        // `PostHogLink.insight.opensInApp` is now true — but the destination is
        // unchanged, for a reason that was always the better one and was
        // previously hidden behind the limitation:
        //
        // `SharedSnapshot.Metric` records the *dashboard* id at write time
        // because that is what the widget's writer had in hand; it has never
        // carried an insight id, and it still doesn't. Routing to an insight
        // would mean inventing one from the metric's title, which is a guess.
        // A control labelled with a metric landing on the dashboard that
        // contains it is honest; landing on some other project object that
        // happens to share a name is not.
        //
        // Falls back to the dashboards home whenever the id is unknown — a
        // snapshot written by an older build, or a metric that has since left
        // the dashboard. Landing one level up is the correct degradation; a
        // guess would not be.
        //
        // Consumed either way, so a stale request cannot redirect a later launch
        // the user began somewhere else.
        if let pending = SharedSnapshotStore.shared.pendingOpen() {
            SharedSnapshotStore.shared.clearPendingOpen()
            let snapshot = SharedSnapshotStore.shared.loadOrNil()
            if let metricID = pending.metricID,
               let dashboardID = snapshot?.metric(id: metricID)?.dashboardID,
               let projectID = snapshot?.projectID {
                // Carried with its project: the snapshot names the project the
                // dashboard id was read in, and `open(_:)` refuses rather than
                // showing another project's dashboard under the same number.
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

    /// Goes where a link points, or explains why it can't.
    ///
    /// The project is settled before the object, and a project this key cannot
    /// see stops the whole thing. Resolving an object ID against a different
    /// project would draw unrelated data, so the project switcher is available
    /// on every screen.
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
                projectList
            } label: {
                // A glyph, not the project name. The name is permanently
                // visible as the navigation subtitle, and repeating it here
                // made the item wide enough that it could not share the bar
                // with a back button — costing a whole row of chrome on every
                // pushed screen.
                Image(systemName: "building.2")
            }
            // The label names the thing; the hint says what happens to it.
            //
            // It used to end "Double tap to switch." — which VoiceOver already
            // appends itself, so the instruction was spoken twice on every
            // screen in the app, and it named a gesture that Switch Control,
            // Voice Control and a keyboard do not have.
            //
            // The organization is spoken only when there is more than one. For
            // the single-organization user it is a constant, and a constant read
            // aloud on every screen is noise; for everyone else it is the half of
            // the answer that decides whose numbers these are.
            .accessibilityLabel(spokenLabel)
            .accessibilityHint(
                model.isMultiOrganization
                    ? "Switches to a different project or organization"
                    : "Switches to a different project"
            )
        }
    }

    private var spokenLabel: String {
        let project = model.selectedProject?.name ?? "none"
        guard model.isMultiOrganization, let organization = model.selectedOrganization else {
            return "Current project: \(project)"
        }
        return "Current project: \(project), in organization \(organization.name)"
    }

    /// Every project the key can reach, under the organisation that owns them.
    ///
    /// The organisation is the *heading over* the projects, not an entry beneath
    /// them.
    ///
    /// It used to be a plain `Text` after a `Divider`, which is the shape a menu
    /// uses for a second group of *commands* — same size, same weight, same
    /// leading inset as the project row above it, with only a missing checkmark
    /// to say it was not selectable. A heading styled like an entry can appear
    /// to be another selectable project, which risks showing the wrong data.
    ///
    /// A titled `Section` is the system's own vocabulary for "these items belong
    /// to this": drawn smaller and grey, above the selectable run rather than
    /// inside it, with no divider implying a second group of choices.
    ///
    /// Buttons rather than the `Picker` this used to be, and that is not a
    /// preference — it is what makes the heading appear at all. Both arrangements
    /// were built and photographed: with a `Picker` inside it, the section's title
    /// is dropped and the organisation vanishes from the menu entirely, and
    /// `.pickerStyle(.inline)` with the organisation as the picker's own label
    /// does the same. Either would have traded a misreading for a blank. A menu
    /// of buttons with a checkmark on the current one is what a `Picker` compiles
    /// to anyway; writing it out is what keeps the title.
    @ViewBuilder
    private var projectList: some View {
        // The heading is the *selected* organization, not `me.organization`.
        // Those are the same thing until somebody switches, and after that
        // `me.organization` is the organization the identity request happened to
        // be centred on — which would leave the menu heading one organization's
        // name over another organization's projects. Precisely the misreading
        // the heading was introduced to prevent.
        Section(model.selectedOrganization?.name ?? model.me?.organization?.name ?? "") {
            ForEach(model.projects) { project in
                let isCurrent = project.id == model.selectedProject?.id
                Button {
                    model.selectedProject = project
                } label: {
                    if isCurrent {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
                // The checkmark is the only thing distinguishing the current
                // project, and a glyph inside a menu item is not announced — so
                // written out, the way `Picker` announced "selected" before.
                .accessibilityLabel(isCurrent ? "\(project.name), current project" : project.name)
            }
        }

        // Absent entirely for the single-organization user, which is most of
        // them: a second section headed "Organization" listing exactly the
        // organization already named above it says nothing and invites the
        // reading that there is somewhere else to go.
        if model.isMultiOrganization {
            organizationList
        }
    }

    /// The other organizations this credential can see.
    ///
    /// Buttons in a titled `Section`, for the same reason the projects above are:
    /// a `Picker` inside a `Section` drops the title, and an untitled run of
    /// organization names directly under a run of project names is two lists that
    /// look like one. Both arrangements were built and photographed when the
    /// project half of this menu was written.
    ///
    /// Switching costs a request the first time, so each button is disabled while
    /// one is in flight — a menu is dismissed on tap and gives the second tap
    /// nowhere to report to, so two switches racing would be resolved by whichever
    /// response arrived last rather than by whichever the user meant.
    private var organizationList: some View {
        Section("Organization") {
            ForEach(model.organizations) { organization in
                let isCurrent = organization.id == model.selectedOrganizationID
                Button {
                    Task { await model.selectOrganization(id: organization.id) }
                } label: {
                    if isCurrent {
                        Label(organization.name, systemImage: "checkmark")
                    } else {
                        Label(organization.name, systemImage: "building.2")
                    }
                }
                .disabled(model.isSwitchingOrganization)
                .accessibilityLabel(
                    isCurrent
                        ? "\(organization.name), current organization"
                        : "\(organization.name), organization"
                )
            }
        }
    }
}
