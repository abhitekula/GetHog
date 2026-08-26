import XCTest

/// The 44×44pt floor, on the controls that were measured below it.
///
/// `View.minimumHitTarget()` in `PlatformAffordances.swift` is what raises them.
/// Where the modifier goes is the part that can be wrong without looking wrong,
/// and two agents found the same trap independently: on a **borderless** `Menu`
/// or `Button` the tap region and the accessibility frame are the *label's*
/// bounds and nothing else, so a modifier applied outside the label closure just
/// recentres the label in a roomier box and moves nothing. A bordered control
/// (`.toggleStyle(.button)`) is the opposite — it draws its background into
/// whatever size it is offered, so the modifier belongs on the control.
///
/// Asserting the rendered frame is exactly what separates the two. A test that
/// only checked the modifier was present would pass on the phantom fix.
final class HitTargetTests: XCTestCase {

    /// Was 19.0×21.0 (back) and 20×22 (forward): under `.plain` the glyph *is*
    /// the button, and play was the only control in the row that already carried
    /// a frame — so its two neighbours, the ones you reach for while something is
    /// playing, were the short ones.
    func testReplayTransportSkipButtons() {
        let app = DemoLaunch.launch(openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")

        let back = app.buttons["Back 10 seconds"]
        XCTAssertTrue(
            DemoLaunch.wait(for: back, timeout: 120),
            "The replay never reached its playing state, so the transport bar was never drawn."
        )
        back.assertMeetsMinimumHitTarget("Replay transport 'Back 10 seconds'")
        app.buttons["Forward 10 seconds"]
            .assertMeetsMinimumHitTarget("Replay transport 'Forward 10 seconds'")
    }

    /// Was **16.0 × 16.0pt**, on both rows, measured through XCUITest while
    /// probing something else entirely.
    ///
    /// Replay Vision citations and timeline rows both use compact labels, but
    /// their tappable frames still owe the same 44-point floor.
    ///
    /// Undersized *inside a toggle* is the bad case: the 28pt of row around the
    /// glyph is not dead space, so a near miss expands the row instead of doing
    /// nothing, and the seek reads as having been ignored rather than as having
    /// been missed.
    ///
    /// Not caught by `AccessibilityAuditTests`: its `hitRegion` sweep runs on the
    /// root screens, and neither of these rows is on one.
    func testSessionRowSeekButtons() {
        let app = DemoLaunch.launch(openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")

        // `canSeek` on both rows is the player's `isReady`, so neither button is
        // built until rrweb has booted and been fed snapshots. The scrubber is
        // `.disabled(!controller.isReady)` and is the only element that says so.
        let scrubber = app.sliders["Playback position"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if scrubber.exists && scrubber.isEnabled { break }
            DemoLaunch.pause(0.5)
        }
        XCTAssertTrue(
            scrubber.exists && scrubber.isEnabled,
            "The replay never reached its ready state, so no seek button was ever drawn."
        )
        DemoLaunch.settle(app)

        // Both are below the fold on a phone, and this screen is one long
        // `ScrollView` of plain stacks — so every row *exists* from the moment
        // the data lands, including rows no finger can reach. The frame of an
        // off-screen row is still its laid-out size, so this would measure
        // correctly without scrolling; it scrolls anyway, because a hit-target
        // assertion about something that cannot be hit is worth nothing.
        let citation = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Play summary citation 1 at")
        ).firstMatch
        XCTAssertTrue(reveal(citation, in: app), "The first summary citation never came into reach.")
        citation.assertMeetsMinimumHitTarget("Session summary citation seek button")

        let event = app.buttons["Play the replay from 7 seconds"]
        XCTAssertTrue(reveal(event, in: app), "The timeline row's seek button never came into reach.")
        event.assertMeetsMinimumHitTarget("Session timeline row seek button")
    }

    /// The replay's three compact filter strips each draw four caption-sized
    /// glass chips. The glass is intentionally compact; the tappable and
    /// accessibility frames still owe the same 44pt floor as every other
    /// button. Querying the rendered frames catches the borderless-button trap
    /// where a roomy modifier outside the label changes layout but not the hit
    /// region.
    func testReplayFilterChips() {
        let app = DemoLaunch.launch(openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")
        let chipPredicate = NSPredicate(
            format: "label MATCHES %@",
            "^(All|Errors|Warnings|Logs|Failed|Fetch & XHR|Documents|Pageviews|Custom), [0-9]+ (entries|requests|events)$"
        )
        let chips = app.buttons.matching(chipPredicate)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, chips.count < 12 {
            DemoLaunch.pause(0.5)
        }

        XCTAssertEqual(
            chips.count, 12,
            "The replay should expose four console, four network and four timeline filter chips."
        )
        for chip in chips.allElementsBoundByIndex {
            chip.assertMeetsMinimumHitTarget("Replay filter chip '\(chip.label)'")
        }
    }

    /// Was 84.3×14.3pt — wide enough, and a third of the height a fingertip
    /// needs. `.footnote` set the line height and the button chrome added almost
    /// nothing to it.
    func testLogsErrorsOnlyToggle() {
        assertErrorsOnlyToggle(onTab: "logs")
    }

    /// Was 114×29.7pt. The same control as Logs' with a different measurement,
    /// which is why both are pinned rather than one standing in for the other.
    func testTracingErrorsOnlyToggle() {
        assertErrorsOnlyToggle(onTab: "tracing")
    }

    /// Was 41×17pt / 42.7×18pt — a subheadline glyph and one short word, with
    /// nothing behind them. This is the borderless `Menu` case: the floor has to
    /// be set inside the label closure, and this assertion is what proves it was.
    func testIngestionCategoryFilter() {
        let app = DemoLaunch.launch(tab: "ingestion")
        DemoLaunch.settle(app)

        let filter = DemoLaunch.elements(
            labelled: "Category filter, all categories",
            in: app
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: filter),
            "Ingestion's category filter was not on screen."
        )
        filter.assertMeetsMinimumHitTarget("Ingestion category filter")
    }

    /// Logs and Tracing carry the identical control, so they share the probe.
    ///
    /// Queried by label across every element type rather than as `.button`: the
    /// element type a `Toggle(…).toggleStyle(.button)` reports is a SwiftUI
    /// implementation detail, and the defect is about its size either way.
    private func assertErrorsOnlyToggle(
        onTab tab: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = DemoLaunch.launch(tab: tab, file: file, line: line)
        DemoLaunch.settle(app)

        let toggle = DemoLaunch.elements(labelled: "Errors only", in: app).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: toggle),
            "The '\(tab)' screen's 'Errors only' filter was not on screen.",
            file: file,
            line: line
        )
        toggle.assertMeetsMinimumHitTarget("'\(tab)' Errors only toggle", file: file, line: line)
    }

    /// Scrolls until `element` is on screen *and* its own centre hit-tests to it.
    ///
    /// `.slow` velocity so a swipe carries no momentum: a flung scroll view
    /// overshoots by an unbounded amount and the loop then hunts. The second pass
    /// goes back up for the case where one swipe stepped over a short row.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<26 {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.3)
        }
        for _ in 0..<26 {
            if element.exists && element.isHittable { return true }
            app.swipeDown(velocity: .slow)
            DemoLaunch.pause(0.3)
        }
        return element.exists && element.isHittable
    }
}
