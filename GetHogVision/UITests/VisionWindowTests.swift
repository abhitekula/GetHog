import XCTest

@MainActor
final class VisionWindowTests: XCTestCase {
    /// Catches a Dashboard landing change that restores separate signal and
    /// collection scroll containers instead of one regular-width dashboard hub.
    func testDashboardLandingUsesOneRegularWidthHub() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_VISION_CONTENT_WIDTH": "1280"]
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

        let cards = hub.buttons.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-card.725101")
        )
        let card = cards.firstMatch
        guard DemoLaunch.wait(for: card) else {
            return XCTFail("The dashboard hub did not contain gethog.dashboard-card.725101.")
        }
        XCTAssertEqual(cards.count, 1, "The dashboard hub must contain exactly one first dashboard card.")
        guard cards.count == 1 else { return }

        guard DemoLaunch.wait(for: projectSignal) else {
            return XCTFail("The dashboard hub did not contain the Project signal.")
        }
        XCTAssertGreaterThan(collection.frame.width, hub.frame.width * 0.5)
        XCTAssertGreaterThanOrEqual(card.frame.minX, hub.frame.minX)
    }

    func testDashboardDetailNeverClaimsEmptyAcrossDelayedListFailure() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: [
                "GETHOG_DEMO_DASHBOARD_LIST_DELAY_MS": "2500",
                "GETHOG_DEMO_DASHBOARD_LIST_FAILURE": "1",
                "GETHOG_VISION_CONTENT_WIDTH": "1280",
            ]
        )

        let emptyTitles = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "No dashboards")
        )
        let loading = app.staticTexts["Loading dashboards…"].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 3, until: {
                loading.exists || emptyTitles.count > 0
            }),
            "The regular dashboard detail exposed neither loading nor its former false-empty state."
        )
        XCTAssertTrue(
            loading.exists,
            "The regular dashboard detail showed No dashboards while its list was still loading."
        )
        guard loading.exists else { return }
        XCTAssertEqual(
            emptyTitles.count,
            0,
            "The regular dashboard detail claimed the still-loading collection was empty."
        )
        XCTAssertGreaterThan(
            loading.frame.midX,
            app.windows.firstMatch.frame.midX,
            "The loading treatment rendered in the list rather than the detail pane."
        )

        let failures = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Couldn't load dashboards")
        )
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10, until: {
                failures.count == 1 && !loading.exists
            }),
            "The delayed list failure did not replace loading with one authoritative error."
        )
        XCTAssertEqual(
            emptyTitles.count,
            0,
            "The regular dashboard detail relabelled a failed collection as empty."
        )
        XCTAssertGreaterThan(
            failures.firstMatch.frame.midX,
            app.windows.firstMatch.frame.midX,
            "The failure treatment rendered in the list rather than the detail pane."
        )
    }

    func testEmptyDashboardCollectionShowsOneBrandedStateAtRegularWidth() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: [
                "GETHOG_DEMO_EMPTY_COLLECTION": "dashboards",
                "GETHOG_VISION_CONTENT_WIDTH": "1280",
            ]
        )

        let emptyTitles = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "No dashboards")
        )
        XCTAssertTrue(
            DemoLaunch.wait(until: { emptyTitles.count > 0 }),
            "The regular-width dashboard did not render its branded empty state."
        )
        DemoLaunch.settle(app)
        XCTAssertEqual(
            emptyTitles.count,
            1,
            "The regular split rendered the full dashboard empty state in more than one column."
        )
    }

    func testSectionSidebarAdaptsToANarrowWindow() {
        let contentWidth: CGFloat = 640
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: [
                "GETHOG_VISION_CONTENT_WIDTH": String(Int(contentWidth)),
            ]
        )

        let dashboard = app.staticTexts[DemoLaunch.firstTileTitle].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: dashboard),
            "The narrow Vision window did not leave the dashboard content usable."
        )

        // At this width a native split may collapse the product sidebar. If it
        // keeps both columns visible, the sidebar must negotiate below the old
        // fixed 280pt width rather than consuming almost half of the window.
        let sidebar = app.collectionViews["gethog.vision.section-sidebar"].firstMatch
        if sidebar.exists && sidebar.isHittable {
            XCTAssertLessThan(
                sidebar.frame.width,
                contentWidth * 0.4,
                "The section sidebar retained its fixed width in a narrow Vision window."
            )
        }

        // Never trust the roster's `isHittable` result as proof that it is on
        // top: visionOS retains covered split columns in the hierarchy. The
        // route bar must remain genuinely interactive at the narrow proposal.
        let events = VisionSidebar.destinationControl("Events", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                events.exists && events.isHittable
            }),
            "The narrow section did not leave a visible Events route control."
        )
        guard events.exists else { return }
        events.tap()
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                (events.value as? String) == "Selected"
            }),
            "The narrow route bar did not retain Events as its selection."
        )
        let eventFixture = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "meteor_report_opened",
                "meteor_report_opened"
            )
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: eventFixture),
            "The narrow route bar did not render the Events fixture."
        )
    }

    func testDashboardTearsOffIntoItsOwnWindow() {
        let app = DemoLaunch.launch()
        let analyzeSection = VisionSidebar.section("Analyze", in: app)
        guard DemoLaunch.wait(until: {
            analyzeSection.exists && analyzeSection.isHittable
        }) else {
            return XCTFail("The Vision sidebar did not offer its Analyze section.")
        }
        analyzeSection.tap()
        guard VisionSidebar.tap("Dashboards", in: app) else { return }

        // The exact title appears once in the detail pane and once inside the
        // dashboard-list row. The tappable row combines title and freshness in
        // one Button label, so select that behavior-bearing element directly.
        let dashboard = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Example App metric 33,"
        )).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: dashboard))
        dashboard.tap()
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts[DemoLaunch.firstTileTitle]))

        let startingWindows = app.windows.count
        app.buttons["Dashboard actions"].tap()
        // SwiftUI exposes popover actions as buttons on visionOS rather than
        // AppKit-style menu items. Match the user-facing action independent of
        // that platform implementation detail.
        let tearOff = DemoLaunch.elements(labelled: "Open in new window", in: app).firstMatch
        guard DemoLaunch.wait(for: tearOff) else {
            return XCTFail("Dashboard actions never offered Open in new window.")
        }
        tearOff.tap()

        XCTAssertTrue(
            DemoLaunch.wait(timeout: 30, until: {
                DemoLaunch.elements(labelled: DemoLaunch.firstTileTitle, in: app).count >= 2
            }),
            "The dashboard tile did not render in a second Vision window."
        )
        XCTAssertGreaterThanOrEqual(app.windows.count, startingWindows + 1)
    }
}
