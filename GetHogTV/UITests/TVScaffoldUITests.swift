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
@MainActor
final class TVScaffoldUITests: XCTestCase {
    func testDemoShellLaunchesToTheSidebar() {
        let app = DemoLaunch.launch()
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Dashboards"], timeout: 60))
    }

    func testDashboardLoadingIsAnnouncedBeforeTheCompactListHasRows() {
        let app = DemoLaunch.launch(environment: [
            "GETHOG_DEMO_DASHBOARD_LIST_DELAY_MS": "5000",
        ])

        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["Loading dashboards…"], timeout: 10),
            "The compact dashboard list rendered as an unlabelled empty skeleton while its request ran."
        )
    }
}
