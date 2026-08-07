import XCTest

/// The DEBUG-only launch seam replaces the persistent credential store with an
/// empty in-memory one and a synthetic transport. A credential saved by a
/// manual run therefore cannot make this contract order-dependent.
@MainActor
final class TVKeyEntryTests: XCTestCase {
    func testKeylessLaunchOffersKeyEntry() {
        let app = XCUIApplication()
        app.launchEnvironment["GETHOG_FORCE_KEYLESS"] = "1"
        app.launch()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["Connect this Apple TV to PostHog"], timeout: 60),
            "The forced-keyless launch did not reach TV key entry."
        )
        XCTAssertTrue(DemoLaunch.wait(for: app.secureTextFields["Personal API key"], timeout: 30))
        XCTAssertTrue(DemoLaunch.wait(for: app.buttons["Browse the demo"], timeout: 30))
    }
}
