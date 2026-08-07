import XCTest

/// The one thing only a real SwiftUI runtime can settle.
///
/// `FlagToggleController` is unit-tested against the ordering this app
/// believes SwiftUI uses — the dialog's `isPresented` binding is set to false
/// synchronously with the tap, before the button's `Task` body runs. That
/// belief is exactly what was wrong before, so it is worth one test that
/// models no ordering at all and simply taps the button.
///
/// Demo mode throughout: the transport answers the PATCH from a fixture and
/// the device-owner gate is satisfied by construction, so nothing here needs a
/// credential or a passcode.
///
/// Deliberately state-agnostic. The demo writes its snapshot to the App Group
/// container, so a flag this test flipped stays flipped for the next run;
/// asserting "on becomes off" would pass once and fail forever after. The
/// direction is read from the dialog the app itself put up.
@MainActor
final class WatchFlagToggleUITests: XCTestCase {

    func testConfirmingTheDialogActuallyFlipsTheFlag() {
        let app = DemoLaunch.launch(environment: ["GETHOG_WATCH_PAGE": "flags"])

        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "example-navigation,")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: row, timeout: 60), "the flags page never drew its shortlist")
        let before = row.label

        row.tap()

        let message = app.staticTexts["This changes the flag for everyone in this project."]
        XCTAssertTrue(
            DemoLaunch.wait(for: message, timeout: 30),
            "tapping a flag did not put up the confirmation dialog"
        )

        // Whichever direction the app decided to offer.
        let turnOn = app.buttons["Turn on"]
        let turnOff = app.buttons["Turn off"]
        let confirm = turnOn.exists ? turnOn : turnOff
        XCTAssertTrue(confirm.exists, "the dialog offered neither direction")

        // Nothing may have been written yet: the dialog is the gate.
        XCTAssertTrue(
            app.buttons[before].exists,
            "the flag moved before the dialog was answered"
        )

        confirm.tap()

        let after = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "example-navigation,", before)
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: after, timeout: 30),
            "confirming the dialog did not write the flag — the tap's work was dropped"
        )
    }

    func testCancellingTheDialogWritesNothing() {
        let app = DemoLaunch.launch(environment: ["GETHOG_WATCH_PAGE": "flags"])
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "example-navigation,")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: row, timeout: 60))
        let before = row.label

        row.tap()
        let message = app.staticTexts["This changes the flag for everyone in this project."]
        XCTAssertTrue(DemoLaunch.wait(for: message, timeout: 30))
        let cancel = app.buttons["Cancel"]
        let close = app.buttons["Close"].firstMatch
        let dismiss = cancel.exists ? cancel : close
        XCTAssertTrue(dismiss.exists, "The confirmation dialog offered no dismissal control.")
        dismiss.tap()

        // Prove no changed label appears during the whole observation window.
        // Waiting positively for the old label would return immediately and
        // could miss a delayed write after the dialog dismissed.
        let changed = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "example-navigation,", before)
        ).firstMatch
        XCTAssertFalse(
            DemoLaunch.wait(timeout: 3, until: { changed.exists }),
            "Cancelling the confirmation dialog changed the flag."
        )
        XCTAssertTrue(app.buttons[before].exists, "The unchanged flag row disappeared after cancellation.")
    }
}
