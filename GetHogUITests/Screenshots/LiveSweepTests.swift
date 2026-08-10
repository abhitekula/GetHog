import XCTest

/// Every screen `AppTab` names, photographed against a **real project**.
///
/// The demo sweep next door answers "does this screen render". This one answers
/// the question demo mode structurally cannot: *does it render what a real
/// project actually contains*. Deterministic fixtures are authored to be
/// well-formed — one page of results, labels that fit, every insight a type the
/// app draws. A real project is none of those things, and the defects that live
/// in the gap (an empty collection with no empty state, a label that wraps to
/// four lines, an insight type that falls back, a scope the key does not carry)
/// are invisible to a fixture by construction.
///
/// **Names are prefixed `live-`** so the images land beside the demo sweep's in
/// the same `light/`, `dark/` and `ax5/` directories without colliding, and so
/// `Screenshot.capture`'s duplicate-luminance check still keys on one screen at a
/// time. A reviewer opening `build/Screenshots/<device>/light/` sees the two
/// halves of the same screen next to each other, which is the comparison worth
/// having.
///
/// **Every test skips, not fails, without `.env.local`.** That file is absent for
/// everyone who is not running a live sweep, and a target that failed on checkout
/// would be worse than one that says why it did nothing.
///
/// The second argument is the screen's **own** navigation title, load-bearing for
/// the reason `ScreenshotCase.captureRoot` records.
final class LiveSweepTests: LiveScreenshotCase {

    // MARK: The four primary tabs

    func testDashboards() throws { try captureLiveRoot("dashboards", titled: "Dashboards") }
    func testEvents() throws { try captureLiveRoot("events", titled: "Events") }
    func testSessions() throws { try captureLiveRoot("sessions", titled: "Sessions") }
    func testFlags() throws { try captureLiveRoot("flags", titled: "Flags") }

    // MARK: Search — the fifth tab, and the index of everything below

    func testSearch() throws { try captureLiveRoot("search", titled: "Search") }

    // MARK: Analyze

    func testInsights() throws { try captureLiveRoot("insights", titled: "Insights") }
    func testWebAnalytics() throws { try captureLiveRoot("webAnalytics", titled: "Web") }
    func testClickmap() throws { try captureLiveRoot("clickmap", titled: "Clickmap") }
    func testPeople() throws { try captureLiveRoot("people", titled: "People") }
    func testGroups() throws { try captureLiveRoot("groups", titled: "Groups") }
    func testSQL() throws { try captureLiveRoot("sql", titled: "SQL") }

    // MARK: Diagnose

    func testErrorTracking() throws { try captureLiveRoot("errorTracking", titled: "Errors") }
    func testSessionSummaries() throws { try captureLiveRoot("sessionSummaries", titled: "Summaries") }
    func testLLM() throws { try captureLiveRoot("llm", titled: "LLM") }
    func testTracing() throws { try captureLiveRoot("tracing", titled: "Tracing") }
    func testLogs() throws { try captureLiveRoot("logs", titled: "Logs") }
    func testSupport() throws { try captureLiveRoot("support", titled: "Support") }
    func testInbox() throws { try captureLiveRoot("inbox", titled: "Inbox") }
    func testSignals() throws { try captureLiveRoot("signals", titled: "Signals") }
    func testHealth() throws { try captureLiveRoot("health", titled: "Health") }
    func testIngestion() throws { try captureLiveRoot("ingestion", titled: "Ingestion") }

    // MARK: Data

    func testWarehouse() throws { try captureLiveRoot("warehouse", titled: "Warehouse") }
    func testPipelines() throws { try captureLiveRoot("pipelines", titled: "Pipelines") }
    func testAutomation() throws { try captureLiveRoot("automation", titled: "Automation") }
    func testActions() throws { try captureLiveRoot("actions", titled: "Actions") }
    func testAnnotations() throws { try captureLiveRoot("annotations", titled: "Annotations") }
    func testTaxonomy() throws { try captureLiveRoot("taxonomy", titled: "Taxonomy") }

    // MARK: Experiment

    func testExperiments() throws { try captureLiveRoot("experiments", titled: "Experiments") }
    func testSurveys() throws { try captureLiveRoot("surveys", titled: "Surveys") }
    func testEarlyAccess() throws { try captureLiveRoot("earlyAccess", titled: "Early access") }

    // MARK: Compose

    func testNotebooks() throws { try captureLiveRoot("notebooks", titled: "Notebooks") }
    func testMax() throws { try captureLiveRoot("max", titled: "Max") }
    func testRenders() throws { try captureLiveRoot("renders", titled: "Renders") }
    func testTemplates() throws { try captureLiveRoot("templates", titled: "Templates") }

    // MARK: Utility

    func testSettings() throws { try captureLiveRoot("settings", titled: "Settings") }
}


