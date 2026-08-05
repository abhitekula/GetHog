import XCTest

/// The welcome step's second door: entering the demo without a credential.
///
/// This is the one flow App Review walks — a reviewer has no PostHog account,
/// and the README promises the same path to anyone evaluating the app. Like
/// `OnboardingAccessibilityTests`, it launches plain: no `-GetHogDemo`, no
/// `GETHOG_API_KEY`, a real and empty `KeychainTokenStore`, so the demo entry
/// being exercised is the runtime one a Release build ships, not the
/// launch-argument one reserved for this test target.
final class DemoEntryTests: XCTestCase {

    func testWelcomeOffersTheDemoAndTapEntersIt() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Get started"]),
            "Onboarding's welcome step never appeared. If this simulator holds a "
                + "stored credential, the app launched past it."
        )

        let demoButton = app.buttons["Explore the demo"]
        XCTAssertTrue(
            demoButton.exists,
            "The welcome step offers no demo entry, so a reviewer with no "
                + "PostHog credential cannot see the app at all."
        )
        demoButton.tap()

        // The same signal `DemoLaunch.launch` waits on: a navigation bar means
        // a real screen came up behind the tab bar, i.e. the fixtures answered.
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars.firstMatch),
            "Tapping the demo entry never produced a screen."
        )
    }
}
