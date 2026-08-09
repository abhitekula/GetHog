import XCTest

@MainActor
final class TVSessionDetailTests: XCTestCase {
    func testSessionDetailShowsTheReplayTimeline() {
        let app = openCanonicalSession()
        let timelineTile = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "Events", "Console errors", "Failed requests")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: timelineTile, timeout: 30))
    }

    func testAISummaryActionCanReceiveFocus() {
        let app = openCanonicalSession(environment: [
            "GETHOG_DEMO_SUMMARY_GENERATION": "1"
        ])
        let generate = app.buttons["Generate AI summary"]

        XCTAssertTrue(DemoLaunch.wait(for: generate, timeout: 60))
        XCTAssertTrue(
            TVRemote.focus(on: generate, by: .up, limit: 32),
            "The summary action must be reachable from the session timeline with the Siri Remote."
        )
    }

    func testAISummaryRequiresConfirmationAndCancelKeepsItAbsent() {
        let app = openCanonicalSession(environment: [
            "GETHOG_DEMO_SUMMARY_GENERATION": "1"
        ])
        let generate = app.buttons["Generate AI summary"]
        XCTAssertTrue(DemoLaunch.wait(for: generate, timeout: 60))
        XCTAssertTrue(TVRemote.focus(on: generate, by: .up, limit: 32))

        TVRemote.press(.select)

        let title = app.sheets["Generate and save an AI summary for Alex Example?"]
        XCTAssertTrue(DemoLaunch.wait(for: title, timeout: 10))
        let consequences = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "save the generated summary with this session",
            "save the generated summary with this session"
        )).firstMatch
        let budget = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "shared query and AI budget",
            "shared query and AI budget"
        )).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: consequences, timeout: 10))
        XCTAssertTrue(DemoLaunch.wait(for: budget, timeout: 10))

        let cancelButtons = app.buttons.matching(identifier: "Cancel")
        let cancel = cancelButtons.firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: cancel, timeout: 10))
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 5) {
                TVRemote.focusedElement(in: cancelButtons).exists
            },
            "Cancel must be the safe initial focus for this persistent write."
        )
        TVRemote.press(.select)

        XCTAssertTrue(DemoLaunch.wait(until: { !title.exists && generate.exists }))
        XCTAssertFalse(
            DemoLaunch.wait(timeout: 2) { !generate.exists },
            "Cancel sent or completed a summary-generation POST."
        )
    }

    private func openCanonicalSession(
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = DemoLaunch.launch(tab: "sessions", environment: environment)
        let session = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Alex Example,")
        ).firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: session, timeout: 60))
        XCTAssertTrue(TVRemote.focus(on: session, by: .right, limit: 16))
        TVRemote.press(.select)
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Replay activity"], timeout: 60))
        return app
    }
}
