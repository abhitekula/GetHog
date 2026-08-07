import XCTest

@MainActor
final class TVSessionDetailTests: XCTestCase {
    func testSessionDetailShowsTheReplayTimeline() {
        let app = DemoLaunch.launch(tab: "sessions")
        let session = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Alex Example,")
        ).firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: session, timeout: 60))
        XCTAssertTrue(TVRemote.focus(on: session, by: .right))
        TVRemote.press(.select)

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Replay activity"], timeout: 60))
        let timelineTile = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "Events", "Console errors", "Failed requests")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: timelineTile, timeout: 30))
    }
}
