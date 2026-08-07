import XCTest

@MainActor
final class VisionReplayTests: XCTestCase {
    func testReplayReachesItsPlayingStage() {
        let app = DemoLaunch.launch(openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")
        let stage = DemoLaunch.elements(labelled: "Session replay", in: app)

        XCTAssertTrue(DemoLaunch.wait(for: stage.firstMatch, timeout: 120))
        XCTAssertEqual(stage.count, 1)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertEqual(app.links.count, 0)
    }
}
