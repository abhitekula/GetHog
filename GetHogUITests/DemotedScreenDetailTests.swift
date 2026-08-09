import XCTest

/// Whether a screen demoted out of the tab bar keeps its open detail across the
/// size-class boundary.
///
/// **The prediction under test.** A tab that is loose at both widths is hosted
/// once, so nothing rebuilds under it — which is why Dashboards, Events,
/// Sessions and Flags have never adopted `OpenDetails` and hold their selection
/// in plain `@State`. Demote one and it is hosted twice: a sidebar `Tab` above
/// the size-class boundary, a push on the search tab's stack below it. That is
/// exactly the arrangement `OpenDetails` exists for, and the seven secondary
/// split views already adopt it.
///
/// **This must run on a Max-size iPhone, and that is the whole design of the
/// test.** `RootView.looseTabs` is `AppTab.primary` on iPad and the user's four
/// only on iPhone, so *nothing is ever demoted on an iPad* — the first version
/// of this test ran there and could not have measured the defect it was written
/// for. A Max-size iPhone is the one device that both honours the preference and
/// crosses the size-class boundary, which it does by rotating: 440 × 956pt
/// portrait is compact, landscape is regular.
///
/// **Four crossings, not three.** A three-stage check has passed here for a
/// mechanism that then failed on the fourth — recorded in `RootView`'s note on
/// `presentedDetail`.
///
/// **The detail is identified by the flag's own name.** The first version keyed
/// on a navigation bar identifier and picked up
/// `_TtGC7SwiftUI32NavigationStackHosting`, SwiftUI's generic host container,
/// which is present whatever happens — so it passed all four crossings without
/// ever looking at the flag. A probe that cannot fail proves nothing.
final class DemotedScreenDetailTests: XCTestCase {

