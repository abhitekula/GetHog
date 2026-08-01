import XCTest

@MainActor
final class BrandedEmptyStateAccessibilityTests: XCTestCase {
    func testBrandedEmptyDashboards() throws {
        try auditEmptyState(tab: "dashboards", title: "No dashboards")
    }

    func testBrandedEmptyInsights() throws {
        try auditEmptyState(tab: "insights", title: "No saved insights")
    }

    func testBrandedEmptySessions() throws {
        try auditEmptyState(tab: "sessions", title: "No sessions")
    }

    func testBrandedWorkspaceActionRemainsReachableAtAX5() {
        let app = DemoLaunch.launch(
            tab: "annotations",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["No annotations"]))

        let action = app.buttons["Write one"]
        for _ in 0..<8 where !action.isHittable {
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        XCTAssertTrue(
            action.isHittable,
            "The branded workspace action must remain reachable at AX5."
        )
    }

    private func auditEmptyState(tab: String, title: String) throws {
        let app = DemoLaunch.launch(
            tab: tab,
            environment: ["GETHOG_DEMO_EMPTY_COLLECTION": tab]
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts[title]),
            "The forced-empty \(tab) screen never rendered its expected title."
        )
        DemoLaunch.settle(app)
        let leakedAssets = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "BrandEmpty"))
        XCTAssertEqual(
            leakedAssets.count,
            0,
            "Decorative illustration asset names must not enter the accessibility tree."
        )
        // These are the two audit classes measured as strict across GetHog's
        // existing rendered sweep. The other classes flag system search fields,
        // antialiased ink, and supported partial Dynamic Type ranges here too.
        try app.performAccessibilityAudit(for: [
            .sufficientElementDescription,
            .trait,
        ])
    }
}
