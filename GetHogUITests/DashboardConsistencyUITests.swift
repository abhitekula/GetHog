import UIKit
import XCTest

final class DashboardConsistencyUITests: XCTestCase {
    private static let emptyDashboardID = 725_103

    func testCompactDashboardCardPublishesADataFreeIdentifier() throws {
        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width <= 700,
            "The compact dashboard row contract is measured on a compact window."
        )
        let card = app.buttons["gethog.dashboard-card.725101"].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: card, timeout: 60),
            "The compact dashboard collection did not publish its data-free card identifier."
        )
    }

    func testCompactDashboardNavigationRowDrawsOneDisclosureIndicator() throws {
        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width <= 700,
            "The compact disclosure contract is measured on a compact window."
        )
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Example App metric 33")
        ).firstMatch
        guard DemoLaunch.wait(for: row, timeout: 60) else {
            return XCTFail("The compact dashboard row never rendered.")
        }

        let screenshot = XCUIScreen.main.screenshot()
        XCTAssertEqual(
            try trailingInkClusterCount(
                in: screenshot,
                rowFrame: row.frame,
                screenFrame: app.frame
            ),
            1,
            "A NavigationLink row must draw only its native disclosure indicator."
        )
    }

    func testPinnedDashboardPreviewFailureIsVisibleAndRetryable() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The pinned dashboard preview belongs to the regular-width dashboard hub."
        )

        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_DEMO_DASHBOARD_DETAIL_FAILURE": "1"]
        )
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width > 700,
            "The app window is compact; compact Dashboards intentionally renders its collection."
        )

        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The regular dashboard landing did not expose its hub.")
        }
        let preview = hub.descendants(matching: .any)[
            "gethog.dashboard-pinned-preview"
        ].firstMatch
        guard DemoLaunch.wait(for: preview) else {
            return XCTFail("The regular dashboard hub did not expose its pinned preview.")
        }

        let failure = preview.staticTexts["Couldn't load pinned dashboard preview"]
        XCTAssertTrue(
            DemoLaunch.wait(for: failure),
            "A failed pinned preview collapsed into a blank Pinned section."
        )
        XCTAssertTrue(preview.staticTexts["Pinned"].firstMatch.exists)
        XCTAssertTrue(preview.buttons["Try again"].firstMatch.exists)
        XCTAssertFalse(
            preview.staticTexts[DemoLaunch.firstTileTitle].firstMatch.exists,
            "A failed pinned preview left stale chart content under its retry state."
        )
        capture("Pinned dashboard preview failure")
    }

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

    func testRegularDashboardLoadingUsesTheAppGround() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The regular dashboard loading state is measured on iPad."
        )

        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_DEMO_DASHBOARD_LIST_DELAY_MS": "5000"]
        )
        let loading = app.staticTexts["Loading dashboards…"].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: loading, timeout: 3),
            "The delayed collection never exposed its regular-width loading state."
        )

        let screenshot = XCUIScreen.main.screenshot()
        let frame = app.frame
        let sample = try pixel(
            in: screenshot,
            at: CGPoint(x: frame.minX + frame.width * 0.75, y: frame.minY + frame.height * 0.75),
            screenFrame: frame
        )
        let lightGround = (red: 242, green: 239, blue: 233)
        let darkGround = (red: 21, green: 20, blue: 19)
        XCTAssertTrue(
            sample.matches(lightGround) || sample.matches(darkGround),
            "Regular dashboard loading sampled \(sample), not the app ground."
        )
    }

    /// The regular hub must not accept a side-by-side project summary if doing
    /// so leaves its pinned preview too narrow for the two readable columns the
    /// preview promises.
    func testRegularDashboardPinnedPreviewUsesTwoColumns() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The pinned-preview width contract is measured on iPad."
        )

        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width > 700,
            "The app window is compact; this contract measures the regular-width hub."
        )

        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The regular dashboard landing did not expose its hub.")
        }
        let projectSummaries = hub.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-project-summary")
        )
        let projectSummary = projectSummaries.firstMatch
        let pinnedPreviews = hub.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-pinned-preview")
        )
        let pinnedPreview = pinnedPreviews.firstMatch
        let firstCards = hub.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-pinned-tile.77021")
        )
        let firstCard = firstCards.firstMatch
        let secondCards = hub.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-pinned-tile.700009")
        )
        let secondCard = secondCards.firstMatch
        guard DemoLaunch.wait(for: firstCard) else {
            return XCTFail("The regular dashboard hub did not expose its first pinned card frame.")
        }
        guard DemoLaunch.wait(for: secondCard) else {
            return XCTFail("The regular dashboard hub did not expose its second pinned card frame.")
        }
        guard DemoLaunch.wait(for: projectSummary) else {
            return XCTFail("The regular dashboard hub did not expose its project-summary geometry.")
        }
        guard DemoLaunch.wait(for: pinnedPreview) else {
            return XCTFail("The regular dashboard hub did not expose its pinned-preview geometry.")
        }

        XCTAssertEqual(projectSummaries.count, 1)
        XCTAssertEqual(pinnedPreviews.count, 1)
        XCTAssertEqual(firstCards.count, 1)
        XCTAssertEqual(secondCards.count, 1)
        XCTAssertTrue(projectSummary.staticTexts["Project signal"].firstMatch.exists)
        XCTAssertTrue(pinnedPreview.staticTexts["Pinned"].firstMatch.exists)
        XCTAssertTrue(firstCard.staticTexts[DemoLaunch.firstTileTitle].firstMatch.exists)
        XCTAssertTrue(secondCard.staticTexts["Example daily engagement"].firstMatch.exists)

        print(
            "iPad dashboard geometry: hub=\(hub.frame), summary=\(projectSummary.frame), "
                + "preview=\(pinnedPreview.frame), first=\(firstCard.frame), second=\(secondCard.frame)"
        )
        capture("iPad Dashboard \(Int(hub.frame.width))pt")

        XCTAssertGreaterThan(
            projectSummary.frame.width,
            hub.frame.width * 0.75,
            "The project summary did not span the regular dashboard hub."
        )
        XCTAssertGreaterThanOrEqual(
            pinnedPreview.frame.minY,
            projectSummary.frame.maxY - 12,
            "The pinned preview rendered beside or above the project summary."
        )
        XCTAssertLessThanOrEqual(
            pinnedPreview.frame.minY,
            projectSummary.frame.maxY + 28,
            "The pinned preview left an excessive gap below the project summary."
        )
        XCTAssertGreaterThan(
            pinnedPreview.frame.width,
            hub.frame.width * 0.75,
            "The pinned preview did not span the regular dashboard hub."
        )
        XCTAssertEqual(
            firstCard.frame.minX,
            pinnedPreview.frame.minX,
            accuracy: 12,
            "The first pinned card did not start at the preview's leading edge."
        )
        XCTAssertEqual(
            secondCard.frame.maxX,
            pinnedPreview.frame.maxX,
            accuracy: 12,
            "The second pinned card did not reach the preview's trailing edge."
        )
        XCTAssertEqual(
            firstCard.frame.width,
            secondCard.frame.width,
            accuracy: 12,
            "The first preview row did not use equal chart columns."
        )
        XCTAssertGreaterThanOrEqual(firstCard.frame.width, 230)
        XCTAssertGreaterThanOrEqual(secondCard.frame.width, 230)
        XCTAssertGreaterThan(firstCard.frame.height, 200)
        XCTAssertGreaterThan(secondCard.frame.height, 200)
        XCTAssertEqual(
            firstCard.frame.minY,
            secondCard.frame.minY,
            accuracy: 12,
            "The first two pinned tiles stacked into one narrow column on regular iPad."
        )
        XCTAssertGreaterThan(
            secondCard.frame.minX,
            firstCard.frame.maxX,
            "The second pinned tile did not occupy a second column beside the first."
        )
        XCTAssertEqual(
            secondCard.frame.maxX - firstCard.frame.minX,
            pinnedPreview.frame.width,
            accuracy: 12,
            "The first preview row did not cover the full pinned-preview width."
        )
        try app.performAccessibilityAudit(for: [
            .sufficientElementDescription,
            .trait,
        ])
    }

    func testRegularDashboardAX5KeepsFirstSignalInInitialViewport() throws {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width > 700,
            "This contract requires a regular-width proposal, independent of device identity."
        )

        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The AX5 dashboard did not expose its regular-width hub.")
        }
        let projectSummary = hub.descendants(matching: .any)[
            "gethog.dashboard-project-summary"
        ].firstMatch
        let pinnedPreview = hub.descendants(matching: .any)[
            "gethog.dashboard-pinned-preview"
        ].firstMatch
        let firstCard = hub.descendants(matching: .any)[
            "gethog.dashboard-pinned-tile.77021"
        ].firstMatch
        let secondCard = hub.descendants(matching: .any)[
            "gethog.dashboard-pinned-tile.700009"
        ].firstMatch
        let projectTitle = hub.staticTexts["Starling Metrics Lab"].firstMatch
        let dashboards = DemoLaunch.elements(labelled: "Dashboards, 11", in: app).firstMatch
        for (element, name) in [
            (projectSummary, "project summary"),
            (pinnedPreview, "pinned preview"),
            (firstCard, "first pinned card"),
            (secondCard, "second pinned card"),
            (projectTitle, "project title"),
            (dashboards, "Dashboards metric"),
        ] {
            guard DemoLaunch.wait(for: element) else {
                return XCTFail("The AX5 dashboard did not expose its \(name).")
            }
        }

        capture("iPad AX5 Dashboard \(Int(hub.frame.width))pt")

        XCTAssertGreaterThanOrEqual(
            dashboards.frame.minY,
            projectTitle.frame.maxY - 12,
            "The summary did not use its vertical fallback at AX5."
        )
        XCTAssertGreaterThanOrEqual(pinnedPreview.frame.minY, projectSummary.frame.maxY - 12)
        XCTAssertLessThanOrEqual(pinnedPreview.frame.minY, projectSummary.frame.maxY + 28)
        XCTAssertEqual(firstCard.frame.minX, pinnedPreview.frame.minX, accuracy: 12)
        XCTAssertEqual(secondCard.frame.minX, pinnedPreview.frame.minX, accuracy: 12)
        XCTAssertEqual(firstCard.frame.width, pinnedPreview.frame.width, accuracy: 12)
        XCTAssertEqual(secondCard.frame.width, pinnedPreview.frame.width, accuracy: 12)
        XCTAssertGreaterThanOrEqual(firstCard.frame.width, 230)
        XCTAssertGreaterThanOrEqual(
            secondCard.frame.minY,
            firstCard.frame.maxY - 12,
            "The AX5 preview did not collapse to one readable chart column."
        )
        XCTAssertLessThanOrEqual(
            firstCard.frame.maxY,
            hub.frame.maxY,
            "The first pinned signal is not completely visible in the initial AX5 viewport."
        )
        try app.performAccessibilityAudit(for: [
            .sufficientElementDescription,
            .trait,
        ])
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

        let nativeBack = app.buttons["BackButton"].firstMatch
        guard DemoLaunch.wait(for: nativeBack, timeout: 5) else {
            return XCTFail("The regular dashboard detail did not provide its native Back control.")
        }
        XCTAssertTrue(nativeBack.isHittable, "The native dashboard Back control is not tappable.")
        nativeBack.tap()

        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("Returning from dashboard detail did not restore the regular hub.")
        }
        let restoredSearch = app.searchFields.firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: restoredSearch), "Dashboard search did not return with the hub.")
        XCTAssertEqual(restoredSearch.value as? String, query)
    }

    /// A search miss is local collection state: it must not replace the project
    /// signal or reintroduce a second regular-width dashboard surface.
    func testRegularDashboardSearchEmptyKeepsOneHub() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The regular dashboard search-empty contract is measured on iPad."
        )

        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width > 700,
            "The app window is compact; this contract measures the regular-width hub."
        )

        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The regular dashboard landing did not expose its hub.")
        }
        let search = app.searchFields.firstMatch
        if !search.exists {
            let searchButton = app.navigationBars["Dashboards"].buttons["Search"].firstMatch
            guard DemoLaunch.wait(for: searchButton) else {
                return XCTFail("The regular dashboard hub did not expose dashboard search.")
            }
            searchButton.tap()
        }
        guard DemoLaunch.wait(for: search) else {
            return XCTFail("The regular dashboard hub did not expose dashboard search.")
        }
        search.tap()
        search.typeText("unmatched synthetic dashboard title")

        let noMatches = hub.staticTexts["No matching dashboards"].firstMatch
        guard DemoLaunch.wait(for: noMatches) else {
            return XCTFail("A regular dashboard search miss did not render its local no-results state.")
        }
        let collections = hub.otherElements.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-collection")
        )
        XCTAssertEqual(collections.count, 1, "A search miss created another dashboard collection surface.")
        XCTAssertTrue(
            hub.staticTexts["Project signal"].firstMatch.exists,
            "A search miss replaced the project signal instead of only the dashboard collection."
        )
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

    /// A Max iPhone changes the dashboard host from the regular hub to the
    /// compact list. Selection belongs to `OpenDetails`, so the detail chosen
    /// from that list must remain selected when the hub host returns.
    func testDashboardSelectionSurvivesRegularCompactRegularTopology() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPhone")
                && deviceName.localizedCaseInsensitiveContains("Max"),
            "This topology crossing is unique to a Max-size iPhone."
        )

        let app = DemoLaunch.launch(tab: "dashboards")
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }

        let compactTabBar = app.tabBars.firstMatch
        guard DemoLaunch.wait(for: compactTabBar) else {
            throw XCTSkip("This Max iPhone did not start in the compact dashboard topology.")
        }
        XCTAssertFalse(
            app.scrollViews["gethog.dashboard-hub"].firstMatch.exists,
            "The compact dashboard topology mounted the regular-width hub."
        )

        let compactWidth = app.windows.firstMatch.frame.width
        XCUIDevice.shared.orientation = .landscapeLeft
        guard DemoLaunch.wait(until: { app.windows.firstMatch.frame.width != compactWidth }) else {
            return XCTFail("The Max iPhone never crossed into the regular dashboard topology.")
        }
        DemoLaunch.settle(app)

        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("Regular width did not expose the dashboard hub.")
        }

        let regularWidth = app.windows.firstMatch.frame.width
        XCUIDevice.shared.orientation = .portrait
        guard DemoLaunch.wait(until: { app.windows.firstMatch.frame.width != regularWidth }) else {
            return XCTFail("The regular dashboard hub never crossed back to compact width.")
        }
        DemoLaunch.settle(app)
        XCTAssertFalse(
            app.scrollViews["gethog.dashboard-hub"].firstMatch.exists,
            "Crossing back to compact width retained the regular-width hub."
        )

        let compactRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Example App metric 33")
        ).firstMatch
        guard DemoLaunch.wait(for: compactRow) else {
            return XCTFail("The compact dashboard list did not expose the deterministic dashboard row.")
        }
        compactRow.tap()

        let detail = app.navigationBars["Example App metric 33"]
        guard DemoLaunch.wait(for: detail) else {
            return XCTFail("Selecting the compact dashboard row did not open its detail.")
        }
        let selectedCompactWidth = app.windows.firstMatch.frame.width
        XCUIDevice.shared.orientation = .landscapeLeft
        guard DemoLaunch.wait(until: { app.windows.firstMatch.frame.width != selectedCompactWidth }) else {
            return XCTFail("The selected compact dashboard never crossed back to regular width.")
        }
        DemoLaunch.settle(app)

        XCTAssertTrue(
            DemoLaunch.wait(for: detail),
            "Returning to the regular dashboard host discarded the selected dashboard."
        )
        let nativeBack = app.buttons["BackButton"].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: nativeBack, timeout: 5),
            "Regular width did not preserve its native Back control for the retained selection."
        )
        XCTAssertTrue(nativeBack.isHittable, "The regular-width native Back control is not tappable.")
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

    private func pixel(
        in screenshot: XCUIScreenshot,
        at point: CGPoint,
        screenFrame: CGRect
    ) throws -> RGBPixel {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scaleX = CGFloat(image.width) / screenFrame.width
        let scaleY = CGFloat(image.height) / screenFrame.height
        let x = Int((point.x - screenFrame.minX) * scaleX)
        let y = Int((point.y - screenFrame.minY) * scaleY)
        let crop = try XCTUnwrap(
            image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        )
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBPixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }

    private func trailingInkClusterCount(
        in screenshot: XCUIScreenshot,
        rowFrame: CGRect,
        screenFrame: CGRect
    ) throws -> Int {
        let source = try XCTUnwrap(screenshot.image.cgImage)
        let scaleX = CGFloat(source.width) / screenFrame.width
        let scaleY = CGFloat(source.height) / screenFrame.height
        let sampleFrame = CGRect(
            x: rowFrame.maxX - 128,
            y: rowFrame.midY - 18,
            width: 112,
            height: 36
        )
        let cropRect = CGRect(
            x: (sampleFrame.minX - screenFrame.minX) * scaleX,
            y: (sampleFrame.minY - screenFrame.minY) * scaleY,
            width: sampleFrame.width * scaleX,
            height: sampleFrame.height * scaleY
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: source.width, height: source.height)
        )
        let crop = try XCTUnwrap(source.cropping(to: cropRect))
        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(rendered, "The dashboard row disclosure region could not be sampled.")
        guard rendered else { return 0 }

        var inkColumns: [Int] = []
        for x in 0 ..< width {
            var minimum = 1.0
            var maximum = 0.0
            for y in 0 ..< height {
                let index = ((y * width) + x) * 4
                let red = Double(pixels[index]) / 255
                let green = Double(pixels[index + 1]) / 255
                let blue = Double(pixels[index + 2]) / 255
                let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
            if maximum - minimum > 0.08 {
                inkColumns.append(x)
            }
        }

        var clusters = 0
        var previous: Int?
        for column in inkColumns {
            if previous.map({ column - $0 > 3 }) ?? true {
                clusters += 1
            }
            previous = column
        }
        return clusters
    }
}

private struct RGBPixel: CustomStringConvertible {
    let red: Int
    let green: Int
    let blue: Int

    func matches(_ expected: (red: Int, green: Int, blue: Int)) -> Bool {
        abs(red - expected.red) <= 3
            && abs(green - expected.green) <= 3
            && abs(blue - expected.blue) <= 3
    }

    var description: String { "rgb(\(red), \(green), \(blue))" }
}
