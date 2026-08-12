import AppKit
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

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, accuracy: CGFloat = 1) -> Bool {
        abs(lhs.minX - rhs.minX) <= accuracy
            && abs(lhs.minY - rhs.minY) <= accuracy
            && abs(lhs.width - rhs.width) <= accuracy
            && abs(lhs.height - rhs.height) <= accuracy
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

    /// Expansion is a second native window, including the native full-screen
    /// cycle, and closing that window returns ownership to the inline player.
    func testExpandedReplayUsesANativeWindowAndReturnsInline() {
        let app = openSessionDetail()
        let inlineStage = app.windows.buttons["Session replay"]
        let inlineTransport = app.windows.sliders["Playback position"]
        guard inlineStage.exists else {
            XCTFail("The session detail rendered no inline replay stage.")
            return
        }
        guard inlineTransport.exists, let inlineValue = inlineTransport.value as? String else {
            XCTFail("The inline replay published no playback value before expansion.")
            return
        }

        app.windows.buttons["Expand replay"].click()
        let expandedStage = app.windows.descendants(matching: .any)["Full-screen session replay"]
        XCTAssertTrue(
            DemoLaunch.wait(for: expandedStage, timeout: 15),
            "Expansion rendered no replay stage in a native window."
        )
        let expandedTransport = app.windows.sliders["Full-screen playback position"]
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                expandedTransport.exists && expandedTransport.isEnabled && expandedTransport.isHittable
            }),
            "The expanded replay window rendered no transport."
        )

        let expandedWindow = app.windows.matching(
            NSPredicate(format: "label CONTAINS %@", "Alex Example")
        ).firstMatch
        XCTAssertTrue(expandedWindow.exists, "Expansion created no person-titled replay window.")
        XCTAssertGreaterThanOrEqual(expandedWindow.frame.width, 640)
        XCTAssertGreaterThanOrEqual(expandedWindow.frame.height, 480)
        XCTAssertGreaterThanOrEqual(app.windows.count, 2)
        capture("b10-expanded-native-window")

        expandedTransport.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                guard let value = expandedTransport.value as? String else { return false }
                return value != inlineValue
            }),
            "The expanded transport did not move away from the inline playhead."
        )
        guard let transferredValue = expandedTransport.value as? String else {
            XCTFail("The expanded replay published no playback value to hand back.")
            return
        }

        let beforeFullScreen = expandedWindow.frame
        app.typeKey("f", modifierFlags: [.control, .command])
        XCTAssertTrue(
            DemoLaunch.wait(until: { !self.framesMatch(expandedWindow.frame, beforeFullScreen) }),
            "The replay window did not enter native full screen."
        )
        app.typeKey("f", modifierFlags: [.control, .command])
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.framesMatch(expandedWindow.frame, beforeFullScreen) }),
            "The replay window did not restore its pre-full-screen frame."
        )
        let afterFullScreen = expandedWindow.frame
        XCTAssertEqual(afterFullScreen.minX, beforeFullScreen.minX, accuracy: 1)
        XCTAssertEqual(afterFullScreen.minY, beforeFullScreen.minY, accuracy: 1)
        XCTAssertEqual(afterFullScreen.width, beforeFullScreen.width, accuracy: 1)
        XCTAssertEqual(afterFullScreen.height, beforeFullScreen.height, accuracy: 1)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                !expandedStage.exists
                    && app.windows.count == 1
                    && (inlineTransport.value as? String) == transferredValue
            }),
            "Command-W did not close the expanded window and transfer its playhead inline."
        )
        XCTAssertTrue(inlineStage.exists)
        XCTAssertEqual(inlineTransport.value as? String, transferredValue)
        XCTAssertEqual(app.windows.count, 1)
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

    /// **Opening a session must not resize the window.**
    ///
    /// It used to. `.inspector` — present on this screen whether or not it was
    /// showing — grew a clean 1,280pt shell to 2,102pt on a 1,512pt display,
    /// which put the toolbar's trailing search field 590pt off the right edge
    /// where nothing could click it, and AppKit then autosaved that frame for
    /// the next launch. `testTypingInTheSearchFieldDoesNotDriveTheTransport` was
    /// the suite's only witness, and it reported the symptom
    /// ("Neither element nor any descendant has keyboard focus") rather than the
    /// cause.
    ///
    /// Measured as a delta rather than against a literal 1,280: a window frame
    /// outlives the process and a UI test cannot seed one — the runner is
    /// sandboxed, so its `defaults write` reaches its own container and never
    /// the app's. What this can say without seeding anything is the thing that
    /// was actually wrong: the shell is whatever size it was, and opening a
    /// recording does not change it.
    func testOpeningASessionDoesNotResizeTheWindow() {
        let app = DemoLaunch.launch()
        app.typeKey("3", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let row = DemoLaunch.waitForContent(containing: "Alex Example", in: app) else {
            XCTFail("The sessions list never offered its first row.")
            return
        }
        let listed = app.windows.firstMatch.frame
        row.click()
        DemoLaunch.settle(app)
        _ = DemoLaunch.wait(for: app.windows.buttons["Session replay"], timeout: 30)
        DemoLaunch.pause(3)
        let opened = app.windows.firstMatch.frame
        print("PHASEB-WINDOW listed=\(listed) opened=\(opened)")
        capture("b8-session-opened-window")
        XCTAssertEqual(
            opened.width, listed.width, accuracy: 1,
            "Opening a session grew the window from \(listed.width) to \(opened.width)."
        )

        // Closed by default is the fix; unreachable would be a regression of
        // its own. Read off the **stage** rather than off the pane's text: the
        // words "Console" and "network" both already appear on this screen — in
        // the stat strip's `Console errors` and in the watch-in-PostHog card —
        // so a `CONTAINS` match cannot tell the pane from the page it sits
        // beside. A stage that narrows says the pane took width from the
        // content, which is the whole of what changed.
        let toggle = app.windows.descendants(matching: .button)
            .matching(NSPredicate(
                format: "label == 'Toggle replay diagnostics' OR label == 'Replay Diagnostics'"
            ))
            .firstMatch
        XCTAssertTrue(toggle.exists, "The diagnostics toggle left the toolbar.")
        let narrowStage = app.windows.buttons["Session replay"].frame
        toggle.click()
        DemoLaunch.settle(app)
        DemoLaunch.pause(2)
        let widened = app.windows.firstMatch.frame
        let squeezedStage = app.windows.buttons["Session replay"].frame
        print("PHASEB-WINDOW toggled window=\(widened) stage \(narrowStage.width) -> \(squeezedStage.width)")
        capture("b9-session-diagnostics-open")
        XCTAssertLessThan(
            squeezedStage.width, narrowStage.width,
            "The toolbar toggle opened no diagnostics pane beside the player."
        )
        // **Opening the pane is still allowed to widen the window, and does —
        // measured at +148pt from 1,280.** The page's own minimum is about
        // 517pt and the pane asks for 320, which is more than the detail column
        // has at the default size. That is a window growing because somebody
        // asked for a second column, which is what the toggle is; the defect
        // was a window growing 822pt because a screen *opened*. What must hold
        // either way is that nothing lands off the display — 590pt of toolbar
        // past the right edge is how this was found.
        //
        // `NSScreen` rather than `XCUIScreen`, which carries no frame — the
        // runner is an app on the same display, so its own screen list is the
        // measure.
        let display = NSScreen.main?.frame ?? .zero
        XCTAssertLessThanOrEqual(
            widened.maxX, display.maxX,
            "The diagnostics pane pushed the window off the \(display.width)pt display: \(widened)."
        )
        // Closed again, so the suite hands the next test the shape it found.
        // The frame stays where AppKit left it — a window does not shrink back
        // and a UI test cannot make it — but the pane does not linger.
        toggle.click()
        DemoLaunch.settle(app)
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
