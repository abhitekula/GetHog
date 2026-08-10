import XCTest

/// Walks every screen the Mac sidebar reaches and photographs it.
///
/// The point of this suite is not its assertions — they are deliberately
/// shallow, an anchor its demo fixture alone can produce plus an app still in
/// the foreground. The point is the **attachments**: one full-screen shot per
/// screen, kept always, so a sweep is read rather than inferred. A screen can
/// pass "the row exists" while its detail floats at sheet size in a 1600pt
/// window, and no assertion anybody would write in advance catches that. A
/// photograph does.
///
/// Split by sidebar section so one broken screen costs one test's screens
/// rather than all thirty-four, and so a re-sweep after a fix reruns the
/// section that changed.
///
/// Sizes: the default pass asserts and shoots at the launch size the shell
/// declares (1280×820). The narrow and wide passes are screenshot-only and off
/// unless `TEST_RUNNER_GETHOG_SWEEP_SIZES=all` is set, because they triple the
/// runtime and exist for a human reading images, not for CI.
///
/// **Screenshot indices follow `AppTab.sections`, which is the sidebar's real
/// order: Analyze, Monitor, Data, Experiment, Workspace.** Read the exported
/// PNGs against the numbering here, not against any external table — Data
/// (Warehouse…Taxonomy) precedes Experiment (Flags…Early access), and a table
/// that lists them the other way round will mis-attribute a finding to the
/// wrong screen.
final class MacSurfaceSweepTests: XCTestCase {

    override func setUpWithError() throws {
        // A sweep is worth more finished than stopped: one screen that fails to
        // render should still leave photographs of the ones after it, which is
        // exactly the evidence needed to tell "this screen is broken" from "the
        // shell fell over".
        continueAfterFailure = true
    }

    // MARK: - The surface

    /// One sidebar destination and the demo string that proves it rendered.
    private struct Screen {
        /// The sidebar row's label — `AppTab.title`, verbatim.
        let title: String
        /// A string only this screen's fixture can produce, traced from the
        /// fixture through the model to the rendered row before being pinned
        /// here — never copied from a plan, which is how two anchors that do
        /// not render got proposed for this file.
        ///
        /// `nil` means one of two things, and each `nil` below says which in a
        /// comment: the demo dataset has no fixture for the screen, or its
        /// demo-derived content is not on the root. A `nil` anchor is
        /// screenshot-only, and the screenshot is what says whether the screen
        /// is populated, empty and honest, or stuck.
        let anchor: String?
        /// Screenshot filename stem, so shots sort in sweep order.
        let index: Int

        init(_ index: Int, _ title: String, anchor: String? = nil) {
            self.index = index
            self.title = title
            self.anchor = anchor
        }
    }

    /// Search sits loose above the sections; the nine Analyze screens follow.
    private static let analyze: [Screen] = [
        Screen(1, "Search"),
        Screen(2, "Dashboards", anchor: "Example App metric 33"),
        // The events feed is backed by `query_hogql.json`, the generic HogQL
        // fixture (`DemoTransport.swift`'s documented fallback) — *not* by
        // `event_definitions.json`, which is a different screen's data. Its
        // first row's event name is this, and `EventAppearance.displayName`
        // passes any name without a `$` prefix through verbatim.
        Screen(3, "Events", anchor: "meteor_report_opened"),
        Screen(4, "Sessions", anchor: "Alex Example"),
        Screen(5, "Insights", anchor: "Example meteor report"),
        Screen(6, "Web", anchor: "sample visitors"),
        // Unanchored, and the sweep is what established why: demo mode has no
        // route for `/api/projects/1001/heatmaps/`, so the screen renders an
        // honest "Couldn't load the clickmap" naming the missing fixture. The
        // saved render this once expected cannot appear until DemoTransport
        // answers that endpoint. Same class as Pipelines and Inbox below —
        // a demo-data gap, not a Mac defect, and it reads identically on iOS.
        Screen(7, "Clickmap"),
        Screen(8, "People", anchor: "Sable Okafor"),
        // The root lists group *types*; the groups themselves are a level down.
        // This is the raw type from `groups_types.json`, which the type row
        // carries as its subtitle and which `DataRow` folds into the row label.
        Screen(9, "Groups", anchor: "example-team"),
        // Deliberately unanchored. The console's demo-derived content is the
        // schema browser and the query result, and neither is on the root: the
        // browser is a `.sheet` (`SQLConsoleRoot.swift:301`) and the result
        // needs a run. The seeded statement is real text but lives in an editor,
        // whose content is a value rather than a label. The screenshot is the
        // evidence here, and a stuck console is still visible in it.
        Screen(10, "SQL"),
    ]

