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
        let markerSemantics = ["2 key events", "fictional refresh button"]
        guard let compactSemanticValue = compact.value as? String else {
            XCTFail("Compact playback position did not publish an accessibility value.")
            return
        }
        for semantic in markerSemantics {
            XCTAssertTrue(
                compactSemanticValue.contains(semantic),
                "Compact playback value \(compactSemanticValue) omitted \(semantic)."
            )
        }

        let expand = app.buttons["Expand replay"]
        XCTAssertTrue(DemoLaunch.wait(for: expand))
        XCTAssertTrue(expand.isHittable)
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        expand.tap()

        let full = app.sliders["Full-screen playback position"]
        let fullReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND enabled == true AND hittable == true"
            ),
            object: full
        )
        XCTAssertEqual(XCTWaiter().wait(for: [fullReady], timeout: 120), .completed)

        let markerRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ AND value CONTAINS %@",
                markerSemantics[0],
                markerSemantics[1]
            ),
            object: full
        )
        XCTAssertEqual(XCTWaiter().wait(for: [markerRestored], timeout: 15), .completed)
        let restoredValue = full.value as? String
        for semantic in markerSemantics {
            XCTAssertTrue(
                restoredValue?.contains(semantic) == true,
                "Ready full-screen value \(restoredValue ?? "nil") did not restore \(semantic) from \(compactSemanticValue)."
            )
        }
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

    func testGenerateSummaryAddsKeyEventsAndKeepsThemFullScreen() {
        let app = DemoLaunch.launch(
            openURL: "gethog://replay/\(DemoLaunch.replaySessionID)",
            environment: ["GETHOG_DEMO_SUMMARY_GENERATION": "1"]
        )

        let generate = app.buttons["Generate AI summary"]
        for _ in 0..<12 where !generate.isHittable {
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.3)
        }
        XCTAssertTrue(generate.exists && generate.isHittable)
        generate.tap()

        let chapter = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Chapter 1,")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: chapter, timeout: 120))

        let compact = app.sliders["Playback position"]
        for _ in 0..<12 where !compact.isHittable {
            app.swipeDown(velocity: .slow)
            DemoLaunch.pause(0.3)
        }
        XCTAssertTrue(compact.exists && compact.isEnabled)

        let expand = app.buttons["Expand replay"]
        for _ in 0..<12 where !expand.isHittable {
            app.swipeDown(velocity: .slow)
            DemoLaunch.pause(0.3)
        }
        XCTAssertTrue(expand.exists && expand.isHittable)

        compact.adjust(toNormalizedSliderPosition: 0.1)
        let markerSemantics = ["2 key events", "fictional refresh button"]
        guard let compactSemanticValue = compact.value as? String else {
            XCTFail("Compact playback position did not publish an accessibility value.")
            return
        }
        for semantic in markerSemantics {
            XCTAssertTrue(compactSemanticValue.contains(semantic))
        }
        XCTAssertTrue(expand.exists && expand.isHittable)
        expand.tap()

        let full = app.sliders["Full-screen playback position"]
        let fullReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND enabled == true AND hittable == true"
            ),
            object: full
        )
        XCTAssertEqual(XCTWaiter().wait(for: [fullReady], timeout: 120), .completed)
        XCTAssertTrue(full.exists && full.isEnabled && full.isHittable)

        let markerRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ AND value CONTAINS %@",
                markerSemantics[0],
                markerSemantics[1]
            ),
            object: full
        )
        XCTAssertEqual(XCTWaiter().wait(for: [markerRestored], timeout: 30), .completed)

        guard let fullSemanticValue = full.value as? String else {
            XCTFail("Ready full-screen playback position did not publish an accessibility value.")
            return
        }
        for semantic in markerSemantics {
            XCTAssertTrue(
                fullSemanticValue.contains(semantic),
                "Full-screen playback did not preserve \(semantic) from \(compactSemanticValue)."
            )
        }
    }
}
