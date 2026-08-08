import XCTest

/// The respond-half write controls, on screen.
///
/// Everything else about these writes is pinned off-screen: the kit tests assert
/// the request each builder produces, and the app tests assert what the
/// controllers do with each of the three answers. Neither can see whether the
/// control is *reachable*, and neither can see the sentence the confirmation
/// dialog puts in front of somebody about to change what production serves.
///
/// That sentence is the point of this file. The design problem with these actions
/// is not the endpoint, it is the word: "stop the experiment" means `end/` to one
/// reader and `pause/` to another, and only one of those touches a production
/// feature flag. A dialog that does not distinguish them is worse than no button,
/// so what is asserted here is that each dialog *says which*.
///
/// One test method per screen, and `exists` polling rather than
/// `waitForExistence`, for the two reasons this target's other files record: a
/// single method launching the app ~20 times takes the runner down, and a failing
/// XCTest wait captures a full element dump on every retry.
final class LifecycleWriteControlTests: XCTestCase {

    /// The popover branch cannot use an element-relative offset greater than one:
    /// on a short window that point leaves the app, and on a moving presentation
    /// it can land back on an action. The chosen point must be a real point in the
    /// window and clear the destructive confirmation row on either side of it.
    func testPopoverDismissPointStaysInsideTheWindowAndAwayFromConfirmation() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 600)

        for confirmation in [
            CGRect(x: 650, y: 500, width: 200, height: 44),
            CGRect(x: 150, y: 100, width: 200, height: 44),
        ] {
            guard let offset = Self.boundedPopoverDismissOffset(
                windowFrame: window,
                avoiding: confirmation
            ) else {
                return XCTFail("A normal popover had no safe bounded dismissal point.")
            }
            let point = CGPoint(
                x: window.minX + offset.dx * window.width,
                y: window.minY + offset.dy * window.height
            )

            XCTAssertTrue(window.contains(point), "The dismissal point left the app window.")
            XCTAssertFalse(
                confirmation.insetBy(dx: -12, dy: -12).contains(point),
                "The dismissal point touched the confirmation action or its safety margin."
            )
            XCTAssertTrue((0...1).contains(offset.dx))
            XCTAssertTrue((0...1).contains(offset.dy))
        }
    }

    /// A survey's stop control, and the dialog that has to promise the responses
    /// survive.
    ///
    /// "Example App metric 829" is the one survey in `surveys.json` carrying a
    /// `start_date`, so it is the only row for which stopping is offered at all —
    /// the same literal `StateScreenshotTests.testSurveyDetailSheet` uses, shared
    /// deliberately so a fixture rename fails both together.
    func testSurveyStopDialog() {
        let app = DemoLaunch.launch(tab: "surveys")
        guard DemoLaunch.wait(for: app.navigationBars["Surveys"]) else {
            return XCTFail("Surveys never came up.")
        }
        guard tapFirst(startingWith: "Example App metric 829", in: app) else {
            return XCTFail("The launched survey's row was not tappable.")
        }
        guard DemoLaunch.wait(for: app.buttons["Done"]) else {
            return XCTFail("The survey sheet never opened.")
        }
        DemoLaunch.settle(app)

        let stop = app.buttons["Stop survey"]
        scrollIntoView(stop, in: app)
        guard DemoLaunch.wait(for: stop, timeout: 10) else {
            return XCTFail("A running survey offered no way to stop it.")
        }
        // The draft-only and stopped-only actions must not be on the same screen:
        // a survey is in exactly one of the three states, and offering two would
        // mean offering a call that 400s.
        XCTAssertFalse(app.buttons["Launch survey"].exists)
        XCTAssertFalse(app.buttons["Resume survey"].exists)

        stop.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["Stop \("Example App metric 829")?"], timeout: 10),
            "Stopping a survey did not name the survey in its confirmation."
        )
        // The promise that makes this safe to tap from a phone.
        XCTAssertTrue(
            existsContaining("already collected is kept", in: app),
            "The stop dialog did not say the responses survive."
        )
        let stopConfirmation = app.buttons["Stop collecting responses"]
        guard DemoLaunch.wait(for: stopConfirmation, timeout: 10) else {
            return XCTFail("The stop dialog exposed no confirmation action.")
        }
        dismissDialog(app, anchoredTo: stopConfirmation)
    }

    /// The experiment controls, where the wording is load-bearing rather than
    /// merely helpful.
    ///
    /// Two dialogs are checked, and the assertion is the *difference* between
    /// them: pause has to say the feature flag turns off, end has to say it does
    /// not. Those two sentences are the whole reason this feature is two buttons.
    func testExperimentPauseAndEndDialogsDifferAboutTheFlag() {
        let app = DemoLaunch.launch(tab: "experiments")
        guard DemoLaunch.wait(for: app.navigationBars["Experiments"]) else {
            return XCTFail("Experiments never came up.")
        }
        // The one running experiment in `experiments.json` — the only row for
        // which pausing is offered. Shared with `AccessibilityAuditTests`.
        guard tapFirst(startingWith: "Example cache strategy trial", in: app) else {
            return XCTFail("The running experiment's row was not tappable.")
        }
        guard DemoLaunch.wait(for: app.buttons["Done"]) else {
            return XCTFail("The experiment sheet never opened.")
        }
        DemoLaunch.settle(app)

        let pause = app.buttons["Pause"]
        scrollIntoView(pause, in: app)
        guard DemoLaunch.wait(for: pause, timeout: 10) else {
            return XCTFail("A running experiment offered no way to pause it.")
        }

        pause.tap()
        let pauseConfirmation = app.buttons["Pause and turn the flag off"]
        guard DemoLaunch.wait(for: pauseConfirmation, timeout: 10) else {
            return XCTFail("The pause dialog never appeared.")
        }
        // Pausing calls `set_flag_active` on the linked flag. If this sentence
        // ever stops naming the flag, the button becomes the ambiguous "stop"
        // this whole design exists to avoid.
        XCTAssertTrue(
            existsContaining("feature flag", in: app),
            "The pause dialog did not say a feature flag changes."
        )
        dismissDialog(app, anchoredTo: pauseConfirmation)

        let end = app.buttons["End experiment"]
        scrollIntoView(end, in: app)
        guard DemoLaunch.wait(for: end, timeout: 10) else {
            return XCTFail("A running experiment offered no way to end it.")
        }
        end.tap()
        // The conclusion is a required choice, because `end_experiment` assigns
        // it unconditionally and an absent one writes null over what was there.
        // The inline picker expands the lifecycle section enough to put the
        // actual end action below the List's realized rows. Bring the exact
        // action under test on screen before asking XCTest to resolve it.
        let endAsWon = app.buttons["End as Won"]
        scrollIntoView(endAsWon, in: app)
        guard DemoLaunch.wait(for: endAsWon, timeout: 10) else {
            return XCTFail("Ending did not ask for a conclusion first.")
        }
        endAsWon.tap()
        let endConfirmation = app.buttons["End the experiment"]
        guard DemoLaunch.wait(for: endConfirmation, timeout: 10) else {
            return XCTFail("The end dialog never appeared.")
        }
        // The opposite claim to the pause dialog's, in the same words, so the two
        // cannot be read as the same action.
        XCTAssertTrue(
            existsContaining("is not changed", in: app),
            "The end dialog did not say the feature flag is left alone."
        )
        dismissDialog(app, anchoredTo: endConfirmation)
    }

    /// The rollout editor, which cannot be a single number and has to say which
    /// condition set it is aimed at.
    func testFlagRolloutEditorNamesItsConditionSet() {
        // Reached by deep link rather than by tapping a row, which is this
        // target's own rule: a test that navigates also fails when navigation
        // changes. It also names which authored demo flag the rollout contract
        // exercises, matching the unit-test fixture.
        let app = DemoLaunch.launch(openURL: "gethog://feature_flags/710301")
        guard DemoLaunch.wait(for: app.navigationBars["example-navigation"], timeout: 30) else {
            return XCTFail("The flag detail never opened.")
        }
        DemoLaunch.settle(app)

        // Matched on the prefix, not on "set 1": whichever flag the list puts
        // first decides the number, and the assertion is that the control names
        // *a* condition set rather than which one.
        let apply = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Apply to set")
        ).firstMatch
        scrollIntoView(apply, in: app)
        guard DemoLaunch.wait(for: apply, timeout: 10) else {
            return XCTFail("The flag detail offered no rollout control.")
        }

        // The slider is adjusted before Apply is reachable at all, and that is
        // the control's design rather than a step in a script: Apply is disabled
        // while the draft equals what PostHog already stores, so a rollout write
        // cannot be committed by tapping through without moving anything.
        let slider = app.sliders.firstMatch
        guard DemoLaunch.wait(for: slider, timeout: 10) else {
            return XCTFail("The rollout editor had no slider.")
        }
        XCTAssertFalse(
            apply.isEnabled,
            "Apply was live before the percentage had been moved off the stored value."
        )
        slider.adjust(toNormalizedSliderPosition: 0.5)
        DemoLaunch.pause(0.5)
        guard DemoLaunch.wait(for: apply, timeout: 10), apply.isEnabled else {
            return XCTFail("Moving the rollout slider did not enable Apply.")
        }

        apply.tap()
        guard DemoLaunch.wait(for: app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Set condition set")
        ).firstMatch, timeout: 10) else {
            return XCTFail("The rollout dialog did not name the condition set.")
        }
        XCTAssertTrue(
            existsContaining("affects live users", in: app),
            "The rollout dialog did not say it affects production."
        )
        let rolloutConfirmation = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Set to ")
        ).firstMatch
        guard DemoLaunch.wait(for: rolloutConfirmation, timeout: 10) else {
            return XCTFail("The rollout dialog exposed no confirmation action.")
        }
        dismissDialog(app, anchoredTo: rolloutConfirmation)
    }

    // MARK: - Harness

    private func existsContaining(_ fragment: String, in app: XCUIApplication) -> Bool {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", fragment)
        ).firstMatch.exists
    }

    /// Cancels whichever confirmation dialog is up, so the next step starts from a
    /// known screen — and so **no write is ever committed**. Every one of these
    /// would be a real request in a non-demo build, and leaving a dialog confirmed
    /// is the difference between a test and an edit.
    private func dismissDialog(
        _ app: XCUIApplication,
        anchoredTo confirmationAction: XCUIElement
    ) {
        let cancel = app.buttons["Cancel"]
        let dismissRegion = app.descendants(matching: .any)
            .matching(identifier: "PopoverDismissRegion")
            .firstMatch
        // Compact-width confirmation dialogs can still render as popovers. In
        // that presentation UIKit omits the cancel button entirely and exposes
        // the safe outside-tap region instead. Waiting only for `Cancel` leaves
        // the dialog covering the sheet and lets the test interact with controls
        // behind it.
        if dismissRegion.exists {
            // A detail sheet and its confirmation can each publish a dismiss
            // region on iPad. `firstMatch` is therefore only a presentation
            // signal, never a safe coordinate or a reliable disappearance
            // witness. Wait until the inner popover's final action is actually
            // tappable and no longer moving, then tap the farthest inset corner
            // of the app window. That point is bounded by construction and is
            // separated from the confirmation row by a safety margin.
            guard let confirmationFrame = stableHittableFrame(of: confirmationAction) else {
                return XCTFail("The confirmation dialog never reached a stable presentation.")
            }
            let window = app.windows.firstMatch
            guard window.exists,
                  let offset = Self.boundedPopoverDismissOffset(
                    windowFrame: window.frame,
                    avoiding: confirmationFrame
                  ) else {
                return XCTFail("The confirmation dialog exposed no safe bounded dismissal point.")
            }
            window.coordinate(withNormalizedOffset: offset).tap()
            for _ in 0..<10 where confirmationAction.exists {
                DemoLaunch.pause(0.4)
            }
            return XCTAssertFalse(
                confirmationAction.exists,
                "The confirmation dialog did not dismiss."
            )
        }

        // Hittable, not merely present. A confirmation dialog publishes its
        // buttons while it is still animating in, and tapping one then fails the
        // test with "Failed to not hittable" rather than dismissing anything.
        for _ in 0..<20 where !cancel.isHittable {
            DemoLaunch.pause(0.25)
        }
        guard cancel.isHittable else {
            return XCTFail("The confirmation dialog exposed no safe dismissal control.")
        }
        cancel.tap()
        // Waited for rather than assumed. A confirmation dialog that is still up
        // covers the sheet, so the next step would poll for a control that is
        // present and simply hidden — and enough failed polls in a row end the
        // run rather than failing a test, which is exactly how this was found.
        for _ in 0..<10 where cancel.exists {
            DemoLaunch.pause(0.4)
        }
        XCTAssertFalse(cancel.exists, "The confirmation dialog did not dismiss.")
    }

    private static func boundedPopoverDismissOffset(
        windowFrame: CGRect,
        avoiding confirmationFrame: CGRect
    ) -> CGVector? {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return nil }

        // Stay clear of the status/home-indicator edges as well as the popover.
        // The quarter-window cap keeps the candidates meaningfully corner-shaped
        // in a very small Stage Manager window.
        let horizontalInset = min(max(24, windowFrame.width * 0.08), windowFrame.width / 4)
        let verticalInset = min(max(24, windowFrame.height * 0.08), windowFrame.height / 4)
        let candidates = [
            CGPoint(x: windowFrame.minX + horizontalInset, y: windowFrame.minY + verticalInset),
            CGPoint(x: windowFrame.maxX - horizontalInset, y: windowFrame.minY + verticalInset),
            CGPoint(x: windowFrame.minX + horizontalInset, y: windowFrame.maxY - verticalInset),
            CGPoint(x: windowFrame.maxX - horizontalInset, y: windowFrame.maxY - verticalInset),
        ]
        let protectedConfirmation = confirmationFrame.insetBy(dx: -12, dy: -12)
        guard let point = candidates
            .filter({ windowFrame.contains($0) && !protectedConfirmation.contains($0) })
            .max(by: {
                $0.squaredDistance(to: confirmationFrame.center)
                    < $1.squaredDistance(to: confirmationFrame.center)
            }) else { return nil }

        return CGVector(
            dx: (point.x - windowFrame.minX) / windowFrame.width,
            dy: (point.y - windowFrame.minY) / windowFrame.height
        )
    }

    private func stableHittableFrame(
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: CGRect?
        var stableSamples = 0

        while Date() < deadline {
            if element.exists, element.isHittable, !element.frame.isEmpty {
                let current = element.frame
                if current == previous {
                    stableSamples += 1
                } else {
                    previous = current
                    stableSamples = 1
                }
                if stableSamples >= 2 { return current }
            } else {
                previous = nil
                stableSamples = 0
            }
            DemoLaunch.pause(0.2)
        }
        return nil
    }

    private func tapFirst(startingWith prefix: String, in app: XCUIApplication) -> Bool {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        guard DemoLaunch.wait(for: match, timeout: 15), match.isHittable else { return false }
        match.tap()
        return true
    }

    /// Swipes until the element is on screen, bounded.
    ///
    /// The lifecycle sections sit below the results on both sheets and below the
    /// release conditions on the flag screen, which at accessibility type sizes is
    /// several screens down.
    ///
    /// **`velocity: .slow`, and that is the whole of it.** A default `swipeUp` is
    /// a flick: measured on the experiment sheet, one of them carried "End
    /// experiment" from *just below the fold* — `exists` true, `isHittable` false
    /// — to off the top and out of the list's realized rows entirely, so the next
    /// check found nothing and the loop kept flicking away from it. A slow swipe
    /// moves roughly a screen without inertia, which is what "scroll until I can
    /// see it" actually means.
    private func scrollIntoView(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 10
    ) {
        for _ in 0..<maximumSwipes {
            if element.exists && element.isHittable { return }
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.3)
        }
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