/// The detail screen under each collection, reached by opening whatever the
/// project's first row happens to be.
///
/// **Why tapping rather than a deep link.** `StateScreenshotTests` addresses its
/// detail screens by `gethog://` URL with an id out of the fixtures — the
/// dashboard is 725101, the replay session is a known UUID. None of those ids
/// exist in a real project, and inventing the live equivalents would mean
/// querying the API for them first and hard-coding whatever came back, which
/// rots the moment the project changes. The first row is stable in the only sense
/// that matters here: there is always one, or there is an empty state, and both
/// are worth a photograph.
///
/// **A screen with no rows is not a skipped test.** It captures whatever the app
/// shows instead, and the reachability is printed as `LIVE-DETAIL <name> rows=N`
/// so the sweep's own log says which of the two a given image is. An empty
/// collection rendering a bare list rather than an empty state is precisely the
/// defect class this sweep exists to find, and skipping would hide it.
final class LiveDetailSweepTests: LiveScreenshotCase {

    func testDashboardDetail() throws {
        try captureLiveDetail("dashboards", titled: "Dashboards", named: "dashboard-detail")
    }

    func testInsightDetail() throws {
        try captureLiveDetail("insights", titled: "Insights", named: "insight-detail")
    }

    func testEventDetail() throws {
        try captureLiveDetail("events", titled: "Events", named: "event-detail")
    }

    func testSessionDetail() throws {
        // The slowest screen in the app by a wide margin: the player boots rrweb
        // in a web view and is then fed snapshots, measured at up to two minutes
        // on the demo fixtures alone. Live recordings are fetched first.
        try captureLiveDetail(
            "sessions", titled: "Sessions", named: "session-detail", settleFor: 120
        )
    }

    func testPersonDetail() throws {
        try captureLiveDetail("people", titled: "People", named: "person-detail")
    }

    func testFlagDetail() throws {
        try captureLiveDetail("flags", titled: "Flags", named: "flag-detail")
    }

    func testErrorIssueDetail() throws {
        try captureLiveDetail("errorTracking", titled: "Errors", named: "error-issue-detail")
    }

    func testExperimentDetail() throws {
        try captureLiveDetail("experiments", titled: "Experiments", named: "experiment-detail")
    }

    func testSurveyDetail() throws {
        try captureLiveDetail("surveys", titled: "Surveys", named: "survey-detail")
    }

    func testGroupDetail() throws {
        try captureLiveDetail("groups", titled: "Groups", named: "group-detail")
    }

    func testAnnotationDetail() throws {
        try captureLiveDetail("annotations", titled: "Annotations", named: "annotation-detail")
    }

    func testActionDetail() throws {
        try captureLiveDetail("actions", titled: "Actions", named: "action-detail")
    }

    func testTaxonomyDetail() throws {
        try captureLiveDetail("taxonomy", titled: "Taxonomy", named: "taxonomy-detail")
    }

    func testLLMTraceDetail() throws {
        try captureLiveDetail("llm", titled: "LLM", named: "llm-trace-detail")
    }

    func testSessionSummaryDetail() throws {
        try captureLiveDetail(
            "sessionSummaries", titled: "Summaries", named: "session-summary-detail"
        )
    }

    func testWarehouseDetail() throws {
        try captureLiveDetail("warehouse", titled: "Warehouse", named: "warehouse-detail")
    }

    func testLogDetail() throws {
        try captureLiveDetail("logs", titled: "Logs", named: "log-detail")
    }

    func testNotebookDetail() throws {
        try captureLiveDetail("notebooks", titled: "Notebooks", named: "notebook-detail")
    }
}


/// Shared plumbing for the live half.
///
/// Subclasses `ScreenshotCase` for its configuration matrix, per-step appearance
/// toggling and duplicate check, and replaces only the two things that differ:
/// where the app gets its data, and how long it is reasonable to wait for it.
class LiveScreenshotCase: ScreenshotCase {

    /// The credential check every test in the live half begins with.
    func requireCredential() throws {
        try LiveCredentials.require()
    }

