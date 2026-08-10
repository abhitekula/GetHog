import XCTest

/// Controls whose *label* contains something that carries a gesture of its own.
///
/// **The class this pins.** `.chartXSelection` inside `TileCard`'s `Button` did
/// not merely swallow the tap on the plot: one touch on it left that button
/// unable to perform its action again, anywhere in its bounds, for the life of
/// the screen. The measurement is written down in `TileCard.card`, and
/// `testDashboardTileTap` in the screenshot target is the regression test for
/// that specific site.
///
/// **Why this file exists as well.** That defect survived eight investigations
/// because it leaves no evidence at all — nothing renders, nothing logs, and
/// screenshots either side of the poisoning touch are byte-identical. The only
/// thing that separates a working control from a latched one is *performing the
/// action and observing the result*, so every other place in the app where a
/// control's label subtree carries a gesture gets a test that does exactly that.
///
/// A sweep of the app on 31 Jul found precisely two such sites — every `Button`,
/// `NavigationLink`, `Link`, `ShareLink`, `Toggle`, `Menu`, `DisclosureGroup`
/// and `Picker` label closure in `GetHog/Sources` and `GetHogWidgets`,
/// with every custom view inside them resolved transitively. One is the tile.
/// This is the other.
///
/// **The trap to avoid when extending this.** `XCUIElement.tap()` aims at the
/// element's *centre*, which is exactly where a latching gesture sits, so the
/// first tap of a probe is the one that poisons the control and every
/// measurement after it reads a corpse. That is how the scrub recogniser came to
/// be wrongly exonerated. So: one tap per launch, and the tap that matters goes
/// first.
final class NestedGestureTapTests: XCTestCase {

    /// Taxonomy → an event → one of its property rows.
    ///
    /// `TaxonomyPropertyRowView` puts `.textSelection(.enabled)` on the whole
    /// row — a selectable-text region installs recognisers of its own — and
    /// `TaxonomyEventDetailView` uses that row as a `Button`'s label. Which is
    /// the tile's shape exactly: a control whose label subtree carries a gesture.
    ///
    /// **Measured, and it holds.** iPhone 17, demo build: the row opened
    /// `$fixture_channel` on the *first* tap, at the element's centre — over the
    /// selectable text rather than beside it — frame 370×91.7pt. So selection
    /// here neither swallows the tap nor latches the button, and the claim in
    /// `TaxonomyPropertyRowView.curationAccessory` that "the row is still a
    /// `Button` and still opens" is now covered by a rendered regression test
    /// rather than assumed.
    ///
    /// Deliberately not asserted from a second tap. If this ever does start
    /// latching, the centre tap fails and the test says so, instead of passing
    /// on a fallback that touched a different part of the control.
    func testTaxonomyPropertyRowOpensOnFirstTap() {
        let app = DemoLaunch.launch(tab: "taxonomy")
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Taxonomy"]),
            "Taxonomy never came up."
        )
        DemoLaunch.settle(app)

