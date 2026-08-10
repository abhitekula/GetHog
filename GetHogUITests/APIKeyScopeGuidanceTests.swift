import XCTest

/// Keeps key creation honest about what the app needs immediately versus what a
/// person may deliberately grant for a later write.
///
/// A personal API key is created before the app can explain a later 403. Showing
/// a write permission in the first checklist therefore changes the customer's
/// security decision, not merely a label. The Settings screen and a locked
/// resource must make the same distinction after connection.
final class APIKeyScopeGuidanceTests: XCTestCase {

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

        let writeScope = DemoLaunch.elements(labelled: "feature_flag:write", in: app)
        XCTAssertEqual(
            writeScope.count,
            0,
            "Onboarding must not request feature_flag:write before the customer chooses a flag-changing action."
        )
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
    }
}
