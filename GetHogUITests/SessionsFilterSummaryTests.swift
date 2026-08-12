import XCTest

@MainActor
final class SessionsFilterSummaryTests: XCTestCase {
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
