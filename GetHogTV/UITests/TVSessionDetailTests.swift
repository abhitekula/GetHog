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
