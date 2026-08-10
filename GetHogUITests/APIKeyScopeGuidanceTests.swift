import XCTest

/// Keeps key creation honest about what the app needs immediately versus what a
/// person may deliberately grant for a later write.
///
/// A personal API key is created before the app can explain a later 403. Showing
/// a write permission in the first checklist therefore changes the customer's
/// security decision, not merely a label. The Settings screen and a locked
/// resource must make the same distinction after connection.
@MainActor
final class APIKeyScopeGuidanceTests: XCTestCase {

    /// Independently derived from the production call-site inventory. Keeping
    /// these literals outside GetHogKit means the rendered checklist cannot pass
    /// by using the same builder as its expectation.
    private static let coreReadScopes = [
        "dashboard:read",
        "insight:read",
        "query:read",
        "session_recording:read",
        "feature_flag:read",
        "project:read",
    ]

    private static let optionalWriteScopes = [
        "feature_flag:write",
        "alert:write",
        "annotation:write",
        "error_tracking:write",
        "experiment:write",
        "survey:write",
    ]

    /// `LabeledContent` exposes each visible pair as one customer-readable
    /// accessibility label. These expected rows remain independent of the
    /// production catalog so an action, scope, omission, or extra row drifts
    /// this rendered contract.
    private static let optionalWriteRows = [
        "Toggle feature flags and change rollouts, feature_flag:write",
        "Create, change, and snooze alerts, alert:write",
        "Create annotations, annotation:write",
        "Triage error issues, error_tracking:write",
        "End, pause, or resume experiments, experiment:write",
        "Launch, stop, or resume surveys, survey:write",
    ]

    func testOnboardingOffersOnlyCoreReadScopes() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Get started"]),
            "Onboarding's welcome step never appeared. A stored credential must not turn this into a test of another screen."
        )
        app.buttons["Get started"].tap()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Continue"]),
            "The region step never appeared after Get started."
        )
        app.buttons["Continue"].tap()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["Core read scopes"]),
            "The key entry must identify its checklist as the least-privilege read baseline."
        )

        let renderedCoreScopes = Set(
            app.staticTexts.matching(
                NSPredicate(format: "label ENDSWITH %@", ":read")
            ).allElementsBoundByIndex.map(\.label)
        )
        XCTAssertEqual(
            renderedCoreScopes,
            Set(Self.coreReadScopes),
            "Onboarding did not render exactly the independently inventoried core-read list."
        )

        for scope in Self.optionalWriteScopes {
            XCTAssertEqual(
                app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", scope)
                ).count,
                0,
                "Onboarding must not request the optional \(scope) grant."
            )
        }
    }

    func testSettingsSeparatesOptionalWritesFromCoreReads() {
        let app = DemoLaunch.launch(tab: "settings")
        let optionalWrites = DemoLaunch.elements(labelled: "Optional write actions", in: app).firstMatch

        // Permissions sits below Account and Project in the Settings list. A
        // List does not publish its below-fold rows into the rendered tree, so
        // scrolling is part of reaching this customer-visible guidance rather
        // than an implementation detail the assertion can skip.
        for _ in 0 ..< 3 where !optionalWrites.exists {
            app.swipeUp()
        }

        XCTAssertTrue(
            DemoLaunch.wait(for: optionalWrites),
            "Settings must identify write permissions as optional instead of presenting them as core access."
        )

        let firstScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        firstScreenshot.name = "Settings optional write guidance start"
        firstScreenshot.lifetime = .keepAlways
        add(firstScreenshot)

        let visibleWriteRows = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", ":write")
        )
        let nextSection = DemoLaunch.elements(labelled: "API key", in: app).firstMatch
        var renderedRows = Set<String>()
        for _ in 0 ..< 8 {
            renderedRows.formUnion(visibleWriteRows.allElementsBoundByIndex.map(\.label))
            if nextSection.exists { break }
            app.swipeUp()
        }

        let lastScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        lastScreenshot.name = "Settings optional write guidance end"
        lastScreenshot.lifetime = .keepAlways
        add(lastScreenshot)

        XCTAssertEqual(
            renderedRows,
            Set(Self.optionalWriteRows),
            "Settings did not render exactly the independently inventoried optional-write rows."
        )
    }
}
