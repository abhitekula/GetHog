import XCTest

/// The two workflows added to the saved-insight screen, driven in the real app.
///
/// Neither can be seen any other way. `ImageRenderer` draws no `Menu`, no real
/// `.sheet` presentation and nothing inside a `List` — and both of these are a
/// menu item opening a sheet containing a list, so a render test of them would
/// produce the system placeholder and prove nothing. This target can pass
/// `-GetHogDemo`, so it is where these get looked at.
///
/// **One test method per screen**, for the reason `AccessibilityAuditTests`
/// records: a single method launching the app repeatedly takes the runner down
/// partway through rather than failing.
final class AlertAndNarrowingTests: XCTestCase {

    /// The first row of `insights_list.json`, and the insight `alerts.json`'s
    /// firing alert points at.
    private static let insightTitle = "Example meteor report"

    /// The two rows in `alerts.json`. The first is firing and awake, the second
    /// snoozed and paused — the pair the row's state logic has to tell apart.
    private static let firingAlertName = "Harbor trials below floor"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Opening an insight's alerts, and finding the workflow's controls on it.
    func testInsightAlertsSheet() {
        let app = openInsight()

        openMenuItem("Alerts", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Alerts"]),
            "The alerts sheet never came up."
        )
        DemoLaunch.settle(app)

        // The alert itself, from the schema-derived fixture. Its `_note` records
        // that the authored alert contract provides this row, so it is the only
        // way the workflow is visible at all.
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts[Self.firingAlertName], timeout: 10),
            "The firing alert did not render. Demo alerts screen: \(app.debugDescription.prefix(2000))"
        )

        // Who gets told — the fact this screen exists to state, and the one the
        // alert row could not carry before `subscribed_users` was decoded.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Alex Example'"))
                .firstMatch.exists,
            "The row never said who PostHog e-mails."
        )

        // Labelled buttons, never a swipe — the rule every write in this app
        // follows. Both have to be present *and* reachable by a fingertip.
        let snooze = app.buttons["Snooze \(Self.firingAlertName)"]
        XCTAssertTrue(DemoLaunch.wait(for: snooze, timeout: 5), "No snooze control on the row.")
        snooze.assertMeetsMinimumHitTarget("the snooze menu")

        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.exists, "No pause control on the row.")
        pause.assertMeetsMinimumHitTarget("the pause button")

        // A snooze must name the alert and the duration before it happens. The
        // menu is opened rather than the write being made: this run is read-only
        // by construction (`DemoTransport`), but the dialog is the contract.
        snooze.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Until tomorrow"], timeout: 5),
            "The snooze menu offered no durations. \(app.debugDescription.prefix(1500))"
        )
        // "Until tomorrow", not "24 hours": PostHog truncates a `1d` snooze to the
        // start of the next UTC day, so the label names where it lands.
        XCTAssertFalse(
            app.buttons["24 hours"].exists,
            "A duration label promised a flat 24 hours, which the server does not give."
        )
    }

    /// Opening the narrowing sheet, and finding the two controls on it.
    func testInsightNarrowSheet() {
        let app = openInsight()

        openMenuItem("Filter or split", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Narrow"]),
            "The narrowing sheet never came up."
        )
        DemoLaunch.settle(app)

        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Add a filter"], timeout: 10),
            "No way to add a filter. \(app.debugDescription.prefix(2000))"
        )
        app.buttons["Add a filter"].assertMeetsMinimumHitTarget("the add-filter button")

        // The cost statement, which is the thing this sheet has to say out loud:
        // one query per Apply, against a budget the organisation shares.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'one query'"))
                .firstMatch.exists,
            "The sheet never stated what applying costs."
        )

        // Apply is inert until something changes, so a reader cannot spend a
        // request reproducing what is already on screen.
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.exists, "No Apply control.")
        XCTAssertFalse(apply.isEnabled, "Apply was live with nothing asked for.")
    }

    // MARK: - Harness

    /// Launches into the insight library and opens the first insight.
    ///
    /// Reached by tapping rather than by launch environment because there is no
    /// variable for one insight — `GETHOG_OPEN_TILE` opens a dashboard tile,
    /// which is a different screen with a different toolbar.
    private func openInsight() -> XCUIApplication {
        let app = DemoLaunch.launch(tab: "insights")
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Insights"]),
            "The insight library never came up."
        )
        DemoLaunch.settle(app)

        let row = app.staticTexts[Self.insightTitle].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: row, timeout: 15),
            "The demo insight was not in the library. \(app.debugDescription.prefix(2000))"
        )
        row.tap()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars[Self.insightTitle], timeout: 15),
            "The insight detail screen never came up."
        )
        DemoLaunch.settle(app)
        return app
    }

    /// Opens the detail screen's overflow menu and taps one item.
    private func openMenuItem(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons["Insight actions"]
        XCTAssertTrue(DemoLaunch.wait(for: menu, timeout: 10), "No actions menu on the insight.")
        menu.tap()

        let item = app.buttons[title]
        XCTAssertTrue(
            DemoLaunch.wait(for: item, timeout: 10),
            "The menu had no “\(title)” item. \(app.debugDescription.prefix(2000))"
        )
        item.tap()
    }
}

/// The regular-width library overview is both an information surface and a
/// navigation source. This class stays in the existing Insights UI-test file so
/// adding it does not require regenerating the project during a serialized run.
final class InsightsOverviewUITests: XCTestCase {
    func testRegularOverviewUsesTheDetailPaneAndOpensItsKindRepresentative() throws {
        let app = DemoLaunch.launch(tab: "insights")
        defer { app.terminate() }

        guard DemoLaunch.wait(for: app.navigationBars["Insights"]) else {
            return XCTFail("The insight library never came up.")
        }
        DemoLaunch.settle(app)

        let overview = app.scrollViews["gethog.insights-overview"].firstMatch
        if app.windows.firstMatch.frame.width <= 700 {
            XCTAssertFalse(
                overview.exists,
                "The compact host mounted a second navigation surface in its content."
            )
            XCTAssertTrue(app.staticTexts["Example meteor report"].firstMatch.exists)
            return
        }

        guard DemoLaunch.wait(for: overview) else {
            return XCTFail("The regular Insights detail pane did not expose its overview.")
        }
        let summary = app.descendants(matching: .any)["gethog.signal-summary.insights"].firstMatch
        let trends = app.descendants(matching: .any)[
            "gethog.insights-overview.kind.trends"
        ].firstMatch
        guard DemoLaunch.wait(for: summary), DemoLaunch.wait(for: trends) else {
            return XCTFail("The overview did not expose its summary and kind navigation.")
        }

        print(
            "iPad Insights overview geometry: window=\(app.windows.firstMatch.frame), "
                + "overview=\(overview.frame), summary=\(summary.frame), trends=\(trends.frame)"
        )
        capture("iPad Insights overview \(Int(overview.frame.width))pt")

        XCTAssertGreaterThan(summary.frame.minX, app.windows.firstMatch.frame.width * 0.35)
        XCTAssertGreaterThan(summary.frame.width, app.windows.firstMatch.frame.width * 0.5)
        XCTAssertEqual(trends.frame.minX, summary.frame.minX, accuracy: 16)
        XCTAssertEqual(trends.frame.width, summary.frame.width, accuracy: 16)
        XCTAssertTrue(summary.staticTexts["4 insights."].exists)
        XCTAssertTrue(overview.staticTexts["Kinds represented"].exists)
        XCTAssertFalse(app.staticTexts["Pick an insight"].exists)

        trends.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Example meteor report"]),
            "The Trends overview row did not open its newest loaded insight."
        )
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
