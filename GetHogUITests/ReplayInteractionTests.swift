import XCTest

final class ReplayInteractionTests: XCTestCase {
    private func launchReadyReplay() -> XCUIApplication {
        let app = DemoLaunch.launch(
            openURL: "gethog://replay/\(DemoLaunch.replaySessionID)"
        )
        let slider = app.sliders["Playback position"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if slider.exists && slider.isEnabled { break }
            DemoLaunch.pause(0.5)
        }
        XCTAssertTrue(slider.exists && slider.isEnabled)
        return app
    }

    func testReplayExpandsAndReturnsItsPlayhead() {
        let app = launchReadyReplay()
        let compact = app.sliders["Playback position"]
        compact.adjust(toNormalizedSliderPosition: 0.2)

        let expand = app.buttons["Expand replay"]
        XCTAssertTrue(DemoLaunch.wait(for: expand))
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        expand.tap()

        let full = app.sliders["Full-screen playback position"]
        XCTAssertTrue(DemoLaunch.wait(for: full, timeout: 120))
        full.adjust(toNormalizedSliderPosition: 0.8)
        let expandedValue = full.value as? String

        let close = app.buttons["Close full-screen replay"]
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()

        XCTAssertTrue(DemoLaunch.wait(for: compact))
        XCTAssertEqual(compact.value as? String, expandedValue)
    }

    func testTappingReplayStageExpandsIt() {
        let app = launchReadyReplay()
        let stage = DemoLaunch.elements(labelled: "Session replay", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: stage))
        stage.tap()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.sliders["Full-screen playback position"], timeout: 120)
        )
        app.buttons["Close full-screen replay"].tap()
        XCTAssertTrue(DemoLaunch.wait(for: app.sliders["Playback position"]))
    }
}