        // `feature_used` is the fixture's largest event and this screen sorts by
        // volume, so it is the top row rather than an arbitrary one — the same
        // row `testTaxonomyEventDetail` names, for the same reason.
        let eventRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "feature_used")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: eventRow), "The feature_used row was not on screen.")
        eventRow.tap()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["feature_used"]),
            "The event detail never pushed."
        )
        DemoLaunch.settle(app)

        // `event_taxonomy.json`'s first row once the screen's own sort is
        // applied: `$fixture_channel` has the largest fictional sample count.
        let propertyRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "$fixture_channel")
        ).firstMatch
        if !DemoLaunch.wait(for: propertyRow, timeout: 10) {
            // The properties section starts below the event's own facts, so on a
            // short window or at a large type size the first row is under the
            // fold and SwiftUI has not built it.
            app.swipeUp()
            DemoLaunch.pause(0.5)
        }

        // Printed unconditionally, for the reason `testDashboardTileTap` prints
        // its probe line: "the tap did nothing" cannot distinguish a control
        // whose action never fired from one that was not in the tree, and those
        // two need entirely different fixes.
        print(
            "PROPERTY-ROW-PROBE exists=\(propertyRow.exists) "
                + "hittable=\(propertyRow.exists ? String(describing: propertyRow.isHittable) : "n/a") "
                + "frame=\(propertyRow.exists ? String(describing: propertyRow.frame) : "n/a")"
        )
        XCTAssertTrue(propertyRow.exists, "The $fixture_channel property row was not on screen.")
        guard propertyRow.exists else { return }

        propertyRow.tap()

        let deadline = Date().addingTimeInterval(12)
        var opened = false
        while Date() < deadline {
            if app.navigationBars["$fixture_channel"].exists {
                opened = true
                break
            }
            DemoLaunch.pause(0.4)
        }
        XCTAssertTrue(
            opened,
            """
            The property row did not open on a tap at its centre. The row's label \
            carries `.textSelection(.enabled)` inside the `Button`, which is the \
            shape that latched the dashboard tile — see `TileCard.card`. Check \
            whether one touch has left this button unable to fire anywhere in its \
            bounds before assuming the tap merely landed on the text.
            """
        )
    }

    // MARK: - The inverse shape: a plain `TapGesture` wrapping a real `Button`

    // Five rows in the replay screen are built the other way round from the tile:
    // `.contentShape(.rect)` plus `.onTapGesture(perform: onToggle)` around a row
    // that can also contain a real seek `Button`. The row therefore has to publish
    // its own explicit button trait and default accessibility action without
    // flattening that nested control: `TimelineRowView`, `TimelineRunRowView`,
    // `SessionChapterRow`, `ReplayConsoleRow` and `ReplayNetworkRow`.
    //
    // A sweep set these aside by argument: a `TapGesture` has no press-state
    // machine, so there is nothing for a child to latch. That argument is
    // plausible and is exactly the epistemic state that produced the eight-
    // investigation tile defect, so the four authored by the replay demo are
    // measured here instead. `TimelineRunRowView` remains a declared fixture gap:
    // `session_events.json` has no three consecutive lookalike non-custom events,
    // and this target must not manufacture a second runtime fixture path merely
    // to make a row appear. Each probe launches its own app and the tap that
    // matters is the first tap that control receives.
    //
    // The contract measured below is stronger than that argument: every reachable
    // row must export as a button and expand on its first activation; its nested
    // button must move the playhead on its first touch, and the row must still
    // toggle afterwards. The growth and seek assertions were checked for
    // sensitivity by breaking the
    // thing they measure and watching them fail: `.onTapGesture(perform: {})` on
    // `ReplayNetworkRow` fails the growth assertion at 75.0pt unchanged, and
    // `Button(action: {})` fails the playhead assertion at "0 seconds" unchanged.
    // A probe that cannot fail is the failure mode this whole file guards.
    //
    // The earlier measurement found a different defect: two measured seek
    // buttons were 16 × 16pt. See `HitTargetTests.testSessionRowSeekButtons`.
    //
    /// The replay screen, waited on until the player reports itself ready.
    ///
    /// `canSeek` on all five row types is `controller.isReady`, so the nested
    /// button does not exist at all until rrweb has booted in the web view and
    /// been fed snapshots. The scrubber is `.disabled(!controller.isReady)`, which
    /// makes `isEnabled` on it the one signal that says so directly — the stage's
    /// own label appears well before.
    private func launchReplay(file: StaticString = #filePath, line: UInt = #line)
        -> XCUIApplication {
        let app = DemoLaunch.launch(openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")
        let slider = app.sliders["Playback position"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if slider.exists && slider.isEnabled { break }
            DemoLaunch.pause(0.5)
        }
        XCTAssertTrue(
            slider.exists && slider.isEnabled,
            "The replay never reached its ready state, so no seek button was ever drawn.",
            file: file,
            line: line
        )
        DemoLaunch.settle(app)
        return app
    }

    /// Scrolls until `element` is on screen *and* its own centre hit-tests to it.
    ///
    /// `isHittable` rather than `exists`: this screen is one long `ScrollView` of
    /// plain stacks, so every row exists in the tree from the moment the data
    /// lands — the timeline's rows were measured at y = 1180…2005 in an 874pt
    /// window. `exists` is therefore true for rows that no tap can reach, and
    /// `XCUIElement.tap()` does not scroll.
    ///
    /// `.slow` velocity so a swipe carries no momentum: a flung scroll view
    /// overshoots by an unbounded amount and the loop then hunts.
    @discardableResult
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

    /// The row container around a labelled descendant.
    ///
    /// `TimelineRowView` publishes the row itself as an unlabelled `.contain`
    /// container whose *child* carries the combined label, so the row cannot be
    /// addressed by label directly. Every ancestor of that child matches
    /// `containing`, and the row is the shortest of them — which is a more honest
    /// way to pick it than trusting the order the query returns.
    private func rowContainer(
        around descendantLabelPrefix: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        app.otherElements
            .containing(NSPredicate(format: "label BEGINSWITH %@", descendantLabelPrefix))
            .allElementsBoundByIndex
            .min { $0.frame.height < $1.frame.height }
    }

    /// Polls a row's height until it grows, which is what expanding does.
    ///
    /// Height rather than "some new text appeared": every one of these rows
    /// reveals different content — properties, a narrative, a URL — and a test
    /// that pins the fixture's text measures the fixture. A row that did not
    /// toggle does not move at all.
    @discardableResult
    private func waitForGrowth(
        of element: XCUIElement,
        beyond baseline: CGFloat,
        timeout: TimeInterval = 8
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var height = baseline
        while Date() < deadline {
            height = element.frame.height
            if height > baseline + 8 { return height }
            DemoLaunch.pause(0.3)
        }
        return height
    }

    /// Polls the scrubber's spoken position until it moves off where it started.
    ///
    /// The player is created with `autoPlay: false`, so a session that nobody has
    /// touched sits at "0 seconds" indefinitely and any movement is the seek.
    private func waitForPlayhead(
        _ slider: XCUIElement,
        toLeave start: String,
        timeout: TimeInterval = 10
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var value = start
        while Date() < deadline {
            value = slider.value as? String ?? ""
            if value != start { return value }
            DemoLaunch.pause(0.3)
        }
        return value
    }

    // MARK: Session timeline

    /// `TimelineRowView` — the row's own toggle, on the first tap it ever gets.
    ///
    /// The `harbor_report_downloaded` row is a named fictional custom event,
    /// which makes it addressable without an index.
    func testTimelineRowExpandsOnFirstTap() {
        let app = launchReplay()
        let row = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "harbor_report_downloaded,"))
            .firstMatch
        XCTAssertTrue(reveal(row, in: app), "The harbor report timeline row never came into reach.")
        guard let container = rowContainer(around: "harbor_report_downloaded,", in: app) else {
            return XCTFail("No container was found around the harbor report row.")
        }
        let before = container.frame.height
        print("TIMELINE-ROW-PROBE row=\(row.frame) container=\(container.frame)")

        row.tap()

        let after = waitForGrowth(of: container, beyond: before)
        XCTAssertGreaterThan(
            after, before + 8,
            """
            Tapping the timeline row at its centre did not expand it: the row is \
            \(before)pt tall before the tap and \(after)pt after. The row's toggle \
            is a bare `.onTapGesture` on a `.contentShape(.rect)` that contains a \
            seek `Button` — check whether the nested control has taken the touch \
            before assuming the tap missed.
            """
        )
    }

    /// `TimelineRowView` — the nested seek `Button`, on the first tap it ever gets.
    ///
    /// Deliberately not asserted from a second tap: the whole reason this file
    /// exists is that a control which latches on its first touch looks perfectly
    /// healthy to any probe that taps twice.
    func testTimelineSeekButtonFiresOnFirstTap() {
        let app = launchReplay()
        let slider = app.sliders["Playback position"]
        let start = slider.value as? String ?? ""

        let seek = app.buttons["Play the replay from 7 seconds"]
        XCTAssertTrue(reveal(seek, in: app), "The timeline row's seek button never came into reach.")
        print("TIMELINE-SEEK-PROBE frame=\(seek.frame) start=\(start)")

        seek.tap()

        let moved = waitForPlayhead(slider, toLeave: start)
        XCTAssertNotEqual(
            moved, start,
            """
            The timeline row's seek button did not move the playhead on a tap at \
            its centre; the scrubber still reads "\(start)". The button sits \
            inside a row whose whole area carries an `.onTapGesture`, so check \
            whether the row's gesture took the touch.
            """
        )

        // A *second* tap, and it is measuring the opposite thing: whether the
        // touch above left the row's own gesture dead. That is the tile's failure
        // mode, and it is only visible after the control has been used once.
        guard let container = rowContainer(around: "harbor_report_downloaded,", in: app) else { return }
        let before = container.frame.height
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "harbor_report_downloaded,"))
            .firstMatch.tap()
        let after = waitForGrowth(of: container, beyond: before)
        XCTAssertGreaterThan(
            after, before + 8,
            "The timeline row stopped toggling after its seek button had been used once."
        )
    }

    // MARK: Session summary chapters

    /// `SessionChapterRow` — the row's own toggle, first tap.
    func testSummaryChapterRowExpandsOnFirstTap() {
        let app = launchReplay()
        let row = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter 1,"))
            .firstMatch
        XCTAssertTrue(reveal(row, in: app), "Chapter 1 never came into reach.")
        let before = row.frame.height
        print("CHAPTER-ROW-PROBE button=\(row.frame)")

        row.tap()

        let after = waitForGrowth(of: row, beyond: before)
        XCTAssertGreaterThan(
            after, before + 8,
            """
            Tapping chapter 1 at its centre did not expand it: \(before)pt before \
            the tap, \(after)pt after. The labelled element is the row's exported \
            button, so this measures its default toggle action directly.
            """
        )
    }

    /// `SessionChapterRow` — the nested seek `Button`, first tap.
    func testSummaryChapterSeekButtonFiresOnFirstTap() {
        let app = launchReplay()
        let slider = app.sliders["Playback position"]
        let start = slider.value as? String ?? ""

        let chapterRows = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Chapter 1,")
        )
        XCTAssertEqual(chapterRows.count, 1, "Chapter 1 should expose one semantic row button.")
        let chapterRow = chapterRows.firstMatch
        let chapterSeekButtons = chapterRow.descendants(matching: .button).matching(
            NSPredicate(format: "label == %@", "Play the replay from 1 second")
        )
        XCTAssertEqual(
            chapterSeekButtons.count,
            1,
            "Chapter 1 should contain one seek button at its own offset."
        )
        let seek = chapterSeekButtons.firstMatch
        XCTAssertTrue(reveal(seek, in: app), "Chapter 1's seek button never came into reach.")
        print("CHAPTER-SEEK-PROBE frame=\(seek.frame) start=\(start)")

        seek.tap()

        let moved = waitForPlayhead(slider, toLeave: start)
        XCTAssertNotEqual(
            moved, start,
            """
            Chapter 1's seek button did not move the playhead on a tap at its \
            centre; the scrubber still reads "\(start)".
            """
        )

        let before = chapterRow.frame.height
        chapterRow.tap()
        let after = waitForGrowth(of: chapterRow, beyond: before)
        XCTAssertGreaterThan(
            after, before + 8,
            "The chapter row stopped toggling after its seek button had been used once."
        )
    }

    // MARK: Replay console pane

    /// `ReplayConsoleRow` — exported as a button and expanded by its own action.
    ///
    /// The prefix comes from the authored rrweb console event rather than from
    /// an index: one log at +1s whose first argument is "Dashboard widgets
    /// loaded". The second argument is deliberately left out of the selector so
    /// the test measures the row contract rather than JSON rendering details.
    func testConsoleRowExpandsOnFirstTap() {
        let app = launchReplay()
        let row = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Log. at 1 second. Dashboard widgets loaded"
            )
        ).firstMatch
        XCTAssertTrue(reveal(row, in: app), "The authored console row never came into reach as a button.")
        let before = row.frame.height
        print("CONSOLE-ROW-PROBE button=\(row.frame)")

        row.tap()

        let after = waitForGrowth(of: row, beyond: before)
        XCTAssertGreaterThan(
            after, before + 8,
            """
            Activating the console row did not expand it: \(before)pt before the \
            activation and \(after)pt after. Check both the exported button \
            semantics and the row's default toggle action.
            """
        )
    }

    // MARK: Replay network pane

    /// `ReplayNetworkRow` — the row's own toggle, first tap.
    ///
    /// The `/api/widgets` row is reached through the pane's own Fetch & XHR filter,
    /// which is a `Button` in the chip strip and not part of the row under test.
    /// It is the fixture's only request and is not `isInitial`, so its seek target
    /// is observable from a player waiting at 0.
    func testNetworkRowExpandsOnFirstTap() {
        let app = launchReplay()
        let chip = app.buttons["Fetch & XHR, 1 requests"]
        XCTAssertTrue(reveal(chip, in: app), "The network pane's filter strip never came into reach.")
        chip.tap()
        DemoLaunch.pause(0.8)

        let row = app.buttons["GET, /api/widgets, status 200, at 1 second, took 120 ms"]
        XCTAssertTrue(reveal(row, in: app), "The /api/widgets network row never came into reach as a button.")
        let before = row.frame.height
        print("NETWORK-ROW-PROBE container=\(row.frame)")

        row.tap()

        let after = waitForGrowth(of: row, beyond: before)
        XCTAssertGreaterThan(
            after, before + 8,
            """
            Tapping the /api/widgets network row at its centre did not expand it: \
            \(before)pt before the tap, \(after)pt after.
            """
        )
    }

    /// `ReplayNetworkRow` — the nested seek `Button`, first tap.
    func testNetworkSeekButtonFiresOnFirstTap() {
        let app = launchReplay()
        let slider = app.sliders["Playback position"]
        let start = slider.value as? String ?? ""

        let chip = app.buttons["Fetch & XHR, 1 requests"]
        XCTAssertTrue(reveal(chip, in: app), "The network pane's filter strip never came into reach.")
        chip.tap()
        DemoLaunch.pause(0.8)

        let row = app.buttons["GET, /api/widgets, status 200, at 1 second, took 120 ms"]
        let seek = row.descendants(matching: .button)["Play the replay from 1 second"]
        XCTAssertTrue(reveal(seek, in: app), "The /api/widgets row's seek button never came into reach.")
        print("NETWORK-SEEK-PROBE frame=\(seek.frame) start=\(start)")

        seek.tap()

        let moved = waitForPlayhead(slider, toLeave: start)
        XCTAssertNotEqual(
            moved, start,
            """
            The /api/widgets row's seek button did not move the playhead on a tap at \
            its centre; the scrubber still reads "\(start)".
            """
        )

        let before = row.frame.height
        row.tap()
        let after = waitForGrowth(of: row, beyond: before)
        XCTAssertGreaterThan(
            after, before + 8,
            "The network row stopped toggling after its seek button had been used once."
        )
    }
}
