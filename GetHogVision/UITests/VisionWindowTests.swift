import XCTest

@MainActor
final class VisionWindowTests: XCTestCase {
    func testSectionSidebarAdaptsToANarrowWindow() {
        let contentWidth: CGFloat = 640
        let app = DemoLaunch.launch(environment: [
            "GETHOG_VISION_CONTENT_WIDTH": String(Int(contentWidth)),
        ])

        let dashboard = app.staticTexts[DemoLaunch.firstTileTitle].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: dashboard),
            "The narrow Vision window did not leave the dashboard content usable."
        )

        // At this width a native split may collapse the product sidebar. If it
        // keeps both columns visible, the sidebar must negotiate below the old
        // fixed 280pt width rather than consuming almost half of the window.
        let sidebar = app.collectionViews["gethog.vision.section-sidebar"].firstMatch
        guard sidebar.exists && sidebar.isHittable else { return }
        XCTAssertLessThan(
            sidebar.frame.width,
            contentWidth * 0.4,
            "The section sidebar retained its fixed width in a narrow Vision window."
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
