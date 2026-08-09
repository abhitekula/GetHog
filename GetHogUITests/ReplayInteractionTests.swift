import XCTest

final class ReplayInteractionTests: XCTestCase {
    private enum ScrollDirection {
        case up
        case down
    }

    /// Scrolls using geometry before asking XCTest for `isHittable`.
    ///
    /// On iOS 26.5 an offscreen SwiftUI button can remain in the accessibility
    /// hierarchy with a valid frame below the window, while reading
    /// `isHittable` records an activation-point failure instead of returning
    /// `false`. Keep the discovery loop independent of that property, then let
    /// each test assert hittability once the control is fully unobscured.
    private func bringOnscreen(
        _ element: XCUIElement,
        in app: XCUIApplication,
        direction: ScrollDirection,
        attempts: Int = 12
    ) {
        let window = app.windows.firstMatch
        for _ in 0..<attempts {
            if element.exists {
                let frame = element.frame
                let windowFrame = window.frame
                let navigationBar = app.navigationBars.firstMatch
                let tabBar = app.tabBars.firstMatch
                let visibleTop = navigationBar.exists
                    ? max(windowFrame.minY, navigationBar.frame.maxY)
                    : windowFrame.minY
                let visibleBottom = tabBar.exists
                    ? min(windowFrame.maxY, tabBar.frame.minY)
                    : windowFrame.maxY
                if frame.width > 0,
                   frame.height > 0,
                   frame.minY >= visibleTop,
                   frame.maxY <= visibleBottom {
                    return
                }
            }

            switch direction {
            case .up:
                app.swipeUp(velocity: .slow)
            case .down:
                app.swipeDown(velocity: .slow)
            }
            DemoLaunch.pause(0.3)
        }
    }

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

        // Stabilise the replay's final height before locating content below it.
        // The preparing stage is shorter, so the summary action can briefly be
        // onscreen and then move below the tab bar when playback becomes ready.
        let compact = app.sliders["Playback position"]
        let playbackReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: compact
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playbackReady], timeout: 120), .completed)

        let generate = app.buttons["Generate AI summary"]
        bringOnscreen(generate, in: app, direction: .up)
        XCTAssertTrue(generate.exists && generate.isHittable)
        generate.tap()

        let chapter = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Chapter 1,")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: chapter, timeout: 120))

        bringOnscreen(compact, in: app, direction: .down)
        XCTAssertTrue(compact.exists && compact.isEnabled && compact.isHittable)

        let expand = app.buttons["Expand replay"]
        bringOnscreen(expand, in: app, direction: .down)
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