    private static let monitor: [Screen] = [
        Screen(11, "Errors", anchor: "HarborRenderFault"),
        // `single_session_summaries.json` carries exactly one row, and the
        // header row states the count in words.
        Screen(12, "Summaries", anchor: "1 summarized session"),
        // The trace's `distinctID` subtitle. `displayName` is not usable here:
        // `llm_traces.json`'s first row carries no `traceName`, so it falls
        // back to an id.
        Screen(13, "LLM", anchor: "synthetic-id-0099"),
        Screen(14, "Tracing"),
        Screen(15, "Logs"),
        // `SupportTicket.displayTitle` prefers `email_subject`, which the first
        // ticket in `conversations_tickets.json` has.
        Screen(16, "Support", anchor: "Example email subject 0735"),
        // No route for `/api/projects/1001/tasks/` — same honest error state.
        Screen(17, "Inbox"),
        Screen(18, "Signals"),
        Screen(19, "Health"),
        // Humanised, not raw: `IngestionWarning.title` is
        // `humanise(type)`, so the fixture's `quota_limited_wandering_hedgehog`
        // reaches the row as this.
        Screen(20, "Ingestion", anchor: "Quota limited wandering hedgehog"),
    ]

    private static let data: [Screen] = [
        Screen(21, "Warehouse", anchor: "example_meteor_delivery_failures"),
        Screen(22, "Pipelines"),
        Screen(23, "Automation"),
        Screen(24, "Actions"),
        Screen(25, "Annotations"),
        Screen(26, "Taxonomy"),
    ]

    private static let experiment: [Screen] = [
        Screen(27, "Flags", anchor: "example-navigation"),
        Screen(28, "Experiments", anchor: "Example cache strategy trial"),
        Screen(29, "Surveys", anchor: "Example App metric 829"),
        Screen(30, "Early access"),
    ]

    private static let workspace: [Screen] = [
        Screen(31, "Notebooks", anchor: "Orbit field log"),
        Screen(32, "Max"),
        Screen(33, "Renders"),
        Screen(34, "Templates", anchor: "Example App metric 125"),
    ]

    // MARK: - Tests

    func testAnalyzeScreensRender() {
        sweep(Self.analyze)
    }

    func testMonitorScreensRender() {
        sweep(Self.monitor)
    }

    func testDataAndExperimentScreensRender() {
        sweep(Self.data + Self.experiment)
    }

