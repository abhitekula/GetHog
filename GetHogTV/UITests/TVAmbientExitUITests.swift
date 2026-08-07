import XCTest

/// Drives the wallboard's way out with the remote.
///
/// The unit suite pins the *rule* that releases the idle timer
/// (`TVScreenAwakeTests`); this pins that the rule is actually reached — that
/// pressing Menu on the ambient screen runs `leave()` and lands back in the
/// sidebar, rather than being swallowed by the focusable full-screen content.
///
/// What no test in this process can observe is
/// `UIApplication.shared.isIdleTimerDisabled` itself: it lives in the app under
/// test, and XCUITest has no route to it. So the coverage is split on purpose —
/// this proves the exit path runs, and the unit tests prove that path releases.
final class TVAmbientExitUITests: XCTestCase {
    func testMenuLeavesTheWallboardForTheSidebar() {
        let app = XCUIApplication()
        app.launchArguments += ["-GetHogDemo"]
        app.launchEnvironment["GETHOG_TAB"] = "ambient"
        app.launch()

        // The wallboard is up: the sidebar row for it is the screen's title.
        XCTAssertTrue(
            app.staticTexts["Ambient"].waitForExistence(timeout: 60),
            "The ambient tab should be showing before Menu is pressed"
        )

        XCUIRemote.shared.press(.menu)

        // Back on the shell's default destination. `exit` routes to Dashboards.
        XCTAssertTrue(
            app.staticTexts["Dashboards"].waitForExistence(timeout: 30),
            "Menu on the wallboard should return to Dashboards, not exit the app"
        )
    }
}
