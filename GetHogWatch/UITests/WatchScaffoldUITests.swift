import XCTest

/// The seed: proves the UI-test plumbing — runner, host app, launch — works
/// on this platform at all. Real coverage arrives with the real shell.
final class WatchScaffoldUITests: XCTestCase {
    func testPlaceholderShellLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["GetHog"].waitForExistence(timeout: 30))
    }
}
