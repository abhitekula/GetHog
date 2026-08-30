import XCTest

@MainActor
final class SessionsFilterSummaryTests: XCTestCase {
    func testPullToRefreshKeepsSearchChromeAboveFirstSession() {
        let app = DemoLaunch.launch(tab: "sessions")
        defer { app.terminate() }

        let search = app.searchFields["Search person email"]
        let first = app.descendants(matching: .any)[
            "gethog.session-card.\(DemoLaunch.replaySessionID)"
        ]
        let sessionsList = app.collectionViews["gethog.sessions-list"]
        XCTAssertTrue(DemoLaunch.wait(for: search))
        XCTAssertTrue(DemoLaunch.wait(for: first))
        XCTAssertTrue(DemoLaunch.wait(for: sessionsList))

        sessionsList.swipeDown(velocity: .slow)
        XCTAssertTrue(DemoLaunch.wait(for: first), "The first session vanished after refresh.")
        XCTAssertLessThanOrEqual(
            search.frame.maxY,
            first.frame.minY,
            "Pull-to-refresh moved the native search drawer through the first session card."
        )
    }

    func testScrollingPastFirstPageLoadsMoreSessions() {
        let app = DemoLaunch.launch(
            tab: "sessions",
            environment: ["GETHOG_DEMO_PAGINATED_SESSIONS": "1"]
        )
        defer { app.terminate() }

        let first = app.descendants(matching: .any)[
            "gethog.session-card.synthetic-paged-session-001"
        ]
        XCTAssertTrue(
            DemoLaunch.wait(for: first),
            "The deterministic first Sessions page never rendered."
        )
        let sessionsList = app.collectionViews["gethog.sessions-list"]
        XCTAssertTrue(
            DemoLaunch.wait(for: sessionsList),
            "The Sessions rows were not hosted in a scrollable list."
        )

        let nextPage = app.descendants(matching: .any)[
            "gethog.session-card.synthetic-paged-session-051"
        ]
        XCTAssertFalse(
            DemoLaunch.wait(for: nextPage, timeout: 1),
            "Sessions eagerly loaded offset 50 before the first-page tail became visible."
        )
        XCTAssertTrue(
            scroll(sessionsList, until: nextPage),
            "Scrolling through the first 50 Sessions rows never loaded offset 50."
        )

        let thirdPage = app.descendants(matching: .any)[
            "gethog.session-card.synthetic-paged-session-101"
        ]
        XCTAssertFalse(
            thirdPage.exists,
            "Sessions loaded offset 100 before its replacement tail became visible."
        )
        XCTAssertTrue(
            scroll(sessionsList, until: thirdPage),
            "Scrolling through the second 50 Sessions rows never loaded offset 100."
        )
    }

    private func scroll(
        _ container: XCUIElement,
        until element: XCUIElement,
        maximumSwipes: Int = 32
    ) -> Bool {
        for _ in 0..<maximumSwipes {
            if element.exists { return true }
            container.swipeUp(velocity: .slow)
            if DemoLaunch.wait(for: element, timeout: 0.5) { return true }
        }
        return element.exists
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        switch toggle.value {
        case let value as NSNumber:
            value.boolValue
        case let value as String:
            value == "1" || value.caseInsensitiveCompare("on") == .orderedSame
        default:
            false
        }
    }

    private func showExcludedUsersSummary(in app: XCUIApplication) -> (
        sentence: XCUIElement,
        clear: XCUIElement
    ) {
        let filter = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Filter sessions")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: filter), "Sessions did not expose its filter action.")
        filter.tap()

        let toggle = app.switches["Filter out internal and test users"]
        XCTAssertTrue(DemoLaunch.wait(for: toggle), "The test-user toggle did not render.")
        let sheetClear = app.navigationBars["Filter sessions"].buttons["Clear"]
        if sheetClear.exists {
            sheetClear.tap()
            XCTAssertTrue(
                DemoLaunch.wait(timeout: 5) { !isOn(toggle) },
                "Sheet Clear did not turn off the durable test-user choice."
            )
        }
        if !isOn(toggle) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let turnedOn = DemoLaunch.wait(for: sheetClear, timeout: 5)
        XCTAssertTrue(
            turnedOn,
            "The test-user choice did not turn on before dismissing the sheet; "
                + "accessibility value was \(String(describing: toggle.value))."
        )
        app.buttons["Done"].tap()

        let sentence = app.staticTexts["Showing excluding test users."]
        let clear = app.buttons["Clear all session filters"]
        XCTAssertTrue(DemoLaunch.wait(for: sentence), "The active-filter sentence did not render.")
        XCTAssertTrue(DemoLaunch.wait(for: clear), "The active-filter Clear action did not render.")
        return (sentence, clear)
    }

    func testSummaryClearAlignsWithSentenceAndKeepsItsHitTarget() {
        let app = DemoLaunch.launch(tab: "sessions")
        defer { app.terminate() }
        let summary = showExcludedUsersSummary(in: app)
        let midpointDelta = abs(summary.clear.frame.midY - summary.sentence.frame.midY)
        print(
            "SESSIONS-FILTER-SUMMARY-MEASUREMENT "
                + "midpointDelta=\(midpointDelta) clearFrame=\(summary.clear.frame)"
        )

        XCTAssertEqual(
            summary.clear.frame.midY,
            summary.sentence.frame.midY,
            accuracy: 2,
            "Clear is not vertically aligned with the visible summary sentence."
        )
        summary.clear.assertMeetsMinimumHitTarget("Sessions active-filter Clear action")
        summary.clear.tap()
    }

    func testSummaryStacksClearAfterSentenceAtAX5() {
        let app = DemoLaunch.launch(
            tab: "sessions",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        defer { app.terminate() }
        let summary = showExcludedUsersSummary(in: app)

        XCTAssertGreaterThanOrEqual(
            summary.clear.frame.minY,
            summary.sentence.frame.maxY,
            "At AX5, Clear must follow the complete sentence instead of floating beside it."
        )
        summary.clear.assertMeetsMinimumHitTarget("AX5 Sessions active-filter Clear action")
        summary.clear.tap()
    }

    func testExcludedUsersChoiceSurvivesRelaunch() {
        let app = DemoLaunch.launch(tab: "sessions")
        defer { app.terminate() }
        _ = showExcludedUsersSummary(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Sessions"]))

        let restored = app.staticTexts["Showing excluding test users."]
        XCTAssertTrue(
            DemoLaunch.wait(for: restored),
            "The active project's test-user exclusion did not survive relaunch."
        )
        let clear = app.buttons["Clear all session filters"]
        XCTAssertTrue(DemoLaunch.wait(for: clear))
        clear.tap()
    }
}
