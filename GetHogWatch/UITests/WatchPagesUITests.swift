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

    /// Empty flags mean the endpoint answered with no rows. A missing key or
    /// an in-flight first request has not answered that question yet and must
    /// never inherit the successful-empty sentence.
    func testFlagsStatesDistinguishNeedsKeyLoadingAndAnsweredEmpty() {
        guard ExclusiveRun.claim() else { return }

        let app = XCUIApplication()
        app.launchArguments = ["-GetHogDemo"]
        app.launchEnvironment["GETHOG_DEMO"] = "1"
        app.launchEnvironment["GETHOG_WATCH_PAGE"] = "flags"

        func launch(_ scenario: String) {
            app.terminate()
            app.launchEnvironment["GETHOG_WATCH_SCENARIO"] = scenario
            app.launch()
            XCTAssertTrue(
                DemoLaunch.wait(for: app.navigationBars["Flags"], timeout: 30),
                "The synthetic Flags page did not render for \(scenario)."
            )
        }

        let empty = app.staticTexts["No flags yet."]

        launch("no-credential")
        XCTAssertTrue(
            DemoLaunch.wait(
                for: app.staticTexts["Connect to PostHog first"], timeout: 5
            ),
            "Missing credentials were presented as answered-empty flags."
        )
        XCTAssertFalse(empty.exists)

        launch("flags-loading")
        let loading = app.staticTexts["Checking flags…"]
        XCTAssertTrue(
            DemoLaunch.wait(for: loading, timeout: 3),
            "The held first flag request did not expose progress."
        )
        XCTAssertFalse(empty.exists)
        let deterministicRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "example-navigation,")
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: deterministicRow, timeout: 30),
            "The held synthetic flag response never released its authored row."
        )

        launch("flags-empty")
        XCTAssertTrue(
            DemoLaunch.wait(for: empty, timeout: 30),
            "A successfully answered empty flag page did not render its empty state."
        )
        XCTAssertFalse(loading.exists)
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