    func testWorkspaceScreensRender() {
        let app = sweep(Self.workspace)

        // Screen 35, and the only one with no sidebar row: Settings is a scene
        // of its own, reached the way a Mac user reaches it.
        let windowsBefore = app.windows.count
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count > windowsBefore }),
            "⌘, never opened the Settings scene."
        )
        DemoLaunch.settle(app)
        capture(app, name: "35-settings-default")
    }

    /// Manual, authenticated counterpart to the deterministic demo sweep.
    ///
    /// Normal CI never spends a real workspace's request budget: without the
    /// opt-in control file this test is skipped before it creates an
    /// application. The runner reads the untracked credential file directly;
    /// XCUITest then hands its two allowlisted values to the app as process
    /// environment, never as an argument, fixture, screenshot label, or
    /// diagnostic string.
    func testLivePATAllRootScreensRender() throws {
        try LiveCredentials.requireSweep()

        guard ExclusiveRun.claim() else { return }
        let app = XCUIApplication()
        app.launchEnvironment = LiveCredentials.environment
        app.launchEnvironment["GETHOG_TAB"] = "dashboards"
        app.launch()

        let dashboardDestination = app.windows.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate("Dashboards"))
            .firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: dashboardDestination, timeout: 60),
            "The authenticated Mac shell never rendered its dashboard destination."
        )

        let roots = Self.analyze + Self.monitor + Self.data + Self.experiment + Self.workspace
        for screen in roots {
            open(screen.title, in: app)
            // A live endpoint may begin its request on the frame after the
            // destination click. Give that frame time to arrive before polling
            // the native progress indicator, then photograph the settled view.
            DemoLaunch.pause(0.75)
            DemoLaunch.settle(app, timeout: 20)
            if screen.title == "Warehouse" {
                XCTAssertTrue(
                    waitForWarehouseTerminalState(in: app),
                    "The live Warehouse screen never left its redacted loading state."
                )
            }
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "The app was gone by live \(screen.title)."
            )
            captureLiveWindow(
                app,
                name: String(format: "live-%02d-%@", screen.index, slug(screen.title))
            )
        }

        open("Dashboards", in: app)
        let dashboardCards = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                "gethog.dashboard-card.",
                "gethog.dashboard-recent-card."
            )
        )
        var dashboardCard: XCUIElement?
        guard DemoLaunch.wait(timeout: 60, until: {
            dashboardCard = dashboardCards.allElementsBoundByIndex.first { $0.isHittable }
            return dashboardCard != nil
        }), let dashboardCard else {
            XCTFail("The live dashboard hub never exposed an actionable dashboard card.")
            return
        }
        let dashboardPrefixes = [
            "gethog.dashboard-card.",
            "gethog.dashboard-recent-card.",
        ]
        guard let dashboardPrefix = dashboardPrefixes.first(where: {
            dashboardCard.identifier.hasPrefix($0)
        }) else {
            XCTFail("The selected live dashboard card had no stable identifier prefix.")
            return
        }
        let dashboardID = String(dashboardCard.identifier.dropFirst(dashboardPrefix.count))
        guard !dashboardID.isEmpty else {
            XCTFail("The selected live dashboard card had an empty stable identifier suffix.")
            return
        }
        dashboardCard.click()

        let dashboardDetail = app.descendants(matching: .any)[
            "gethog.dashboard-detail.\(dashboardID)"
        ]
        guard DemoLaunch.wait(for: dashboardDetail, timeout: 60) else {
            XCTFail("The live dashboard card never opened its matching stable detail root.")
            return
        }
        let dashboardActions = DemoLaunch.elements(labelled: "Dashboard actions", in: app).firstMatch
        guard DemoLaunch.wait(timeout: 60, until: {
            dashboardActions.exists && dashboardActions.isHittable
        }) else {
            XCTFail("The live dashboard detail never exposed its actions.")
            return
        }
        XCTAssertEqual(app.state, .runningForeground, "The live dashboard detail took the app down.")
        captureLiveWindow(app, name: "live-dashboard-detail")

        let windowsBefore = app.windows.count
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count > windowsBefore }),
            "The live sweep could not open Settings with Command-comma."
        )
        DemoLaunch.settle(app, timeout: 20)
        captureLiveWindow(app, name: "live-35-settings")
    }

    /// The flows a list row opens, which is where an iOS-ism survives longest:
    /// a detail that was a sheet on the phone has to fill the Mac's detail
    /// column, and a screenshot is the only thing that says whether it does.
    func testDetailFlowsRender() {
        let app = DemoLaunch.launch()

        for (title, rowText, name) in Self.detailFlows {
            open(title, in: app)
            if title == "Dashboards" {
                let row = app.buttons["gethog.dashboard-card.725101"].firstMatch
                var scrolls = 0
                while !row.exists && scrolls < 12 {
                    app.scrollViews["gethog.dashboard-hub"].scroll(byDeltaX: 0, deltaY: -180)
                    scrolls += 1
                }
                guard DemoLaunch.wait(for: row) else {
                    XCTFail("Dashboards never offered gethog.dashboard-card.725101.")
                    continue
                }
                row.click()
                let detail = app.descendants(matching: .any)["gethog.dashboard-detail.725101"]
                XCTAssertTrue(
                    DemoLaunch.wait(for: detail),
                    "The dashboard card did not open its matching detail root."
                )
                DemoLaunch.settle(app)
                capture(app, name: "\(name)-default")
                XCTAssertEqual(app.state, .runningForeground, "Dashboards' detail took the app down.")
                continue
            }
            guard let row = DemoLaunch.waitForContent(containing: rowText, in: app) else {
                XCTFail("\(title) never offered a row containing \(rowText).")
                continue
            }
            row.click()
            DemoLaunch.settle(app)
            capture(app, name: "\(name)-default")
            XCTAssertEqual(app.state, .runningForeground, "\(title)'s detail took the app down.")
        }
    }

    /// Sidebar row, the row to click in it, and the shot's name.
    ///
    /// Three of the four ex-sheet screens lead — `llm`, `experiments` and
    /// `surveys` had their detail lifted out of a sheet and into a navigation
    /// destination, and this is where that lands or does not. The fourth,
    /// `pipelines`, is absent on purpose: the demo dataset ships no
    /// `hog_functions` fixture, so there is no row to open. Its root
    /// screenshot at all three sizes is the whole evidence available, and a
    /// stuck spinner there is still a finding.
    ///
    /// The LLM row is named by its `distinctID` subtitle, because a trace's
    /// `displayName` falls back to an id when the fixture carries no
    /// `traceName` — which this one does not.
    private static let detailFlows: [(String, String, String)] = [
        ("LLM", "synthetic-id-0099", "d1-llm-detail"),
        ("Experiments", "Example cache strategy trial", "d2-experiments-detail"),
        ("Surveys", "Example App metric 829", "d3-surveys-detail"),
        ("Dashboards", "Example App metric 33", "d4-dashboard-detail"),
        ("Sessions", "Alex Example", "d5-replay-detail"),
        ("Insights", "Example meteor report", "d6-insight-detail"),
        ("Notebooks", "Orbit field log", "d7-notebook-detail"),
    ]

    /// The pointer over a chart, photographed at the two positions that decide
    /// whether the hover scrub is right.
    ///
    /// This is the regression guard the hover work left owed. It does not
    /// assert the readout's text: the hover overlay is `accessibilityHidden`
    /// by design — a clear rectangle over every chart would otherwise be a stop
    /// on the VoiceOver tour — so the readout is not addressable by the query
    /// this suite could write in advance, and an assertion invented for it
    /// would pin the wrong thing. What it does is put the pointer where the
    /// answer is and keep the pictures.
    ///
    /// The two positions are the point: the plot centre is the case that has
    /// to work, and the margin just inside the plot edge is the 12pt
    /// scale-padding band where `ChartHover`'s selection can resolve to `nil`
    /// and blank a readout that should have held its last real sample. Read
    /// the two shots side by side; a blank margin shot is the finding.
    func testChartHoverHoldsItsReadout() {
        let app = DemoLaunch.launch()

        open("Dashboards", in: app)
        guard let row = DemoLaunch.waitForContent(containing: "Example App metric 33", in: app) else {
            XCTFail("The dashboard list never offered its first row.")
            return
        }
        row.click()

        guard let tile = DemoLaunch.waitForContent(
            containing: DemoLaunch.firstTileTitle, in: app
        ) else {
            XCTFail("The dashboard detail never rendered \(DemoLaunch.firstTileTitle).")
            return
        }
        DemoLaunch.settle(app)

        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        DemoLaunch.settle(app)
        capture(app, name: "h1-chart-hover-centre")

        // Just inside the left edge of the plot — the scale-padding band.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.6)).hover()
        DemoLaunch.settle(app)
        capture(app, name: "h2-chart-hover-margin")

        XCTAssertEqual(app.state, .runningForeground, "Hovering the chart took the app down.")
    }

    // MARK: - The sweep

    @discardableResult
    private func sweep(_ screens: [Screen]) -> XCUIApplication {
        let app = DemoLaunch.launch()

        for screen in screens {
            open(screen.title, in: app)

            if let anchor = screen.anchor {
                XCTAssertNotNil(
                    DemoLaunch.waitForContent(containing: anchor, in: app),
                    "\(screen.title) never rendered its demo anchor “\(anchor)”."
                )
            }
            // Holds for anchored and unanchored screens alike, and is the one
            // thing a photograph cannot show: that the screen before this did
            // not take the process with it.
            XCTAssertEqual(app.state, .runningForeground, "The app was gone by \(screen.title).")

            capture(app, name: "\(screen.index)-\(slug(screen.title))-default")
        }

        sweepAlternateSizes(screens, in: app)
        return app
    }

    /// The narrow and wide passes: photographs only, and never a failure.
    ///
    /// Nothing here asserts, on purpose. Resizing a window from a UI test is
    /// the least reliable thing this suite does — there is no resize API, only
    /// a drag of the frame's corner — and a sweep whose *evidence-gathering*
    /// step can fail the run would make the fix loop chase the harness instead
    /// of the app. If a drag does not take, the screenshot shows the size that
    /// was actually reached, which is still the truth about what was seen.
    private func sweepAlternateSizes(_ screens: [Screen], in app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["GETHOG_SWEEP_SIZES"] == "all" else { return }

        for (label, size) in [("narrow", CGSize(width: 800, height: 600)),
                              ("wide", CGSize(width: 1_800, height: 1_100))] {
            resizeMainWindow(of: app, to: size)
            for screen in screens {
                // `reach`, not `open`: at 800×600 the sidebar is the single most
                // likely thing to collapse or drop out of the outline query, and
                // `open` ends in an `XCTFail`. A screen this pass cannot get to
                // is a screenshot not taken, not a failed run — which is the
                // contract this whole function is written to.
                guard reach(screen.title, in: app) else { continue }
                capture(app, name: "\(screen.index)-\(slug(screen.title))-\(label)")
            }
        }
    }

    /// Drags the main window's bottom-right corner.
    ///
    /// Normalized offsets rather than absolute points: the window's own frame
    /// is the origin, so this works wherever the window happens to sit. The
    /// drag starts just inside the corner because the resize handle is on the
    /// frame edge itself.
    private func resizeMainWindow(of app: XCUIApplication, to size: CGSize) {
        let window = app.windows.firstMatch
        guard window.exists else { return }

        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        let target = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: size.width / max(frame.width, 1),
                dy: size.height / max(frame.height, 1)
            )
        )
        corner.press(forDuration: 0.2, thenDragTo: target)
        DemoLaunch.settle(app)
    }

    // MARK: - Helpers

    /// The sidebar destination carrying an exact title, scoped the way
    /// `MacNavigationTests.sidebarItem` scopes it — the content area can
    /// legitimately carry the same word, and the menu bar certainly does.
    private func sidebarItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // Every outline, not just the first. On a split-view screen the
        // content list is *also* an outline — measured: the Sessions list
        // reports `Outline, label: 'Sidebar'` at x=271 — so `firstMatch` can
        // resolve to the content column, miss the destination, and fall through
        // to an app-wide query that returns a zero-size off-screen duplicate.
        // Asking every outline for a hittable match removes the ambiguity.
        for sidebar in app.outlines.allElementsBoundByIndex {
            let scoped = sidebar.descendants(matching: .any)
                .matching(DemoLaunch.macTextPredicate(title))
            if let hittable = scoped.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                return hittable
            }
        }
        return app.windows.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate(title))
            .firstMatch
    }

    /// Clicks a sidebar destination, failing the test if it is not there.
    /// The default pass's route: a missing destination is a finding.
    private func open(_ title: String, in app: XCUIApplication) {
        if !reach(title, in: app) {
            XCTFail("No sidebar destination labelled \(title).")
        }
    }

    /// Clicks a sidebar destination and says whether it got there, scrolling the
    /// sidebar to it first if it is below the fold — thirty-four rows do not fit
    /// 820pt, and the rows at the bottom of Workspace are exactly the ones
    /// nobody has looked at.
    ///
    /// Returning a `Bool` rather than failing is what lets the screenshot-only
    /// size passes keep their promise not to fail the run; `open` puts the
    /// failure back for the passes that assert.
    @discardableResult
    private func reach(_ title: String, in app: XCUIApplication) -> Bool {
        var item = sidebarItem(title, in: app)
        // **A missing row is a reason to try the menu, not to give up.** This
        // returned `false` here, which is why the narrow and wide passes
        // produced no screenshots at all: at 800×600 the split view collapses
        // its sidebar, so *no* destination row exists, the 30-second existence
        // wait timed out on every screen, and the Go-menu fallback forty lines
        // below — which needs no sidebar and would have worked — was never
        // reached. Five seconds, because a row that is going to appear has
        // appeared by then; the launch gate already waited for the shell.
        guard DemoLaunch.wait(for: item, timeout: 5) else {
            return openViaGoMenu(title, in: app)
        }

        // Existence is not reachability in a scrolling outline.
        // Scroll monotonically toward the bottom, then back toward the top.
        // The first attempt alternated direction and therefore netted zero,
        // which is why the Workspace rows were never reached and their
        // screenshots caught the *previous* screen still on display.
        var scrolls = 0
        while !item.isHittable && scrolls < 12 {
            app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: -120)
            item = sidebarItem(title, in: app)
            scrolls += 1
        }
        while !item.isHittable && scrolls < 24 {
            app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: 120)
            item = sidebarItem(title, in: app)
            scrolls += 1
        }

        // Last resort, and a check in its own right: the Go menu lists every
        // destination and needs no scrolling. If the sidebar could not be made
        // to reach a screen but the menu can, the sweep still photographs the
        // screen and the difference is itself worth knowing.
        guard item.isHittable else { return openViaGoMenu(title, in: app) }

        item.click()
        DemoLaunch.settle(app)
        return true
    }


    /// Routes to a destination through the Go menu, which needs no scrolling
    /// because a menu is not a viewport. Also a check in its own right: if the
    /// sidebar could not be made to reach a screen but the menu can, the sweep
    /// still photographs the screen and the difference is worth knowing.
    private func openViaGoMenu(_ title: String, in app: XCUIApplication) -> Bool {
        let go = app.menuBars.menuBarItems["Go"]
        guard go.exists else { return false }
        go.click()
        let entry = app.menuItems[title]
        guard DemoLaunch.wait(for: entry, timeout: 5), entry.isEnabled else {
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        entry.click()
        DemoLaunch.settle(app)
        return true
    }

    /// The whole screen, not the window: the Dock and the menu bar are part of
    /// what a Mac sweep is checking, and a window-scoped shot would crop out
    /// the app icon this task also fixed.
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Authenticated evidence is intentionally window-scoped.
    ///
    /// The deterministic sweep above owns the entire simulator desktop, so the
    /// menu bar and Dock are useful shell evidence there. A manual live sweep
    /// runs in the developer's real GUI session; a full-screen attachment can
    /// capture unrelated applications behind GetHog. The front app window is
    /// the complete product surface and the only privacy-safe boundary.
    private func captureLiveWindow(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "The live sweep had no GetHog window for \(name).")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for one of Warehouse's three truthful terminal compositions.
    ///
    /// SwiftUI's redaction skeleton is not a progress indicator, so the generic
    /// `settle` helper can finish while the list still contains placeholders.
    /// `WarehouseRoot` publishes a state-only identifier after the three
    /// requests resolve. It contains no project data and remains available when
    /// accessibility-sized lazy lists keep lower section headers off-screen.
    private func waitForWarehouseTerminalState(in app: XCUIApplication) -> Bool {
        let terminal = app.descendants(matching: .any)["gethog.warehouse-terminal"]
        return DemoLaunch.wait(for: terminal, timeout: 60)
    }

    private func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