    /// Waits out a **network** load rather than `DemoTransport`'s 120ms sleep.
    ///
    /// `DemoLaunch.settle` bounds its poll at six seconds, which is generous for
    /// a fixture served from the app bundle and far too short for a cold query
    /// against a real project — an insight that has to be computed rather than
    /// read is routinely longer than that. A screenshot taken early photographs a
    /// skeleton, and a directory of skeletons is a defect report written against
    /// the loading state of every screen in the app.
    ///
    /// Polls `exists` rather than calling `waitForNonExistence`, for the reason
    /// `DemoLaunch.settle` records: XCTest captures a full element debug
    /// description on every failed check, and enough of those in a row take the
    /// runner down rather than failing a test.
    static func settleLive(_ app: XCUIApplication, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.activityIndicators.firstMatch.exists { break }
            DemoLaunch.pause(0.5)
        }
        // Charts and lists animate in once the data lands; a frame inside that
        // catches a bar at 40% height, which reads as a data defect and is not
        // one. Longer than the demo sweep's 0.9 because a live list is usually
        // longer and its animation correspondingly so.
        DemoLaunch.pause(1.2)
    }

    /// Redaction placeholders do not expose a native activity indicator.
    ///
    /// Warehouse issues three requests and redacts the list while the first two
    /// are pending, so the generic live settle can otherwise photograph the
    /// skeleton as if it were a terminal screen. The root publishes a state-only
    /// identifier after all requests resolve; it exposes no project values and
    /// is not defeated by accessibility-sized lazy lists.
    static func waitForWarehouseTerminalState(in app: XCUIApplication) -> Bool {
        let terminal = app.descendants(matching: .any)["gethog.warehouse-terminal"]
        return DemoLaunch.wait(for: terminal, timeout: 60)
    }

    /// A tab root, live.
    func captureLiveRoot(
        _ tab: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try requireCredential()
        capture(
            launching: {
                Screenshot.launch(
                    $0, tab: tab, environment: LiveCredentials.environment, demo: false
                )
            },
            steps: [
                ScreenshotStep("live-\(tab)") { app in
                    // The title wait is the guard as much as the sync. If the
                    // credential is rejected the app sits on onboarding, and
                    // without this every image in the sweep would be a
                    // photograph of the welcome screen filed under a product
                    // name.
                    guard DemoLaunch.wait(for: app.navigationBars[title], timeout: 45) else {
                        print("LIVE-UNREACHED \(tab)")
                        return false
                    }
                    Self.settleLive(app)
                    if tab == "warehouse" {
                        guard Self.waitForWarehouseTerminalState(in: app) else {
                            print("LIVE-UNSETTLED warehouse")
                            return false
                        }
                    }
                    return true
                }
            ],
            file: file,
            line: line
        )
    }

    /// Opens the first row that actually navigates, and says which one did.
    ///
    /// **This exists because the obvious version lied.** The first draft tapped
    /// `app.cells.firstMatch`, printed `opened=cell` whenever a tap had been
    /// *issued*, and returned. Fifteen of eighteen "detail" captures in the
    /// first live sweep turned out to be photographs of the list screen —
    /// verified afterwards by downsampling each pair to 32×32 and differencing,
    /// where fifteen scored 0.0 against their own list and only Sessions,
    /// Insights and People scored above 12. The log had said `rows=8
    /// opened=cell` for every one of them.
    ///
    /// A tap being issued is not a screen being reached, and a capture harness
    /// that cannot tell the difference produces a directory of confident
    /// mislabels — which is the same failure `scripts/run-ui-tests` exists to
    /// catch in test counts, one layer down.
    ///
    /// So navigation is now *proven* before the name is claimed: a pushed screen
    /// either shows a back button carrying the list's title, or no longer shows
    /// the list's own navigation bar. Rows are tried in order until one of those
    /// holds, because the first cell is often chrome — a search field or a
    /// section header — rather than a row.
    ///
    /// Deliberately restricted to cells. Tapping arbitrary `buttons` would reach
    /// rows the app draws as cards, but it would also reach the toggle in a flag
    /// row, and a sweep that runs unattended against a real project has no
    /// business pressing controls it did not identify. The app confirms before
    /// changing a flag, so even that would be caught — relying on it would still
    /// be the wrong shape.
    ///
    /// Returns a description for the log. `opened=none` is an honest outcome and
    /// still captures: an empty collection is a real state of a real project,
    /// and whether the app draws an empty state or a bare list is exactly what
    /// this sweep is for.
    static func openFirstRow(
        in app: XCUIApplication,
        below listTitle: String,
        timeout: TimeInterval
    ) -> String {
        let rows = app.cells
        let count = rows.count
        guard count > 0 else { return "rows=0 opened=none" }

        for index in 0..<min(count, 8) {
            let row = rows.element(boundBy: index)
            guard row.exists, row.isHittable else { continue }
            row.tap()
            settleLive(app, timeout: timeout)

            let pushed = DemoLaunch.wait(timeout: 15) {
                app.navigationBars.buttons[listTitle].exists
                    || !app.navigationBars[listTitle].exists
            }
            if pushed { return "rows=\(count) opened=cell[\(index)]" }
        }
        return "rows=\(count) opened=none-navigated"
    }

    /// A tab root, then whatever its first row opens.
    func captureLiveDetail(
        _ tab: String,
        titled title: String,
        named name: String,
        settleFor timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try requireCredential()
        capture(
            launching: {
                Screenshot.launch(
                    $0, tab: tab, environment: LiveCredentials.environment, demo: false
                )
            },
            steps: [
                ScreenshotStep("live-\(name)") { app in
                    guard DemoLaunch.wait(for: app.navigationBars[title], timeout: 45) else {
                        print("LIVE-UNREACHED \(name)")
                        return false
                    }
                    Self.settleLive(app, timeout: timeout)

                    print("LIVE-DETAIL \(name) \(Self.openFirstRow(in: app, below: title, timeout: timeout))")
                    return true
                }
            ],
            file: file,
            line: line
        )
    }
}
