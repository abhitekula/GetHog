import SwiftUI

enum ScreenNavigationPlacement: Sendable {
    case standalone
    case visionSectionDetail
}

private struct ScreenNavigationPlacementKey: EnvironmentKey {
    static let defaultValue = ScreenNavigationPlacement.standalone
}

extension EnvironmentValues {
    var screenNavigationPlacement: ScreenNavigationPlacement {
        get { self[ScreenNavigationPlacementKey.self] }
        set { self[ScreenNavigationPlacementKey.self] = newValue }
    }
}

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
        // not "Charts": a saved insight is a saved *question*, and it may be a
        // HogQL result table, a headline value, or another non-chart display.
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
        // `cursorarrow.rays` resolves, but repeatedly drove the iPad tab item's
        // image host into an unbounded relayout loop. The click variant says
        // what an action matches and remained stable across repeated launches.
        case .actions: "cursorarrow.click"
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
    /// **All seven build a plain list in compact width**, so asking about the
    /// width is required rather than incidental. Events and Flags also choose
    /// that full-width list at accessibility sizes: their split sidebars leave
    /// too little measure for the row and its state. Each renders
    /// `list.navigationDestination(item:)` below that topology boundary and
    /// keeps the split view otherwise — in list topology they own nothing and
    /// need a stack from whatever hosts them.
    ///
    /// Measured both ways on iPhone, and both failures are silent-looking:
    /// with this returning `true` unconditionally, a screen *promoted* into the
    /// bar got no stack from `container(for:)` and tapping a row left
    /// `navigationBars` empty; and a screen converted to the compact shape while
    /// this still claimed a container drew no navigation bar at all.
    func ownsNavigationContainer(compact: Bool, accessibilitySize: Bool = false) -> Bool {
        switch self {
        case .events, .flags:
            !compact && !accessibilitySize
        case .dashboards, .sessions, .people, .errorTracking, .insights:
            !compact
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
            // Dashboards, Events and Sessions lead this group, and their being
            // here at all is what the tab bar becoming a preference required: a
            // screen the user demotes out of the bar has to have somewhere to be
            // listed, and before this these three — and Flags below — were in no
            // section at all. They lead rather than sitting among the rest
            // because they are the defaults, and a reader who has customised
            // nothing should find them where the bar left them.
            tabs: [
                .dashboards, .events, .sessions,
                .insights, .webAnalytics, .clickmap, .people, .groups, .sql,
            ]
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
        // Flags leads Experiment rather than joining Analyze, which is where
        // PostHog's own console files feature flags: a flag is the mechanism an
        // experiment is run with, and the two screens link to each other.
        AppTabSection(title: "Experiment", tabs: [.flags, .experiments, .surveys, .earlyAccess]),
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

    /// Every screen that can occupy a tab-bar slot.
    ///
    /// Defined as the sections' contents, which is what excludes `.search` and
    /// `.settings` by construction rather than by a list that would need
    /// maintaining: neither sits in a section, and neither should be choosable
    /// into the four.
    static let productScreens: [AppTab] = sections.flatMap(\.tabs)

    /// The sections with `loose` removed — the one rule that decides where a
    /// screen is listed, so it is listed exactly once.
    ///
    /// One helper for two consumers: the compact index and the iPad sidebar.
    /// Written twice they would drift the first time a screen moved, and the
    /// difference would only ever show up on one of the two devices.
    ///
    /// This became necessary the moment the four defaults moved into sections
    /// above. Before that they were in no group, so a sidebar could declare them
    /// loose and render every section without listing anything twice; now it
    /// would list each of them twice, and the compact index would offer a screen
    /// that is already a tab.
    static func groupedScreens(excluding loose: [AppTab]) -> [AppTabSection] {
        sections.compactMap { section in
            let tabs = section.tabs.filter { !loose.contains($0) }
            return tabs.isEmpty ? nil : AppTabSection(title: section.title, tabs: tabs)
        }
    }

    /// Everything the phone reaches through the index rather than the tab bar,
    /// **for the default bar only**.
    ///
    /// It used to be a fact about the app; it is now a fact about one
    /// arrangement of it, because which screens the index holds depends on which
    /// four the user put in the bar. Kept for the call sites that genuinely mean
    /// "the default arrangement" — the demo-index ambiguity measurement in
    /// `SearchSuggestionTests` is one — and *not* for anything that draws the
    /// index. Those read `NavPreferences.indexedScreens`.
    ///
    /// Computed rather than stored, and that is load-bearing: as a `static let`
    /// it would now hold the four as well, since they are in sections.
    static var secondary: [AppTab] {
        groupedScreens(excluding: primary).flatMap(\.tabs) + utility
    }
}
