import XCTest

/// The replay transport keys, driven through a real window server.
///
/// `MacReplayKeyboardTests` pins the mapping as arithmetic; this is the half
/// only a rendered player can answer — whether the key equivalents are actually
/// installed, whether they move the transport the on-screen buttons move, and
/// whether a query typed into the sessions search field reaches the field
/// instead of the player.
///
/// Every assertion reads the transport's *own* controls: the play button's
/// symbol, the playback slider's value, the speed menu's value. Those are the
/// same three things a person looks at, and none of them is a private hook
/// added for the test.
final class MacReplayTransportTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The player

    private func playButton(in app: XCUIApplication) -> XCUIElement {
        app.windows.buttons.matching(
            NSPredicate(format: "label == 'Play' OR label == 'Pause'")
        ).firstMatch
    }

    private func slider(in app: XCUIApplication) -> XCUIElement {
        app.windows.sliders["Playback position"]
    }

    private func speed(in app: XCUIApplication) -> XCUIElement {
        app.windows.descendants(matching: .menuButton)
            .matching(NSPredicate(format: "label == 'Playback speed'"))
            .firstMatch
    }

    private func position(in app: XCUIApplication) -> Double {
        Double("\(slider(in: app).value ?? "")") ?? -1
    }

    /// The solo replay window (`GETHOG_SOLO_RECORDING`): one screen, no shell.
    ///
    /// Launched here rather than through `DemoLaunch.launch`, whose macOS gate
    /// waits for a *sidebar row* — a screen this window deliberately does not
    /// have, so the shared gate times out and relaunches before failing.
    ///
    /// This window is also the shortest route to the state-restoration race
    /// `DetachedRecordingView` used to lose: it mounts before `bootstrap()` has
    /// a client, which is what a window restored at launch does too.
    @discardableResult
    private func launchSolo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-GetHogDemo"]
        app.launchEnvironment["GETHOG_SOLO_RECORDING"] = DemoLaunch.replaySessionID
        app.launch()
        _ = DemoLaunch.wait(for: app.windows.buttons["Session replay"], timeout: 30)
        DemoLaunch.settle(app)
        DemoLaunch.pause(3)
        return app
    }

    // MARK: - Tests

    /// The solo window renders the player, and the stage's surround is drawn.
    func testSoloRecordingWindowRendersItsStage() {
        let app = launchSolo()
        let stage = app.windows.buttons["Session replay"]
        XCTAssertTrue(stage.exists, "The solo recording window rendered no replay stage.")
        print("PHASEB-SOLO stage=\(stage.frame) window=\(app.windows.firstMatch.frame)")
        capture("b1-solo-recording-stage")
        XCTAssertEqual(app.state, .runningForeground, "The solo recording window took the app down.")
    }

    /// The shell's own session detail, which is where a person meets the
    /// player.
    ///
    /// `Alex Example`, and the choice is measured rather than incidental:
    /// `DemoTransport` answers *every* recording id with the first row of
    /// `session_recordings.json`, so only that row's player reaches a ready
    /// state. Opening `Morgan Example` — chosen originally because its 34:35
    /// makes ⇧→'s 30-second jump legible where Alex's 0:10 clamps it — leaves a
    /// player whose own play button does not toggle and whose slider sits at a
    /// constant. The step *ladder* is pinned as arithmetic by
    /// `MacReplayKeyboardTests`; what this suite can honestly show is that each
    /// key reaches the transport at all.
    private func openSessionDetail(_ person: String = "Alex Example") -> XCUIApplication {
        let app = DemoLaunch.launch()
        app.typeKey("3", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let row = DemoLaunch.waitForContent(containing: person, in: app) else {
            XCTFail("The sessions list never offered \(person).")
            return app
        }
        row.click()
        DemoLaunch.settle(app)
        _ = DemoLaunch.wait(for: app.windows.buttons["Session replay"], timeout: 30)
        DemoLaunch.pause(2)
        return app
    }

    /// Space, ←/→, ⇧←/⇧→ and `[` / `]`, each read off the control it drives.
    func testKeyboardTransportDrivesThePlayer() {
        let app = openSessionDetail()
        guard app.windows.buttons["Session replay"].exists else {
            XCTFail("No replay stage to drive.")
            return
        }

        // Seek. The slider reports seconds, so a ±10s step is unambiguous.
        app.typeKey(.rightArrow, modifierFlags: [])
        DemoLaunch.pause(1.2)
        let forward = position(in: app)
        print("PHASEB-SEEK right=\(forward)")
        XCTAssertGreaterThan(forward, 0, "→ did not move the playhead.")
        capture("b3-seek-forward")

        app.typeKey(.leftArrow, modifierFlags: [])
        DemoLaunch.pause(1.2)
        let back = position(in: app)
        print("PHASEB-SEEK left=\(back)")
        XCTAssertLessThan(back, forward, "← did not move the playhead back.")

        // ⇧→ is three steps rather than one. On the only playable demo
        // recording — 0:10 — both land on the same upper bound, so what is
        // assertable here is that the shifted key reaches the transport and
        // lands legally, not that it travelled further. The 10-versus-30
        // arithmetic is `MacReplayKeyboardTests`' to pin.
        app.typeKey(.rightArrow, modifierFlags: .shift)
        DemoLaunch.pause(1.2)
        let bigForward = position(in: app)
        print("PHASEB-SEEK shift-right=\(bigForward) (plain right was \(forward))")
        XCTAssertGreaterThanOrEqual(bigForward, forward, "⇧→ moved the playhead backwards.")

        // Speed: `]` steps up the ladder, `[` steps back down.
        let restingSpeed = "\(speed(in: app).value ?? "")"
        app.typeKey("]", modifierFlags: [])
        DemoLaunch.pause(1.2)
        let faster = "\(speed(in: app).value ?? "")"
        print("PHASEB-SPEED \(restingSpeed) -> ] -> \(faster)")
        XCTAssertNotEqual(faster, restingSpeed, "] did not change the playback speed.")
        capture("b4-speed-up")

        app.typeKey("[", modifierFlags: [])
        DemoLaunch.pause(1.2)
        let slower = "\(speed(in: app).value ?? "")"
        print("PHASEB-SPEED \(faster) -> [ -> \(slower)")
        XCTAssertEqual(slower, restingSpeed, "[ did not step the speed back down.")

        // Space, measured against the **playhead** rather than the button's
        // label, and the reason is a measurement rather than a preference: the
        // demo recording plays for about 1.2 seconds and stops, and the button
        // is back to "Play" long before any poll reads it. Clicking the
        // on-screen button — the same `togglePlayPause` — behaves identically,
        // so a label comparison says "nothing happened" about a player that
        // demonstrably ran. What the position can still show is whether the key
        // reached the transport at all.
        app.typeKey(.leftArrow, modifierFlags: .shift)
        DemoLaunch.pause(1.2)
        let start = position(in: app)
        app.typeKey(" ", modifierFlags: [])
        DemoLaunch.pause(3)
        let played = position(in: app)
        print("PHASEB-SPACE position \(start) -> \(played), button=\(playButton(in: app).label)")
        capture("b2-space-playback")
        XCTAssertGreaterThan(
            played, start,
            "Space did not start playback: the playhead stayed at \(start)."
        )
    }

    /// Typing into the sessions search field must reach the field, not the
    /// transport. The shell, not the solo window, because the search field is
    /// the shell's toolbar.
    func testTypingInTheSearchFieldDoesNotDriveTheTransport() {
        let app = DemoLaunch.launch()
        app.typeKey("3", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let row = DemoLaunch.waitForContent(containing: "Alex Example", in: app) else {
            XCTFail("The sessions list never offered its first row.")
            return
        }
        row.click()
        DemoLaunch.settle(app)
        DemoLaunch.pause(3)

        guard app.windows.buttons["Session replay"].exists else {
            XCTFail("The session detail rendered no replay stage.")
            return
        }
        let restingPlay = playButton(in: app).label
        let restingSpeed = "\(speed(in: app).value ?? "")"
        let restingPosition = position(in: app)

        let field = app.windows.searchFields.firstMatch
        XCTAssertTrue(field.exists, "The sessions screen has no search field.")
        // Clicked through a coordinate rather than `field.click()`. On a window
        // as wide as the display XCUITest reports the toolbar's *trailing*
        // search field as not hittable while it is plainly on screen — the same
        // frame-space disagreement the status item shows — and `click()` refuses
        // on that judgement alone. The assertion at the end is the real check:
        // if the click missed, the query never reaches the field and the test
        // fails on that.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        DemoLaunch.pause(0.8)
        // Every transport key, typed as a query.
        field.typeText("a b[]")
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: .shift)
        DemoLaunch.pause(1.5)
        capture("b5-search-field-typed")

        print("PHASEB-SEARCH field=\(field.value ?? "nil") play=\(playButton(in: app).label) "
            + "speed=\(speed(in: app).value ?? "nil") position=\(position(in: app))")
        XCTAssertEqual(
            playButton(in: app).label, restingPlay,
            "A space typed into the search field started the player."
        )
        XCTAssertEqual(
            "\(speed(in: app).value ?? "")", restingSpeed,
            "Brackets typed into the search field changed the playback speed."
        )
        XCTAssertEqual(
            position(in: app), restingPosition,
            "Arrows typed into the search field moved the playhead."
        )
        XCTAssertTrue(
            "\(field.value ?? "")".contains("a b"),
            "The query never reached the field: \(field.value ?? "nil")."
        )
    }

    /// Scroll wheel over the stage — recorded either way. The question is
    /// whether the outer detail scrolls underneath the player.
    func testScrollWheelOverTheStage() {
        let app = DemoLaunch.launch()
        app.typeKey("3", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let row = DemoLaunch.waitForContent(containing: "Alex Example", in: app) else {
            XCTFail("The sessions list never offered its first row.")
            return
        }
        row.click()
        DemoLaunch.settle(app)
        DemoLaunch.pause(3)

        let stage = app.windows.buttons["Session replay"]
        guard stage.exists else {
            XCTFail("The session detail rendered no replay stage.")
            return
        }
        let before = stage.frame
        capture("b6-stage-before-scroll")
        stage.scroll(byDeltaX: 0, deltaY: -240)
        DemoLaunch.pause(1.5)
        let after = stage.frame
        capture("b7-stage-after-scroll")
        print("PHASEB-STAGE-SCROLL before=\(before) after=\(after) moved=\(before.minY - after.minY)")
        XCTAssertEqual(app.state, .runningForeground, "Scrolling the stage took the app down.")
    }
}
