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
        /// A string only this screen's fixture can produce, or `nil` where the
        /// demo dataset has no pinned content to name. A `nil` anchor is not a
        /// weaker test by accident: it is recorded as screenshot-only, and the
        /// screenshot is what says whether the screen is populated, empty and
        /// honest, or stuck.
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
        Screen(3, "Events"),
        Screen(4, "Sessions", anchor: "Alex Example"),
        Screen(5, "Insights", anchor: "Example meteor report"),
        Screen(6, "Web", anchor: "sample visitors"),
        Screen(7, "Clickmap", anchor: "Example App metric 1831"),
        Screen(8, "People", anchor: "Sable Okafor"),
        Screen(9, "Groups"),
        Screen(10, "SQL"),
    ]

    private static let monitor: [Screen] = [
        Screen(11, "Errors", anchor: "HarborRenderFault"),
        Screen(12, "Summaries"),
        Screen(13, "LLM"),
        Screen(14, "Tracing"),
        Screen(15, "Logs"),
        Screen(16, "Support"),
        Screen(17, "Inbox"),
        Screen(18, "Signals"),
        Screen(19, "Health"),
        Screen(20, "Ingestion"),
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

    /// The flows a list row opens, which is where an iOS-ism survives longest:
    /// a detail that was a sheet on the phone has to fill the Mac's detail
    /// column, and a screenshot is the only thing that says whether it does.
    func testDetailFlowsRender() {
        let app = DemoLaunch.launch()

        for (title, rowText, name) in Self.detailFlows {
            open(title, in: app)
            let row = element(containing: rowText, in: app)
            guard DemoLaunch.wait(for: row) else {
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
        let row = element(containing: "Example App metric 33", in: app)
        guard DemoLaunch.wait(for: row) else {
            XCTFail("The dashboard list never offered its first row.")
            return
        }
        row.click()

        let tile = element(containing: DemoLaunch.firstTileTitle, in: app)
        guard DemoLaunch.wait(for: tile) else {
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
                XCTAssertTrue(
                    DemoLaunch.wait(for: element(containing: anchor, in: app)),
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
                open(screen.title, in: app)
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
        let sidebar = app.outlines.firstMatch
        if sidebar.exists {
            let scoped = sidebar.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", title))
                .firstMatch
            if scoped.exists { return scoped }
        }
        return app.windows.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    /// Clicks a sidebar destination, scrolling the sidebar to it first if it is
    /// below the fold — thirty-four rows do not fit 820pt, and the rows at the
    /// bottom of Workspace are exactly the ones nobody has looked at.
    private func open(_ title: String, in app: XCUIApplication) {
        var item = sidebarItem(title, in: app)
        guard DemoLaunch.wait(for: item) else {
            XCTFail("No sidebar destination labelled \(title).")
            return
        }

        // Existence is not reachability in a scrolling outline.
        var scrolls = 0
        while !item.isHittable && scrolls < 8 {
            app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: -80)
            item = sidebarItem(title, in: app)
            scrolls += 1
        }

        item.click()
        DemoLaunch.settle(app)
    }

    /// Every element whose label contains the text, of any type — list rows
    /// fold their fields into one label, so an exact match cannot find a row.
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
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

    private func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