    /// The control the demoted measurement is read against: the identical tap,
    /// on the identical row, with Flags left in the tab bar where it has always
    /// been. Without it, a tap that opens nothing is indistinguishable from a
    /// selector that misses.
    func testFlagsInTheBarOpensItsDetail() {
        let app = DemoLaunch.launch(
            tab: "flags",
            environment: ["GETHOG_TAB_BAR": "dashboards,events,sessions,flags"]
        )
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Flags"]))
        DemoLaunch.settle(app)

        let row = app.cells.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.flagKey))
            .firstMatch
        guard DemoLaunch.wait(for: row, timeout: 15) else {
            XCTFail("Flags never listed \"\(Self.flagKey)\".")
            return
        }
        print("CONTROL row=\(row.frame) hittable=\(row.isHittable)")
        row.tap()
        DemoLaunch.wait { app.navigationBars[Self.flagKey].exists }
        print("CONTROL barsAfterTap=\(app.navigationBars.allElementsBoundByIndex.map { $0.identifier })")

        XCTAssertTrue(
            app.navigationBars[Self.flagKey].exists,
            "Even in the tab bar, tapping this row opens no detail — so the selector is wrong, not the demotion."
        )
    }

    /// The first row of `feature_flags.json`'s list as the screen sorts it.
    private static let flagKey = "example-chart-density"

    /// The other three split views that can now be demoted.
    ///
    /// Each was a loose tab for the life of the app and so had never been
    /// pushed onto anyone else's stack. They share Flags' structure exactly — a
    /// `NavigationSplitView` at both widths over a `List(selection:)` — so they
    /// share its defect, and this is what says so rather than an argument from
    /// resemblance.
    func testDemotedDashboardsOpensItsDetail() {
        assertDemotedScreenOpensADetail(tab: "dashboards", titled: "Dashboards")
    }

    func testDemotedSessionsOpensItsDetail() {
        assertDemotedScreenOpensADetail(tab: "sessions", titled: "Sessions")
    }

    func testDemotedEventsOpensItsDetail() {
        assertDemotedScreenOpensADetail(tab: "events", titled: "Events")
    }

    /// An event selected in compact width becomes the split-view detail in
    /// regular width, then must become the same pushed detail when the window
    /// narrows again. The Stage Manager live pass caught a destination that
    /// retained its Back button while its body became an empty view.
    func testEventDetailSurvivesCompactRegularCompactTransition() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard
            deviceName.localizedCaseInsensitiveContains("iPhone"),
            deviceName.localizedCaseInsensitiveContains("Max")
        else {
            throw XCTSkip("This regression requires a Max-size iPhone that becomes regular in landscape.")
        }

        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

        let app = DemoLaunch.launch(tab: "events")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Events"]))
        XCTAssertTrue(app.tabBars.firstMatch.exists, "The Max-size iPhone did not start in compact width.")

        let eventName = "meteor_report_opened"
        let row = app.cells.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", eventName))
            .firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: row), "The deterministic first event never rendered.")
        row.tap()

        let detail = app.navigationBars[eventName]
        let copy = app.buttons["Copy as JSON"]
        XCTAssertTrue(DemoLaunch.wait(for: detail), "The event detail never opened.")
        XCTAssertTrue(DemoLaunch.wait(for: copy), "The event detail opened without its content.")

        let portraitWidth = app.windows.firstMatch.frame.width
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            DemoLaunch.wait { app.windows.firstMatch.frame.width != portraitWidth },
            "The event-detail transition into regular width never completed."
        )
        DemoLaunch.settle(app)
        DemoLaunch.pause(1)

        XCTAssertTrue(
            row.exists && row.isHittable && detail.exists && copy.exists && copy.isHittable,
            "Regular width did not render the original Events row and its selected detail together."
        )

        let landscapeWidth = app.windows.firstMatch.frame.width
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            DemoLaunch.wait { app.windows.firstMatch.frame.width != landscapeWidth },
            "The event-detail transition back into compact width never completed."
        )
        DemoLaunch.settle(app)
        DemoLaunch.pause(1)

        XCTAssertTrue(detail.exists, "The selected event was lost when the window narrowed again.")
        XCTAssertTrue(
            copy.exists && copy.isHittable,
            "The narrowed event destination kept navigation chrome but rendered a blank body."
        )
    }

    /// Opens the first row of a demoted screen and requires *something* to have
    /// opened over the list.
    ///
    /// Deliberately weaker than the Flags measurement above: it does not name
    /// the detail, because these three open dashboards, recordings and events
    /// whose titles come from fixtures this file should not have to track. What
    /// it pins is the fact that broke — a demoted split view opening nothing at
    /// all.
    ///
    /// **It does not count navigation bars, and the first version did.** A push
    /// *replaces* the visible bar rather than stacking a second one, so all
    /// three went from two bars to one at the very moment they started working:
    /// `["…NavigationStackHosting", "Dashboards"]` became `["My App
    /// Dashboard"]`. Counting called that a regression. What is asserted instead
    /// is that some bar now carries a name of its own — neither the screen's
    /// title nor SwiftUI's `_Tt`-prefixed host container, which is what a list
    /// that opened nothing leaves behind.
    private func assertDemotedScreenOpensADetail(
        tab: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // A bar of four screens that are none of the three under test.
        let app = DemoLaunch.launch(
            tab: tab,
            environment: ["GETHOG_TAB_BAR": "logs,errorTracking,inbox,health"]
        )
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars[title]), file: file, line: line)
        DemoLaunch.settle(app)

        guard app.tabBars.firstMatch.exists else {
            print("DEMOTED-OPEN \(tab) skipped: regular width demotes nothing.")
            return
        }

        let before = app.navigationBars.count
        let row = app.cells.buttons.allElementsBoundByIndex.first {
            $0.isHittable && !$0.label.localizedCaseInsensitiveContains("dismiss")
        }
        guard let row else {
            XCTFail("\(title) listed no tappable row, so nothing was measured.", file: file, line: line)
            return
        }
        print("DEMOTED-OPEN \(tab) row=\(row.label.prefix(40)) barsBefore=\(before)")
        row.tap()
        // Something opened when a bar carries a name that is neither the
        // screen's nor SwiftUI's host container - the same condition asserted
        // below, so this waits for exactly what it is about to measure.
        DemoLaunch.wait {
            app.navigationBars.allElementsBoundByIndex.contains { bar in
                let name = bar.identifier
                return !name.isEmpty && name != title && !name.hasPrefix("_Tt")
            }
        }

        let after = app.navigationBars.allElementsBoundByIndex.map { $0.identifier }
        print("DEMOTED-OPEN \(tab) barsAfter=\(after)")
        let opened = after.contains { name in
            !name.isEmpty && name != title && !name.hasPrefix("_Tt")
        }
        XCTAssertTrue(
            opened,
            """
            Tapping the first row of a demoted \(title) opened nothing — bars \
            went from \(before) to \(after), none of them a detail's own name. A \
            `NavigationSplitView` pushed onto the search tab's stack has nowhere \
            to put its detail; the fix is the arrangement `FlagsRoot` now uses.
            """,
            file: file,
            line: line
        )
    }

    func testDemotedFlagsKeepsItsOpenDetail() {
        // Flags is demoted; the bar is four screens that are not it.
        let app = DemoLaunch.launch(
            tab: "flags",
            environment: ["GETHOG_TAB_BAR": "dashboards,events,sessions,logs"]
        )
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Flags"]))
        DemoLaunch.settle(app)

        let window = app.windows.firstMatch.frame
        // Compact now, and able to become regular. A device that is already
        // regular is an iPad, where nothing is demoted in the first place.
        guard app.tabBars.firstMatch.exists else {
            print("DEMOTED-DETAIL skipped: \(window) is regular width, so nothing here is demoted.")
            return
        }

        // Named, not "the first row". `app.cells.buttons.firstMatch` picked up
        // TipKit's **Dismiss tip** button, which is inside a cell on this screen
        // — the same trap `AccessibilityAuditTests` records from the AX5
        // screenshot run, where "the topmost full-width labelled button" was a
        // filter control rather than a row. This key is the first row of
        // `feature_flags.json`.
        let row = app.cells.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.flagKey))
            .firstMatch
        guard DemoLaunch.wait(for: row, timeout: 15) else {
            XCTFail("Flags never listed \"\(Self.flagKey)\", so nothing was measured.")
            return
        }
        row.tap()
        let detail = app.navigationBars[Self.flagKey]
        DemoLaunch.wait { detail.exists }
        print("DEMOTED-DETAIL window=\(window) flag=\(Self.flagKey) detailBarExists=\(detail.exists)")
        print("DEMOTED-DETAIL barsAfterTap=\(app.navigationBars.allElementsBoundByIndex.map { $0.identifier })")
        print("DEMOTED-DETAIL switchesAfterTap=\(app.switches.allElementsBoundByIndex.map { $0.label }.prefix(6))")
        print("DEMOTED-DETAIL textsAfterTap=\(app.staticTexts.allElementsBoundByIndex.map { $0.label }.prefix(14))")
        guard detail.exists else {
            XCTFail("Tapping \"\(Self.flagKey)\" opened no detail, so the crossings would measure nothing.")
            return
        }

        for stage in 1...4 {
            let widthBefore = app.windows.firstMatch.frame.width
            XCUIDevice.shared.orientation = stage.isMultiple(of: 2) ? .portrait : .landscapeLeft
            // Wait for the resize to actually land rather than for a fixed
            // interval, then settle, then read *late* on purpose.
            //
            // The late read is not padding and must not be optimised away: the
            // arrangement this test guards once looked correct the instant a
            // drag ended and was wrong a second later, which is the whole reason
            // the check is four crossings rather than one.
            DemoLaunch.wait { app.windows.firstMatch.frame.width != widthBefore }
            DemoLaunch.settle(app)
            DemoLaunch.pause(1.0)
            let bars = app.navigationBars.allElementsBoundByIndex.map { $0.identifier }
            print(
                "DEMOTED-DETAIL stage=\(stage) width=\(app.windows.firstMatch.frame.width) "
                    + "detailStillOpen=\(detail.exists) bars=\(bars)"
            )
            XCTAssertTrue(
                detail.exists,
                """
                Crossing \(stage): the open flag "\(Self.flagKey)" is gone and the bars \
                are \(bars). A demoted primary screen is hosted twice and must \
                adopt `OpenDetails`, the way the seven secondary split views \
                already do.
                """
            )
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
