import XCTest

@MainActor
final class VisionReplayTests: XCTestCase {
    func testReplayReachesItsPlayingStage() {
        let app = DemoLaunch.launch(openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")
        let inlineStage = app.buttons.matching(NSPredicate(
            format: "label == %@",
            "Session replay"
        ))

        XCTAssertTrue(
            DemoLaunch.wait(for: inlineStage.firstMatch, timeout: 120),
            "The inline Session replay button never appeared."
        )
        let becameReady = DemoLaunch.wait(timeout: 120) {
            inlineStage.firstMatch.exists && inlineStage.firstMatch.isEnabled
        }
        XCTAssertTrue(
            becameReady,
            "The inline Session replay button appeared but never became enabled."
        )
        guard becameReady else { return }

        XCTAssertEqual(inlineStage.count, 1)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertEqual(app.links.count, 0)

        inlineStage.firstMatch.tap()

        let expandedStage = DemoLaunch.elements(
            labelled: "Full-screen session replay",
            in: app
        )
        let close = app.buttons.matching(NSPredicate(
            format: "label == %@",
            "Close full-screen replay"
        ))
        let expanded = DemoLaunch.wait {
            expandedStage.firstMatch.exists && close.firstMatch.exists
        }
        XCTAssertTrue(
            expanded,
            "The ready inline replay did not expand with its native Close action."
        )
        guard expanded else { return }

        XCTAssertEqual(expandedStage.count, 1)
        XCTAssertEqual(close.count, 1)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertEqual(app.links.count, 0)

        close.firstMatch.tap()

        let returnedInline = DemoLaunch.wait {
            !expandedStage.firstMatch.exists
                && !close.firstMatch.exists
                && inlineStage.count == 1
                && inlineStage.firstMatch.isEnabled
        }
        XCTAssertTrue(
            returnedInline,
            "Close did not restore exactly one enabled inline Session replay button."
        )
        guard returnedInline else { return }

        XCTAssertEqual(inlineStage.count, 1)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertEqual(app.links.count, 0)
    }
}
