import XCTest

final class DashboardConsistencyUITests: XCTestCase {
    private static let emptyDashboardID = 725_103

    /// Catches a Dashboard landing change that restores separate signal and
    /// collection scroll containers instead of one regular-width dashboard hub.
    func testRegularDashboardLandingUsesOneHub() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The regular-width dashboard hub contract is measured on iPad."
        )

        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width > 700,
            "The app window is compact; this contract measures the regular-width dashboard landing."
        )

        let hubs = app.scrollViews.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-hub")
        )
        let hub = hubs.firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The regular dashboard landing did not expose gethog.dashboard-hub.")
        }
        XCTAssertEqual(hubs.count, 1, "The dashboard landing must expose exactly one hub.")
        guard hubs.count == 1 else { return }

        let projectSignal = hub.staticTexts["Project signal"].firstMatch
        let collections = hub.otherElements.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-collection")
        )
        let collection = collections.firstMatch
        guard DemoLaunch.wait(for: collection) else {
            return XCTFail("The dashboard hub did not contain gethog.dashboard-collection.")
        }
        XCTAssertEqual(collections.count, 1, "The dashboard hub must contain exactly one collection.")
        guard collections.count == 1 else { return }
        let collectionWidth = collection.frame.width

        let cards = hub.buttons.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-card.725101")
        )
        let card = cards.firstMatch
        // The project signal and pinned preview intentionally occupy the first
        // viewport. `LazyVGrid` creates the dashboard cards as they approach
        // it, so use a bounded scroll on the one hub surface before requiring
        // the descendant card.
        for _ in 0..<6 where !card.exists {
            hub.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        guard DemoLaunch.wait(for: card) else {
            return XCTFail("The dashboard hub did not contain gethog.dashboard-card.725101.")
        }
        XCTAssertEqual(cards.count, 1, "The dashboard hub must contain exactly one first dashboard card.")
        guard cards.count == 1 else { return }

        guard DemoLaunch.wait(for: projectSignal) else {
            return XCTFail("The dashboard hub did not contain the Project signal.")
        }
        XCTAssertGreaterThan(collectionWidth, hub.frame.width * 0.5)
        XCTAssertGreaterThanOrEqual(card.frame.minX, hub.frame.minX)
    }

    func testRegularDashboardReturnPreservesSearch() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The regular dashboard return contract is measured on iPad."
        )

        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width > 700,
            "The app window is compact; this contract measures regular-width navigation."
        )

        let query = "Example App metric 33"
        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The regular dashboard landing did not expose its hub.")
        }

        let search = app.searchFields.firstMatch
        if !search.exists {
            let searchButton = app.navigationBars["Dashboards"].buttons["Search"].firstMatch
            guard DemoLaunch.wait(for: searchButton) else {
                return XCTFail("The regular dashboard landing did not expose dashboard search.")
            }
            searchButton.tap()
        }
        guard DemoLaunch.wait(for: search) else {
            return XCTFail("The regular dashboard landing did not expose dashboard search.")
        }
        search.tap()
        search.typeText(query)

        let card = hub.buttons["gethog.dashboard-card.725101"].firstMatch
        for _ in 0..<6 where !(card.exists && card.frame.intersects(hub.frame)) {
            hub.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        guard DemoLaunch.wait(until: { card.exists && card.frame.intersects(hub.frame) }) else {
            return XCTFail("The searched dashboard card did not become visible in the regular hub.")
        }
        card.tap()

        let detail = app.navigationBars[query]
        guard DemoLaunch.wait(for: detail) else {
            return XCTFail("Selecting the regular dashboard card did not open its detail.")
        }
        let tile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", DemoLaunch.firstTileTitle)
        ).firstMatch
        guard DemoLaunch.wait(for: tile) else {
            return XCTFail("The opened dashboard detail did not render its synthetic tile.")
        }

        let allDashboards = app.buttons["All dashboards"]
        guard DemoLaunch.wait(for: allDashboards) else {
            return XCTFail("The regular dashboard detail did not provide an All dashboards return action.")
        }
        allDashboards.tap()

        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("Returning from dashboard detail did not restore the regular hub.")
        }
        let restoredSearch = app.searchFields.firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: restoredSearch), "Dashboard search did not return with the hub.")
        XCTAssertEqual(restoredSearch.value as? String, query)
    }

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
