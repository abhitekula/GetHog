import XCTest

/// Proves the UI-test plumbing — runner, host app, launch — works on this
/// platform, and now that the launch lands on the real shell rather than a
/// placeholder.
///
/// Launched in demo mode because the alternative is the key-entry screen: a
/// clean simulator holds no credential, so an unadorned launch proves the
/// process started and nothing about the sidebar. "Dashboards" is the first
/// sidebar row and the default selection, so its presence is the shell
/// standing up end to end.
final class TVScaffoldUITests: XCTestCase {
    func testDemoShellLaunchesToTheSidebar() {
        let app = XCUIApplication()
        app.launchArguments += ["-GetHogDemo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Dashboards"].waitForExistence(timeout: 60))
    }
}
