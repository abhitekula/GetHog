import XCTest

/// The screens that only exist after somebody touches something.
///
/// This is the half of the app `ImageRenderer` provably cannot reach, and
/// therefore the half that shipped least observed. A renderer can draw a `View`;
/// it cannot present a sheet with detents, open a `Menu`, raise a confirmation
/// dialog, clip content inside a `ScrollView`, or run a `WKWebView` — and every
/// state in this file is one of those.
///
/// **What is not here, and why.** Seven detail screens cannot be opened in demo
/// mode at all, because their root has no rows to tap: tracing (and the call tree
/// and span detail below it), logs, warehouse, actions, notebooks, Max, and the
/// pipelines sheet. `DemoTransport` documents that two of those query kinds are
/// refused outright for a project-scoped key, and a fixture invented to fill the
/// gap would be a picture of something that does not exist. The roots themselves
/// are captured by `RootScreenshotTests`; the details are listed as uncaptured
/// rather than faked.
///
/// **The experiments sheet used to be on that list and no longer belongs there.**
/// The claim was true when this file was written and became false when
/// `experiments.json`, `experiment_detail_*.json`, `experiment_exposures_*.json`
/// and the three `experiment_result_*.json` fixtures landed:
/// `AccessibilityAuditTests.testExperimentResults` has been opening that sheet by
/// tapping a row ever since. It is captured below. Re-checked while correcting
/// this: `DemoTransport` still has no `/pipeline` route and
/// `GetHog/Resources/DemoData/` still holds no pipelines fixture, so the
/// pipelines half of the old sentence stands.
@MainActor
final class StateScreenshotTests: ScreenshotCase {

    /// The deterministic dashboard-detail fixture.
    private static let dashboard = "gethog://dashboard/\(DemoLaunch.dashboardID)"
    /// Tile 5 by `order` is "Pageview funnel, by browser", the only `FunnelsQuery`
    /// in the fixture and therefore the only tile with a drillable axis that
    /// needs no chart scrubbing to reach.
    private static let funnelTileIndex = "5"
    /// `error_tracking.json`, first synthetic row: `HarborRenderFault`, status active — so
    /// the triage buttons drawn are "Resolve" and "Suppress".
    private static let errorIssue = "018f3300-0000-7000-8000-000000000901"

    // MARK: - Brand states

    func testBrandedEmptyDashboards() {
        captureBrandState(
            tab: "dashboards",
            title: "No dashboards",
            name: "brand-empty-dashboards",
            emptyCollection: "dashboards"
        )
    }

    func testBrandedEmptyInsights() {
        captureBrandState(
            tab: "insights",
            title: "No saved insights",
            name: "brand-empty-insights",
            emptyCollection: "insights"
        )
    }

    func testBrandedEmptySessions() {
        captureBrandState(
            tab: "sessions",
            title: "No sessions",
            name: "brand-empty-sessions",
            emptyCollection: "sessions"
        )
    }

    func testBrandedEmptyExperiments() {
        captureBrandState(
            tab: "experiments",
            title: "No experiments",
            name: "brand-empty-experiments",
            emptyCollection: "experiments"
        )
    }

    func testBrandedAllClearErrors() {
        captureBrandState(
            tab: "errorTracking",
            title: "No errors in this period",
            name: "brand-all-clear-errors",
            emptyCollection: "errorTracking"
        )
    }

    func testBrandedWorkspace() {
        captureBrandState(
            tab: "annotations",
            title: "No annotations",
            name: "brand-empty-workspace"
        )
    }

    func testBrandFamilyEmblems() {
        captureBrandState(
            tab: "search",
            title: "Search",
            name: "brand-family-emblems"
        )
    }

    func testBrandFamilyEmblemData() {
        captureBrandEmblem(
            query: "Actions",
            result: "Actions",
            name: "brand-family-emblem-data"
        )
    }

    func testBrandFamilyEmblemExperiment() {
        captureBrandEmblem(
            query: "Experiments",
            result: "Experiments",
            name: "brand-family-emblem-experiment"
        )
    }

    func testBrandFamilyEmblemWorkspace() {
        captureBrandEmblem(
            query: "Notebooks",
            result: "Notebooks",
            name: "brand-family-emblem-workspace"
        )
    }

    func testBrandedEmptyDashboardReduceMotion() {
        captureBrandState(
            tab: "dashboards",
            title: "No dashboards",
            name: "brand-empty-dashboards-reduce-motion",
            emptyCollection: "dashboards",
            extraArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"]
        )
    }

    private func captureBrandState(
        tab: String,
        title: String,
        name: String,
        emptyCollection: String? = nil,
        extraArguments: [String] = []
    ) {
        var environment: [String: String] = [:]
        if let emptyCollection {
            environment["GETHOG_DEMO_EMPTY_COLLECTION"] = emptyCollection
        }

        capture(
            launching: {
                Screenshot.launch(
                    $0,
                    tab: tab,
                    environment: environment,
                    extraArguments: extraArguments
                )
            },
            steps: [
                ScreenshotStep(name) { app in
                    self.waitUntil {
                        app.staticTexts[title].exists || app.navigationBars[title].exists
                    }
                }
            ]
        )
    }

    private func captureBrandEmblem(query: String, result: String, name: String) {
        capture(
            launching: { Screenshot.launch($0, tab: "search") },
            steps: [
                ScreenshotStep(name) { app in
                    guard self.waitUntil({ app.navigationBars["Search"].exists }) else {
                        return false
                    }
                    let field = app.searchFields.firstMatch
                    guard DemoLaunch.wait(for: field) else { return false }
                    field.tap()
                    field.typeText(query)
                    return self.waitUntil {
                        app.buttons.matching(
                            NSPredicate(format: "label BEGINSWITH %@", result)
                        ).firstMatch.exists
                    }
                }
            ]
        )
    }

    // MARK: - Dashboards

