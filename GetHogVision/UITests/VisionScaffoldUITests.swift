import XCTest

/// A keyless Vision launch must show the onboarding flow, rather than merely
/// proving that the app's brand appears somewhere in its accessibility tree.
@MainActor
final class VisionScaffoldUITests: XCTestCase {
    func testKeylessLaunchOffersOnboarding() {
        let app = XCUIApplication()
        app.launchEnvironment["GETHOG_FORCE_KEYLESS"] = "1"
        app.launch()
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["GetHog"], timeout: 30))
        XCTAssertTrue(DemoLaunch.wait(for: app.buttons["Get started"], timeout: 30))
    }
}
