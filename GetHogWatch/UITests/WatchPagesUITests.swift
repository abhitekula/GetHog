import XCTest

/// Direct-page launches keep each surface's render contract isolated. The
/// traversal contract below separately proves the real `.verticalPage`
/// interaction with a gesture aimed at the pager's trailing edge.
@MainActor
final class WatchPagesUITests: XCTestCase {
    func testRightEdgeSwipesTraverseEveryVerticalPage() {
        let app = DemoLaunch.launch()

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Example daily engagement"], timeout: 60))

        guard swipePager(in: app, until: app.staticTexts["Metric watches"], page: "Health") else {
            return XCTFail("Upward pager swipes did not move Metrics to Health.")
        }

        guard swipePager(in: app, until: app.staticTexts["First 10 flags"], page: "Flags") else {
            return XCTFail("Upward pager swipes did not move Health to Flags.")
        }

        guard swipePager(in: app, until: app.staticTexts["meteor_report_opened"], page: "Activity") else {
            return XCTFail("Upward pager swipes did not move Flags to Activity.")
        }
    }

    /// The trailing edge is outside the list rows' primary hit area, allowing
    /// the drag to reach the enclosing pager instead of scrolling nested Lists.
    /// The cap keeps a broken pager deterministic on both watch sizes.
    private func swipePager(
        in app: XCUIApplication,
        until destination: XCUIElement,
        page: String
    ) -> Bool {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.82))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.18))

        for attempt in 1...3 {
            start.press(
                forDuration: 0.05,
                thenDragTo: end,
                withVelocity: .fast,
                thenHoldForDuration: 0
            )
            if DemoLaunch.wait(for: destination, timeout: 3) {
                print("PAGER-TRAVERSAL page=\(page) swipes=\(attempt)")
                return true
            }
        }
        print("PAGER-TRAVERSAL page=\(page) swipes=3 result=miss")
        return false
    }

    func testMetricsPageShowsTheHeadlineAndItsDelta() {
        let app = DemoLaunch.launch(environment: ["GETHOG_WATCH_PAGE": "metrics"])

        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Starling Metrics Lab"], timeout: 60))
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Example daily engagement"], timeout: 30))
        XCTAssertTrue(DemoLaunch.wait(for: app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "55", "55")
        ).firstMatch, timeout: 30))
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "22.22%", "22.22%")
        ).firstMatch, timeout: 30))
    }

    func testHealthPageShowsTheWatchesAndTheErrorPulse() {
        let app = DemoLaunch.launch(environment: ["GETHOG_WATCH_PAGE": "health"])

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Metric watches"], timeout: 60))
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Errors, last 24 h"], timeout: 30))
        XCTAssertTrue(DemoLaunch.wait(for: app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Example daily engagement")
        ).firstMatch, timeout: 30))
    }

    func testFlagsPageShowsTheShortlist() {
        let app = DemoLaunch.launch(environment: ["GETHOG_WATCH_PAGE": "flags"])

        XCTAssertTrue(DemoLaunch.wait(for: app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "example-navigation,")
        ).firstMatch, timeout: 60))
    }

    func testActivityPageShowsRecentEvents() {
        let app = DemoLaunch.launch(environment: ["GETHOG_WATCH_PAGE": "activity"])

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["meteor_report_opened"], timeout: 60))
        let honestFooter = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Last 24 h", "No events in the last")
        ).firstMatch
        app.swipeUp()
        XCTAssertTrue(DemoLaunch.wait(for: honestFooter, timeout: 30))
        XCTAssertFalse(app.staticTexts["Not checked yet"].exists)
    }
}