    /// The dashboard grid itself, which is a screen no tab names.
    func testDashboardDetail() {
        capture(
            launching: { Screenshot.launch($0, openURL: Self.dashboard) },
            steps: [
                ScreenshotStep("dashboard-detail") { app in
                    // The tile, not just the bar. A dashboard draws its title
                    // before it has anything under it, and a photograph of the
                    // empty grid would be filed as the screen.
                    DemoLaunch.wait(
                        for: self.elements(startingWith: DemoLaunch.firstTileTitle, in: app)
                            .firstMatch
                    )
                }
            ]
        )
    }

    /// A tile opened into its full insight.
    ///
    /// **Opened by `GETHOG_OPEN_TILE` rather than by tapping, which keeps this
    /// capture about the detail's *appearance* and nothing else.** It used to say
    /// the tap route was unreachable — four attempts, 142 seconds, no "Done" and
    /// no "Close insight" — and that whether the chart's scrub recogniser was
    /// eating the tap "is not something a screenshot can answer". Both halves are
    /// now out of date: it was `chartXSelection`, it did far more than eat one
    /// tap, and `testDashboardTileTap` below answers it by tapping. The launch
    /// variable stays here because a photograph of a settled screen should not
    /// also be the regression test for a gesture.
    ///
    /// The state is not the same shape on both devices, which is why the wait is
    /// a disjunction: on iPhone it is a sheet inside a `NavigationStack` with a
    /// "Done" button, and on iPad it is a second column in an `HStack` with no
    /// navigation bar at all and a "Close insight" button.
    func testDashboardTileInsight() {
        capture(
            launching: {
                Screenshot.launch(
                    $0,
                    openURL: Self.dashboard,
                    environment: ["GETHOG_OPEN_TILE": "0"]
                )
            },
            steps: [
                ScreenshotStep("dashboard-tile-insight") { app in
                    self.waitUntil {
                        app.buttons["Done"].exists || app.buttons["Close insight"].exists
                    }
                }
            ]
        )
    }

    /// The chart drill-down: who is behind one funnel step.
    ///
    /// Two presentations deep on iPhone — a sheet over a sheet — which is
    /// exactly what no renderer can produce. `GETHOG_OPEN_TILE` opens the
    /// funnel tile directly, because the tap route is already covered above and
    /// the funnel is the sixth tile in a grid that has to be scrolled.
    ///
    /// The sibling `Menu` in the drill sheet's toolbar is captured in the second
    /// step: a `Menu`'s popover is presented in a window of its own, which is
    /// both why `XCUIScreen.main.screenshot()` is used throughout and why this is
    /// worth a frame — a `Menu` label taking the accent colour and turning every
    /// funnel step teal is a defect this project has already shipped once.
    func testInsightDrillDown() {
        capture(
            launching: {
                Screenshot.launch(
                    $0,
                    openURL: Self.dashboard,
                    environment: ["GETHOG_OPEN_TILE": Self.funnelTileIndex]
                )
            },
            steps: [
                ScreenshotStep("insight-funnel-detail") { app in
                    self.waitUntil {
                        self.elements(startingWith: "Step 1,", in: app).firstMatch.exists
                    }
                },
                ScreenshotStep("insight-drilldown") { app in
                    guard self.tapFirst(startingWith: "Step 2,", in: app) else { return false }
                    return self.waitUntil {
                        app.staticTexts.containing(
                            NSPredicate(format: "label CONTAINS %@", "people on this chart")
                        ).firstMatch.exists
                    }
                },
                ScreenshotStep("insight-drilldown-menu") { app in
                    self.tapFirst(startingWith: "Change outcome", in: app)
                },
            ]
        )
    }

