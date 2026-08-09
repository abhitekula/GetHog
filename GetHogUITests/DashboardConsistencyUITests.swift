import XCTest

final class DashboardConsistencyUITests: XCTestCase {
    private static let emptyDashboardID = 725_103

    func testDashboardShowsInitialLoadingBeforeTiles() {
        let app = DemoLaunch.launch(
            openURL: "gethog://dashboard/\(DemoLaunch.dashboardID)",
            environment: ["GETHOG_DEMO_DASHBOARD_DETAIL_DELAY_MS": "1500"]
        )

        let loading = app.staticTexts["Loading dashboard…"]
        XCTAssertTrue(
            DemoLaunch.wait(for: loading, timeout: 2),
            "The dashboard never exposed an honest initial loading state."
        )
        let tile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", DemoLaunch.firstTileTitle)
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: tile),
            "The delayed dashboard did not replace loading with its first tile."
        )
    }

    func testDashboardShowsZeroTileEmptyState() {
        let app = DemoLaunch.launch(
            openURL: "gethog://dashboard/\(Self.emptyDashboardID)"
        )

        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Synthetic empty dashboard"]),
            "The deterministic empty dashboard did not load."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["No tiles on this dashboard"]),
            "A successful dashboard with zero tiles still looked like a blank canvas."
        )
    }

    func testDashboardRecomputeFailureRemainsVisibleBesideTiles() {
        let app = DemoLaunch.launch(
            openURL: "gethog://dashboard/\(DemoLaunch.dashboardID)",
            environment: ["GETHOG_DEMO_DASHBOARD_RECOMPUTE_FAILURE": "1"]
        )
        let tile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", DemoLaunch.firstTileTitle)
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: tile), "The cached dashboard never loaded.")

        app.buttons["Dashboard actions"].tap()
        let recompute = app.buttons["arrow.clockwise"].firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: recompute), "The recompute action was unavailable.")
        recompute.tap()

        let notice = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Couldn't recompute this dashboard.")
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: notice),
            "A failed explicit recompute did not leave a visible retry notice."
        )
        XCTAssertTrue(tile.exists, "A failed recompute removed the last good dashboard content.")
    }

    func testEmptyDashboardRecomputeFailureRemainsVisible() {
        let app = DemoLaunch.launch(
            openURL: "gethog://dashboard/\(Self.emptyDashboardID)",
            environment: ["GETHOG_DEMO_DASHBOARD_RECOMPUTE_FAILURE": "1"]
        )
        let empty = app.staticTexts["No tiles on this dashboard"]
        XCTAssertTrue(DemoLaunch.wait(for: empty), "The empty dashboard never loaded.")

        app.buttons["Dashboard actions"].tap()
        let recompute = app.buttons["arrow.clockwise"].firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: recompute), "The recompute action was unavailable.")
        recompute.tap()

        let notice = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Couldn't recompute this dashboard.")
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: notice),
            "An empty dashboard hid its failed recompute and retry notice."
        )
        XCTAssertTrue(empty.exists, "A failed recompute replaced the valid empty state.")
    }

    func testDashboardRangeAndInsightSurviveFourSizeClassCrossings() throws {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_OPEN_DASHBOARD": "first"]
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Example App metric 33"]),
            "The selected synthetic dashboard never opened."
        )
        guard app.tabBars.firstMatch.exists else {
            throw XCTSkip("This regression requires a compact Max-size iPhone that becomes regular in landscape.")
        }

        let month = app.buttons["30d"]
        XCTAssertTrue(DemoLaunch.wait(for: month), "The dashboard range picker did not render.")
        month.tap()
        XCTAssertTrue(
            DemoLaunch.wait { month.isSelected },
            "The 30-day range never became selected."
        )

        let tile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", DemoLaunch.firstTileTitle)
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: tile), "The first synthetic tile did not render.")
        tile.tap()
        XCTAssertTrue(
            DemoLaunch.wait {
                app.buttons["Done"].exists || app.buttons["Close insight"].exists
            },
            "Tapping the tile did not open its insight."
        )

        for stage in 1...4 {
            let widthBefore = app.windows.firstMatch.frame.width
            XCUIDevice.shared.orientation = stage.isMultiple(of: 2) ? .portrait : .landscapeLeft
            XCTAssertTrue(
                DemoLaunch.wait { app.windows.firstMatch.frame.width != widthBefore },
                "Crossing \(stage) never completed its window resize."
            )
            DemoLaunch.settle(app)
            DemoLaunch.pause(1)
            XCTAssertTrue(
                app.buttons["30d"].isSelected,
                "Crossing \(stage) reset the selected 30-day range."
            )
            XCTAssertTrue(
                app.buttons["Done"].exists || app.buttons["Close insight"].exists,
                "Crossing \(stage) dismissed the open dashboard insight."
            )
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