    /// The saved-insight library's detail screen, which shipped never having been
    /// seen running.
    func testSavedInsightDetail() {
        capture(
            launching: { Screenshot.launch($0, tab: "insights") },
            steps: [
                ScreenshotStep("saved-insight-detail") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Insights"]) else { return false }
                    guard self.tapFirst(
                        startingWith: "Example meteor report", in: app
                    ) else { return false }
                    return self.waitUntil {
                        app.navigationBars["Example meteor report"].exists
                    }
                }
            ]
        )
    }

    /// PostHog's own alerts on one insight, and the snooze menu over them.
    ///
    /// A `Menu` item opening a `.sheet` containing a `List` — three of the things
    /// `ImageRenderer` provably cannot draw — so this harness is the only way
    /// either of the two new workflows is ever looked at.
    ///
    /// The alert row comes from `alerts.json`, an authored schema-shaped fixture.
    /// These frames show the contract populated with the demo's fictional
    /// insights.
    ///
    /// The narrowing sheet is a **separate method** rather than a fourth step
    /// here, and that is measured rather than tidiness: as a fourth step it had to
    /// dismiss two presentations and re-open the toolbar menu, and the run took
    /// the runner down at that point with "Restarting after unexpected exit"
    /// — twice. Two methods spend one extra launch and neither has to unwind
    /// anything.
    func testInsightAlerts() {
        capture(
            launching: { Screenshot.launch($0, tab: "insights") },
            steps: [
                ScreenshotStep("insight-actions-menu") { app in
                    guard self.openDemoInsight(app) else { return false }
                    // The menu itself is worth a frame: it is where both features
                    // are reached from, and a `Menu`'s popover is presented in a
                    // window of its own — which is why this harness photographs
                    // the whole screen rather than the app.
                    return self.tapFirst(startingWith: "Insight actions", in: app)
                },
                ScreenshotStep("insight-alerts") { app in
                    guard self.tapFirst(startingWith: "Alerts", in: app) else { return false }
                    return self.waitUntil { app.navigationBars["Alerts"].exists }
                },
                ScreenshotStep("insight-alert-snooze-menu") { app in
                    // The snooze durations, which are the one place this app
                    // states what PostHog's `always_truncate` really does to a
                    // "1d" snooze. A label reading "24 hours" here would be wrong
                    // and would look right.
                    self.tapFirst(startingWith: "Snooze ", in: app)
                },
            ]
        )
    }

    /// The alert composer — the sheet that writes one.
    ///
    /// Its own method rather than a fourth step on `testInsightAlerts`, for the
    /// reason recorded there: unwinding two presentations to reach a third state
    /// took the runner down twice.
    func testInsightAlertComposer() {
        capture(
            launching: { Screenshot.launch($0, tab: "insights") },
            steps: [
                ScreenshotStep("insight-alert-composer") { app in
                    guard self.openDemoInsight(app) else { return false }
                    guard self.tapFirst(startingWith: "Insight actions", in: app) else { return false }
                    guard self.tapFirst(startingWith: "Alerts", in: app) else { return false }
                    guard self.waitUntil({ app.navigationBars["Alerts"].exists }) else { return false }
                    guard self.tapFirst(startingWith: "New alert", in: app) else { return false }
                    return self.waitUntil { app.navigationBars["New alert"].exists }
                }
            ]
        )
    }

    /// Narrowing the same insight by a property filter or a breakdown.
    func testInsightNarrowSheet() {
        capture(
            launching: { Screenshot.launch($0, tab: "insights") },
            steps: [
                ScreenshotStep("insight-narrow-sheet") { app in
                    guard self.openDemoInsight(app) else { return false }
                    guard self.tapFirst(startingWith: "Insight actions", in: app) else { return false }
                    guard self.tapFirst(startingWith: "Filter or split", in: app) else { return false }
                    return self.waitUntil { app.navigationBars["Narrow"].exists }
                },
                ScreenshotStep("insight-narrow-filter-picker") { app in
                    guard self.tapFirst(startingWith: "Add a filter", in: app) else { return false }
                    return self.waitUntil { app.navigationBars["Add a filter"].exists }
                },
            ]
        )
    }

    /// Opens the library's first insight, which both methods above start from.
    private func openDemoInsight(_ app: XCUIApplication) -> Bool {
        guard DemoLaunch.wait(for: app.navigationBars["Insights"]) else { return false }
        guard tapFirst(startingWith: "Example meteor report", in: app)
        else { return false }
        return waitUntil { app.navigationBars["Example meteor report"].exists }
    }

    // MARK: - Sessions

    /// The filter sheet, with its `[.medium, .large]` detents — a presentation no
    /// renderer produces and therefore a layout nothing has checked.
    func testSessionFilterSheet() {
        capture(
            launching: { Screenshot.launch($0, tab: "sessions") },
            steps: [
                ScreenshotStep("session-filter-sheet") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Sessions"]) else { return false }
                    // Prefix, because the label gains ", N active" once the list
                    // has been narrowed.
                    guard self.tapFirst(startingWith: "Filter sessions", in: app)
                    else { return false }
                    guard self.waitUntil({ app.navigationBars["Filter sessions"].exists })
                    else { return false }
                    return self.waitUntil {
                        app.switches["Filter out internal and test users"].exists
                    }
                }
            ]
        )
    }

    /// Playlists and a collection detail, followed only in the forward direction.
    ///
    /// A collection is a hand-pinned list that `/recordings/` returns rows for.
    /// The saved-filter kind is captured from its own fresh launch below: moving
    /// back from this detail did not reliably republish the playlist list's
    /// accessibility hierarchy, so a capture that then selected another row was
    /// testing navigation restoration rather than either detail screen.
    func testPlaylists() {
        capture(
            launching: { Screenshot.launch($0, tab: "sessions") },
            steps: [
                ScreenshotStep("session-playlists") { app in
                    self.openPlaylists(app)
                },
                ScreenshotStep("session-playlist-collection") { app in
                    guard self.tapFirst(startingWith: "Onboarding drop-offs", in: app)
                    else { return false }
                    return self.waitUntil { app.navigationBars["Onboarding drop-offs"].exists }
                },
            ]
        )
    }

    /// A saved filter re-runs its stored query rather than reading the collection
    /// sub-resource. Starting from a fresh playlist list keeps this proof about
    /// that distinction and independent of the collection detail's back stack.
    func testPlaylistSavedFilter() {
        capture(
            launching: { Screenshot.launch($0, tab: "sessions") },
            steps: [
                ScreenshotStep("session-playlist-saved-filter") { app in
                    guard self.openPlaylists(app) else { return false }
                    guard self.tapFirst(startingWith: "Sessions with exceptions", in: app)
                    else { return false }
                    return self.waitUntil {
                        app.navigationBars["Sessions with exceptions"].exists
                    }
                },
            ]
        )
    }

    private func openPlaylists(_ app: XCUIApplication) -> Bool {
        guard DemoLaunch.wait(for: app.navigationBars["Sessions"]) else { return false }
        guard tap(app.buttons["Playlists"]) else { return false }
        return waitUntil { app.navigationBars["Playlists"].exists }
    }

    /// A session, its replay, and the two diagnostic panes below it.
    ///
    /// One launch for three images, because the expensive part is shared: the
    /// player boots rrweb in a `WKWebView` and has to be fed snapshots before
    /// anything is on screen, which `ReplayStageAccessibilityTests` waits up to
    /// two minutes for. The console and network panes are then further down the
    /// same scroll view — they are drawn unconditionally as sibling cards, not
    /// behind a segmented control — so reaching them is a swipe.
    func testSessionReplayAndDiagnostics() {
        capture(
            launching: {
                Screenshot.launch($0, openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")
            },
            steps: [
                ScreenshotStep("session-detail") { app in
                    DemoLaunch.wait(
                        for: DemoLaunch.elements(labelled: "Session replay", in: app).firstMatch,
                        timeout: 150
                    )
                },
                ScreenshotStep("replay-console") { app in
                    self.scrollToHeadOfPage(app.staticTexts["Console"])
                },
                ScreenshotStep("replay-network") { app in
                    self.scrollToHeadOfPage(app.staticTexts["Network"])
                },
            ]
        )
    }

    // MARK: - Errors

    /// An issue, its stack trace, and the dialog that guards a status change.
    ///
    /// The trace is inline rather than behind a tap — it is the last block of the
    /// screen's scroll view and arrives on its own second request — so it is
    /// reached by scrolling. The confirmation dialog is the third step because it
    /// is a separate presented window, and a dialog whose destructive framing is
    /// wrong is invisible to every other kind of test here.
    func testErrorIssueTriage() {
        capture(
            launching: {
                Screenshot.launch($0, openURL: "gethog://error_tracking/\(Self.errorIssue)")
            },
            steps: [
                ScreenshotStep("error-issue-detail") { app in
                    DemoLaunch.wait(for: app.navigationBars["HarborRenderFault"])
                },
                ScreenshotStep("error-stack-trace") { app in
                    self.scrollIntoView(app.staticTexts["Stack trace"], maximumSwipes: 14)
                },
                ScreenshotStep("error-resolve-dialog") { app in
                    // Back up first: the triage buttons sit *above* the stack
                    // trace, and `scrollIntoView` only swipes one way. At an
                    // accessibility type size the distance between the two is
                    // several screens, which is how this step was measured
                    // failing at ax5 while passing at every other size.
                    self.scrollToTop()
                    guard self.tapFirst(startingWith: "Resolve", in: app) else { return false }
                    return self.waitUntil {
                        app.staticTexts["Mark this issue resolved?"].exists
                    }
                },
            ]
        )
    }

    // MARK: - Sheets `RootView` presents

    /// A survey's questions. One of the four details `RootView` presents itself,
    /// because a sheet cannot survive an iPad width change from inside the screen
    /// that owns it.
    func testSurveyDetailSheet() {
        capture(
            launching: { Screenshot.launch($0, tab: "surveys") },
            steps: [
                ScreenshotStep("survey-detail-sheet") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Surveys"]) else { return false }
                    guard self.tapFirst(startingWith: "Example App metric 829", in: app)
                    else { return false }
                    return self.waitUntil { app.buttons["Done"].exists }
                }
            ]
        )
    }

    /// The experiment readout — the longest single screen in the app.
    ///
    /// Twelve sections deep on a running experiment: verdict card, exposure
    /// split, one section per primary metric and one per secondary, progress,
    /// setup, description, variants and the web link. Almost none of it is
    /// reachable by any other means here — it is a sheet (so `ImageRenderer`
    /// cannot present it) whose content is `ScrollView`-clipped (so a renderer
    /// could not show the tail even if it could), and it is the only screen whose
    /// statistical framing — a delta, an interval, a "not significant yet" — is a
    /// *claim about numbers* that a reader has to be able to check by eye.
    ///
    /// The row is named rather than picked by `tapFirstRow`, matching
    /// `AccessibilityAuditTests.testExperimentResults`: it is the one running
    /// experiment in `experiments.json`, so it is the row with a populated
    /// results section rather than a draft's "not started" card. Sharing the
    /// literal with the audit is deliberate — if the fixture's row is renamed,
    /// both fail together and name the same cause.
    ///
    /// **Two steps, and the second scrolls by a fixed count rather than to an
    /// element.** Every section header here is a `SectionLabel`, whose
    /// glyph-and-text pair does not publish its string as a single element — the
    /// same measurement `testClickmapPageOverlay` records — so `scrollIntoView`
    /// has nothing to aim at, and the one `LabeledContent` that would serve
    /// ("Statistics") is rendered only when the results response carries a
    /// method. What is wanted is simply the middle of the same sheet, and a
    /// count of swipes says that without asserting anything false.
    func testExperimentResultsSheet() {
        capture(
            launching: { Screenshot.launch($0, tab: "experiments") },
            steps: [
                ScreenshotStep("experiment-results-sheet") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Experiments"])
                    else { return false }
                    guard self.tapFirst(startingWith: "Example cache strategy trial", in: app)
                    else { return false }
                    return self.waitUntil { app.buttons["Done"].exists }
                },
                ScreenshotStep("experiment-results-metrics") { app in
                    for _ in 0..<3 {
                        app.swipeUp()
                        DemoLaunch.pause(0.4)
                    }
                    // The sheet is still the sheet: a swipe that dismissed it
                    // instead of scrolling it would photograph the list.
                    return app.buttons["Done"].exists
                },
            ]
        )
    }

    /// An LLM trace. The other sheet detail demo mode has rows for.
    ///
    /// **Named, and it is the third screen to need naming — for a reason the
    /// cell test cannot cover.** `ax5/llm-trace-detail-sheet` had never been
    /// captured. From the runner's log: light and dark tapped
    /// `"Trace f5eed704-dbe…, …, cost $0.14, 71.37s, …"`; ax5 tapped
    /// `"Date range, Last 7 days"` twice and timed out. That is the same
    /// accessibility-size `Menu` swap `testPersonDetail` records — but
    /// `LLMAnalyticsRoot` puts its `GlassFilterBar` **inside the `List`**, as
    /// the first section's first row, so the picker is a cell descendant like
    /// every real row and no structural rule here can tell them apart. Naming
    /// the row is what is left; `"Trace "` is the prefix every row in
    /// `llm_traces.json` carries, so it is the fixture's shape rather than one
    /// fixture row.
    func testLLMTraceDetailSheet() {
        capture(
            launching: { Screenshot.launch($0, tab: "llm") },
            steps: [
                ScreenshotStep("llm-trace-detail-sheet") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["LLM"]) else { return false }
                    guard self.tapFirstRow(in: app, startingWith: "Trace ") else { return false }
                    return self.waitUntil { app.buttons["Done"].exists }
                }
            ]
        )
    }

    // MARK: - Pushed details with demo rows

    /// Named explicitly, unlike its six neighbours: Support's first full-width
    /// row is a **summary card** — "8 unread messages / Across 7 unresolved
    /// tickets on this page" — which is not a ticket and navigates nowhere. The
    /// generic rule would pick it and wait out its timeout on a screen that is
    /// working correctly.
    func testSupportTicketDetail() {
        capturePushedDetail(
            tab: "support",
            titled: "Support",
            named: "support-ticket-detail",
            row: "Double charge on the July invoice"
        )
    }

    /// Named, and it is the fourth screen to need naming — for the third
    /// distinct reason.
    ///
    /// `ax5/taxonomy-event-detail` was the one image missing from that
    /// directory. From the runner's log: light and dark tapped
    /// `"feature_used"` at t=4.5s, and the ax5
    /// pass tapped **nothing at all** in 95 seconds — `tapFirstRow` found no
    /// candidate, rather than the wrong one. At an accessibility type size
    /// `TaxonomyRoot`'s first row is taller than the window, so it starts below
    /// the fold and SwiftUI has not built it, and the rule's `app.cells.buttons`
    /// query has nothing to rank. Naming the row routes it through `tap`, which
    /// scrolls before it gives up.
    ///
    /// `feature_used` is the fixture's largest event by volume and this screen sorts
    /// by volume, so it is the top row rather than an arbitrary one.
    func testTaxonomyEventDetail() {
        capturePushedDetail(
            tab: "taxonomy",
            titled: "Taxonomy",
            named: "taxonomy-event-detail",
            row: "feature_used"
        )
    }

    func testSessionSummaryDetail() {
        capturePushedDetail(
            tab: "sessionSummaries", titled: "Summaries", named: "summary-detail"
        )
    }

    func testRenderDetail() {
        capturePushedDetail(tab: "renders", titled: "Renders", named: "render-detail")
    }

    func testGroupTypeDetail() {
        capturePushedDetail(tab: "groups", titled: "Groups", named: "group-type-detail")
    }

    /// People, and the screen that proved `tapFirstRow` needed the cell test.
    ///
    /// This capture could not be produced at **ax5** and could at every other
    /// size, which read as a layout defect in the detail screen and is not one.
    /// The runner's event log showed light and dark tapping the authored demo
    /// person row, while AX5 tapped the preceding **"View, Persons"** button — the
    /// Persons/Cohorts picker in the filter bar above the list. `PeopleRoot`
    /// swaps that `Picker` from `.segmented` to `.menu` at accessibility sizes on
    /// purpose, because a segmented control shreds its labels there; a segmented
    /// control's arms are each under 0.6 of the window and so failed the old
    /// heuristic's width test, and one menu button spanning the bar passes every
    /// one of its tests while sitting *above* the row it was meant to find. The
    /// tap opened a `Menu` popover, the wait for a second navigation bar then
    /// spent its full 30 seconds twice, and the sequence recorded a screen that
    /// renders perfectly well as unreachable.
    ///
    /// Fixed in `tapFirstRow` rather than by naming a row here, because the
    /// picker is chrome on **thirteen** roots and nothing about it is specific to
    /// People.
    func testPersonDetail() {
        capturePushedDetail(tab: "people", titled: "People", named: "person-detail")
    }

    /// The cohorts half of People: the list, a definition, and a definition this
    /// build cannot draw.
    ///
    /// Three frames from one launch, because the interesting thing about this
    /// screen is the *difference* between its states and three separate launches
    /// would photograph them as three unrelated screens.
    ///
    /// The segment switch is the awkward part and it is the same awkwardness
    /// `testPersonDetail` records: `PeopleRoot` renders its Persons/Cohorts
    /// `Picker` as a segmented control at default sizes and as a `Menu` at
    /// accessibility sizes, so at ax5 there is no "Cohorts" arm to tap until the
    /// menu is open. Probed rather than branched on a type size this target
    /// cannot read.
    func testCohortDetail() {
        capture(
            launching: { Screenshot.launch($0, tab: "people") },
            steps: [
                ScreenshotStep("cohorts-list") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["People"]) else { return false }
                    if !self.elements(startingWith: "Cohorts", in: app).firstMatch.exists {
                        // The menu's own label leads with the picker's title:
                        // "View, Persons".
                        guard self.tapFirst(startingWith: "View,", in: app) else { return false }
                    }
                    guard self.tapFirst(startingWith: "Cohorts", in: app) else { return false }
                    // *A* cohort row, not a named one. Measured at ax5: the
                    // first row's title, description and count wrap to more than
                    // a screen, so the second cohort has not been built yet and
                    // waiting on it spent the full 30 seconds on a list that was
                    // right there. Every row's combined label ends "<n> people,
                    // Dynamic" or "…, Static", so this recognises the list
                    // without naming a fixture row — and the step after it
                    // scrolls, which is what reaches the named one.
                    for _ in 0..<12 {
                        let rows = app.buttons.matching(
                            NSPredicate(format: "label BEGINSWITH %@", "Example comet explorers")
                        )
                        for index in 0..<min(rows.count, 12) {
                            let row = rows.element(boundBy: index)
                            if row.exists, row.isHittable { return true }
                        }
                        // AX5 rows can be taller than one viewport. A default
                        // swipe skips their tappable centre; the slow gesture
                        // leaves the first real row visibly framed for capture.
                        app.swipeUp(velocity: .slow)
                        DemoLaunch.pause(0.5)
                    }
                    return false
                },
                ScreenshotStep("cohort-definition") { app in
                    guard self.tapFirstRow(in: app, startingWith: "Example comet explorers")
                    else { return false }
                    // Waited for by *content*, not by a navigation bar, because
                    // the two devices do not produce the same one: on iPhone the
                    // detail is pushed and takes the bar, and on iPad it is the
                    // second column of a `NavigationSplitView`, where
                    // `navigationBars["Example comet explorers"]` did not resolve —
                    // measured, the iPad sweep failed this step twice on a
                    // screen that had rendered. A rule card's accessibility
                    // label is the rule as one sentence (see
                    // `CohortConditionRow`), it exists only on this screen, and
                    // it is the same string on both devices.
                    //
                    // **A disjunction, because neither half covers both.** The
                    // bar alone did not resolve on iPad; the rule card alone did
                    // not resolve at **ax5**, where the header, the description
                    // and the three stat tiles fill more than a screen, so
                    // SwiftUI has not built the definition section yet and there
                    // is no element to wait for. Both were measured failing on a
                    // screen that had rendered, and either one arriving is
                    // enough to say this is the cohort.
                    return self.waitUntil {
                        app.navigationBars["Example comet explorers"].exists
                            || app.descendants(matching: .any).matching(
                                NSPredicate(
                                    format: "label CONTAINS %@", "Example key"
                                )
                            ).firstMatch.exists
                    }
                },
                ScreenshotStep("cohort-definition-rules") { app in
                    // The rule cards themselves, which at ax5 are several
                    // screens below the header — and they are the whole point of
                    // the screen, so a frame that only ever shows the header
                    // would leave the new layout as unobserved as it was before.
                    // Swipes rather than a target: the section header is a
                    // `SectionLabel`, whose glyph-and-text pair publishes no
                    // single element to aim at.
                    for _ in 0..<4 {
                        app.swipeUp()
                        DemoLaunch.pause(0.4)
                    }
                    // Still the same screen: a swipe that popped it instead of
                    // scrolling it would photograph the list.
                    return app.navigationBars["Example comet explorers"].exists
                        || app.descendants(matching: .any).matching(
                            NSPredicate(format: "label CONTAINS %@", "Person property plan")
                        ).firstMatch.exists
                },
                ScreenshotStep("cohort-definition-unsupported") { app in
                    // On iPad the list is a column that never went away, which
                    // is why `popToRoot` treats an already-visible root as
                    // success rather than as a failure to pop.
                    _ = self.popToRoot(app, titled: "People")
                    guard self.tapFirstRow(in: app, startingWith: "Spent over") else { return false }
                    // The unrenderable state's own sentence, for the same
                    // reason the step above waits on content: this screen is a
                    // push on one device and a column on the other.
                    return self.waitUntil {
                        app.navigationBars["Example launch-day visitors"].exists
                            || app.descendants(matching: .any).matching(
                                NSPredicate(
                                    format: "label CONTAINS %@", "SQL query rather than by filters"
                                )
                            ).firstMatch.exists
                    }
                },
            ]
        )
    }

    /// Named explicitly for the same reason Support is: the generic rule picks
    /// the topmost full-width labelled button, and on Flags that is the segmented
    /// status filter above the list rather than a flag.
    func testFlagDetail() {
        capturePushedDetail(
            tab: "flags",
            titled: "Flags",
            named: "flag-detail",
            row: "example-navigation"
        )
    }

    /// The template gallery's detail, reached from a `LazyVGrid` card rather than
    /// a list row — so it is a `Button`, not a `NavigationLink`.
    func testDashboardTemplateDetail() {
        capture(
            launching: { Screenshot.launch($0, tab: "templates") },
            steps: [
                ScreenshotStep("template-detail") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Templates"]) else { return false }
                    guard self.tapFirst(startingWith: "Landing Pages Report", in: app)
                    else { return false }
                    return self.waitUntil { app.navigationBars["Landing Pages Report"].exists }
                }
            ]
        )
    }

    /// Real clicks drawn over a real page render — the one screen in the app that
    /// composites app chrome over a downloaded image.
    func testClickmapPageOverlay() {
        capture(
            launching: { Screenshot.launch($0, tab: "clickmap") },
            steps: [
                ScreenshotStep("clickmap-page-overlay") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Clickmap"]) else { return false }
                    // Scrolled to the *row*, not to its section header: the
                    // header is a `SectionLabel`, whose glyph-and-text pair does
                    // not publish the plain string as one element, so waiting on
                    // it fails on a screen where the row itself is right there.
                    // Either spelling: the fixture's saved render carries the name
                    // "New heatmap" *and* the URL `https://example.com/`, and
                    // which of the two the row leads with is the screen's choice,
                    // not this test's.
                    let row = app.descendants(matching: .any).matching(
                        NSPredicate(
                            format: "label BEGINSWITH %@ OR label CONTAINS %@",
                            "New heatmap", "example.com"
                        )
                    ).firstMatch
                    guard self.scrollIntoView(row, maximumSwipes: 14) else { return false }
                    guard self.tap(row) else { return false }
                    return self.waitUntil {
                        app.otherElements.containing(
                            NSPredicate(format: "label CONTAINS %@", "click")
                        ).firstMatch.exists || !app.navigationBars["Clickmap"].exists
                    }
                }
            ]
        )
    }

    // MARK: - Menus

    /// The project switcher, open. It is in the toolbar of **every** root screen
    /// in this app, and it is a borderless `Menu` — a control whose popover is a
    /// separate window and whose label has already been measured taking the
    /// accent colour when it should not.
    func testProjectSwitcherMenu() {
        capture(
            launching: { Screenshot.launch($0, tab: "dashboards") },
            steps: [
                ScreenshotStep("project-switcher-menu") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Dashboards"]) else { return false }
                    guard self.tapFirst(startingWith: "Current project", in: app) else {
                        return false
                    }
                    return self.waitUntil { app.buttons.count > 0 }
                }
            ]
        )
    }

    /// Ingestion's category filter, open. The borderless `Menu` whose hit target
    /// measured 41×17pt before `minimumHitTarget()` went inside its label closure.
    func testIngestionCategoryMenu() {
        capture(
            launching: { Screenshot.launch($0, tab: "ingestion") },
            steps: [
                ScreenshotStep("ingestion-category-menu") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Ingestion"]) else { return false }
                    guard self.tapFirst(startingWith: "Category filter", in: app) else {
                        return false
                    }
                    // Untyped: a `Picker` row inside a `Menu` is neither a
                    // `StaticText` nor reliably a `Button` — the popover is a
                    // separate window rendered by UIKit, and which element type
                    // its rows resolve to is not this test's business.
                    return self.waitUntil {
                        DemoLaunch.elements(labelled: "All categories", in: app).firstMatch.exists
                    }
                }
            ]
        )
    }

    // MARK: - Sheets behind a toolbar button

    /// The schema browser, and one table's columns.
    ///
    /// This sheet uses the authored `schema_tables.json` inventory and the
    /// matching `schema_columns_events.json` contract. A screen that ships with
    /// rows should be exercised with deterministic rows in this target.
    ///
    /// Waited on by navigation title rather than by a row, because the sheet
    /// draws "Reading the schema" first — the tables arrive on their own request
    /// — and a wait on a row would be a wait on the network beat as well as on
    /// the presentation.
    func testSQLSchemaBrowser() {
        capture(
            launching: { Screenshot.launch($0, tab: "sql") },
            steps: [
                ScreenshotStep("sql-schema-browser") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["SQL"]) else { return false }
                    guard self.tap(app.buttons["Browse tables and columns"]) else { return false }
                    return self.waitUntil { app.navigationBars["Schema"].exists }
                },
                ScreenshotStep("sql-schema-columns") { app in
                    // `events` rather than the first row: the fixture's sections
                    // are ordered by kind and the first row is whichever table
                    // sorts first inside the first kind, while `events` is the
                    // one table whose columns are also recorded. A row that
                    // pushes a detail with no columns under it would photograph
                    // an empty screen and say nothing.
                    guard self.tapFirst(startingWith: "events", in: app) else { return false }
                    return self.waitUntil {
                        !app.navigationBars["Schema"].exists || app.navigationBars.count > 1
                    }
                },
            ]
        )
    }

    /// The annotation composer — this client's second write, and the first one
    /// with a form in front of it.
    ///
    /// Nothing has photographed it. It is a sheet (so no renderer can present
    /// it) carrying a `TextField`, a `DatePicker` and a scope `Picker`, which is
    /// the densest single form in the app and therefore the most likely to break
    /// at an accessibility type size.
    func testAnnotationComposer() {
        capture(
            launching: { Screenshot.launch($0, tab: "annotations") },
            steps: [
                ScreenshotStep("annotation-composer") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Annotations"])
                    else { return false }
                    guard self.tap(app.buttons["New annotation"]) else { return false }
                    return self.waitUntil { app.navigationBars["New annotation"].exists }
                }
            ]
        )
    }

    // MARK: - Opening a tile by tapping it

    /// A dashboard tile opened **by tapping it**, which is the route the rest of
    /// this file reaches through `GETHOG_OPEN_TILE`.
    ///
    /// Kept separate from `testDashboardTileInsight` rather than folded into it,
    /// because the two are asking different questions: that one asks what the
    /// insight detail looks like and sets `selectedTile` directly; this one asks
    /// whether the tile is a control at all. A failure here is an interaction
    /// defect in the app and not a gap in the harness, so it is worth its own
    /// name in the run's output.
    ///
    /// The probe line is printed unconditionally. Four early attempts recorded
    /// only that the tap "did not produce the sheet", which cannot distinguish a
    /// button whose action never fired from a button that was not in the tree —
    /// and the `dashboard-elements` dump taken before `.navigationTransition`
    /// landed showed the latter: six tiles, nineteen buttons, and not one of them
    /// a tile. Printing the frame and the hittability of what was actually found
    /// is what tells those two apart next time.
    ///
    /// **The defect this pins, and what it actually was.** For eight attempts on
    /// 31 Jul this test failed: the tile was in the tree, carried the button
    /// trait, was hittable and correctly sized, and neither the centre tap nor a
    /// second tap on the title row opened anything, in light, dark and ax5. The
    /// standing explanation — that the chart's scrub recogniser eats taps on the
    /// plot — was too small. `chartXSelection` inside the tile's `Button` did not
    /// just consume the plot tap; it left that button unable to fire from
    /// **anywhere** in its bounds for the rest of the screen's life. Bisected on
    /// iPhone 16e: with the plot tap skipped the title row opened the insight in
    /// every build, including builds with `.draggable` and `.contextMenu`
    /// removed; with the plot tapped first nothing opened in any of them, while
    /// the untouched neighbouring tile still opened normally. The fix is in
    /// `TileCard.card` and the measurement is written down there.
    ///
    /// **Which is why the order of the two taps here is load-bearing.** The
    /// centre of the tile is the plot, so the first tap is the one that used to
    /// poison the control, and it is now the one that must open it. The title-row
    /// tap is kept behind it: if the latch ever comes back, the first tap fails
    /// *and* the second fails, and this test says so instead of quietly passing
    /// on a fallback.
    func testDashboardTileTap() {
        capture(
            launching: { Screenshot.launch($0, openURL: Self.dashboard) },
            steps: [
                ScreenshotStep("dashboard-tile-tap") { app in
                    guard DemoLaunch.wait(
                        for: self.elements(startingWith: DemoLaunch.firstTileTitle, in: app)
                            .firstMatch
                    ) else { return false }

                    let tile = app.buttons.matching(
                        NSPredicate(format: "label BEGINSWITH %@", DemoLaunch.firstTileTitle)
                    ).firstMatch
                    print(
                        "TILE-PROBE exists=\(tile.exists) "
                            + "hittable=\(tile.exists ? String(describing: tile.isHittable) : "n/a") "
                            + "frame=\(tile.exists ? String(describing: tile.frame) : "n/a") "
                            + "buttonsOnScreen=\(app.buttons.count)"
                    )
                    let opened = { app.buttons["Done"].exists || app.buttons["Close insight"].exists }

                    guard self.tap(tile) else { return false }
                    if self.waitUntil(timeout: 6, opened) {
                        print("TILE-PROBE opened on the first tap, on the plot")
                        return true
                    }

                    // **Second tap, deliberately not in the middle.**
                    // `XCUIElement.tap()` hits the element's centre, and the
                    // centre of the tile is the plot. 0.5/0.08 is the title row —
                    // inside the same button, above the chart. Reaching this at
                    // all means the plot tap did not open the insight, which is
                    // the defect; reaching it and failing means the button was
                    // latched by that tap, which is the same defect one step
                    // further on.
                    tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
                    DemoLaunch.pause(0.8)
                    let byTitle = self.waitUntil(timeout: 12, opened)
                    print(
                        "TILE-PROBE the plot tap did not open the insight; "
                            + "the title row then opened=\(byTitle)"
                    )
                    return byTitle
                }
            ]
        )
    }

    // MARK: - Settings

    func testSettingsAbout() {
        capture(
            launching: { Screenshot.launch($0, tab: "settings") },
            steps: [
                ScreenshotStep("settings-about") { app in
                    guard DemoLaunch.wait(for: app.navigationBars["Settings"]) else { return false }
                    guard self.tapFirst(startingWith: "About GetHog", in: app) else {
                        return false
                    }
                    // **"About", not "About GetHog".** The row's label and the
                    // screen's title are different strings — `AboutView` sets
                    // `.navigationTitle("About")` — so this wait could not
                    // succeed, and it did not: `settings-about` was missing from
                    // all five device/configuration directories, in every sweep,
                    // while the row itself was being tapped correctly each time.
                    // A row label is not a promise about the title of what it
                    // pushes.
                    return self.waitUntil { app.navigationBars["About"].exists }
                }
            ]
        )
    }

    // MARK: - Helpers

    /// A root whose first list row pushes a detail.
    ///
    /// The row's title is not hardcoded, because seven screens share this and
    /// their fixtures' first rows are seven different strings that would each
    /// need maintaining. What is asserted instead is that a *second* navigation
    /// bar exists after the tap — which is the shape of a push, and fails if the
    /// row was not activatable.
    private func capturePushedDetail(
        tab: String,
        titled title: String,
        named name: String,
        row: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        capture(
            launching: { Screenshot.launch($0, tab: tab) },
            steps: [
                ScreenshotStep(name) { app in
                    guard DemoLaunch.wait(for: app.navigationBars[title]) else { return false }
                    guard self.tapFirstRow(in: app, startingWith: row) else { return false }
                    // On iPhone the detail replaces the root's bar; on iPad it
                    // joins it in a second column. Either way the root's own
                    // title stops being the only one on screen — except on iPad,
                    // where the split view already showed a detail placeholder.
                    return self.waitUntil {
                        !app.navigationBars[title].exists || app.navigationBars.count > 1
                    }
                }
            ],
            file: file,
            line: line
        )
    }

    /// Taps the topmost full-width **labelled button** below the navigation bar.
    ///
    /// Three wrong versions of this preceded it, and the tree is why. Dumped on
    /// Support (`ZZTreeProbe`, since removed):
    ///
    /// ```
    /// collectionViews=1 cells=7 buttons=17
    /// cell[0] (16, 187, 370, 33)  hittable=true  label=""      ← section header
    /// cell[3] (16, 350, 370, 164) hittable=true  label=""      ← the row's shell
    /// button[5..9]  (…, 795, ~74, 54)            label="Events"… ← the tab bar
    /// button[13] (16, 350, 370, 164)             label="Double charge on the…"
    /// ```
    ///
    /// So: `collectionViews.firstMatch` is sometimes the **tab bar**, whose items
    /// are cells too; `cells.element(boundBy: 0)` is a 33pt **section header**
    /// that swallows the tap and navigates nowhere; and every cell on the screen
    /// carries an **empty label**, because a row that combines its subviews
    /// publishes the combined label on the button, not on the shell around it.
    ///
    /// What separates the row from everything else is all three of: a non-empty
    /// label, a width most of the screen's, and a position below the bar. The tab
    /// bar fails the width test (74 of 402pt), the section header fails the label
    /// test, and the toolbar's own controls fail the position test.
    ///
    /// **And a fourth: the row is inside a list cell, and the filter bar is not.**
    /// The three tests above are necessary and were not sufficient — see
    /// `testPersonDetail` for the measurement. A `Picker` rendered
    /// `.pickerStyle(.menu)`, which is what thirteen roots here do at
    /// accessibility type sizes, is a single full-width labelled button sitting
    /// between the navigation bar and the list, and it passes all three. It is
    /// not in a cell; a row always is. So candidates are drawn from
    /// `app.cells.buttons` first, and the whole-app scan is kept only as a
    /// fallback for a screen whose rows are not cells at all — the template
    /// gallery's `LazyVGrid` is the shape that could be — so that a screen this
    /// change does not understand still gets the behaviour it had.
    private func tapFirstRow(in app: XCUIApplication, startingWith prefix: String? = nil) -> Bool {
        if let prefix {
            // Recreate the query after every swipe. At AX5 SwiftUI materialises
            // the first taxonomy row only after the summary card has moved off
            // screen; retaining one `firstMatch` proxy can keep resolving the
            // pre-scroll accessibility tree even after the named row exists.
            // The prefix remains exact fixture identity, and only a visible,
            // hittable match is accepted.
            for _ in 0..<12 {
                let matches = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", prefix)
                )
                for index in 0..<min(matches.count, 12) {
                    let match = matches.element(boundBy: index)
                    guard match.exists, match.isHittable else { continue }
                    match.tap()
                    DemoLaunch.pause(0.8)
                    return true
                }
                app.swipeUp(velocity: .slow)
                DemoLaunch.pause(0.5)
            }
            return false
        }

        guard DemoLaunch.wait(for: app.buttons.firstMatch, timeout: 15) else { return false }
        let bar = app.navigationBars.firstMatch
        let barBottom = bar.exists ? bar.frame.maxY : 0

        // **The two passes want different width floors, and that is the second
        // thing this rule got wrong.** A fraction of the *window* assumes the
        // list spans it, which is false for the three roots that are
        // `NavigationSplitView`s: on iPad Pro 11" the window is ~1210pt and
        // People's sidebar column is 300–440pt, so every row failed
        // `0.6 × window` and `iPad/light/person-detail` had never been captured
        // — the one screen of the seven here missing on that device, while the
        // six stack-only ones captured fine. Inside the cells a flat floor is
        // enough to do the only job the width test ever had, which is excluding
        // the tab bar: its items measured 74pt of 402. The whole-app fallback
        // keeps the fraction, because outside a cell there is nothing else
        // separating a row from a toolbar control.
        let row = topmostRow(in: app.cells.buttons, wider: 240, below: barBottom)
            ?? topmostRow(in: app.buttons, wider: app.frame.width * 0.6, below: barBottom)
        guard let row else { return false }
        return tap(row)
    }

    /// The highest labelled button in a query that is wide enough and low enough
    /// to be a list row.
    private func topmostRow(
        in query: XCUIElementQuery,
        wider minimumWidth: CGFloat,
        below barBottom: CGFloat
    ) -> XCUIElement? {
        var best: XCUIElement?
        var bestY = CGFloat.greatestFiniteMagnitude
        for index in 0..<min(query.count, 60) {
            let button = query.element(boundBy: index)
            guard button.exists, !button.label.isEmpty else { continue }
            let frame = button.frame
            guard frame.width >= minimumWidth, frame.height >= 44, frame.minY > barBottom
            else { continue }
            if frame.minY < bestY {
                bestY = frame.minY
                best = button
            }
        }
        return best
    }
}
