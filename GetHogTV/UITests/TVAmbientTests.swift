import XCTest

/// Ambient reads the App Group snapshot when it appears. Bootstrap writes that
/// snapshot after the shell is ready, so each test waits for Dashboards before
/// entering Ambient; launching straight there on a clean simulator is a race.
@MainActor
final class TVAmbientTests: XCTestCase {
    private func launchAndEnterAmbient() -> XCUIApplication {
        let app = DemoLaunch.launch()
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Example App metric 33"], timeout: 60))
        TVSidebar.select("Ambient", in: app)
        return app
    }

    private func wallboard(in app: XCUIApplication) -> XCUIElement {
        // The tab applies its root identifier outside Ambient's combined
        // accessibility element. tvOS correctly flattens that child into the
        // reachable tab-content node, so the stable destination root is the
        // user-observable wallboard contract.
        app.descendants(matching: .any)["gethog.tv.root.ambient"]
    }

    func testAmbientShowsAPinnedMetricAndReturnsOnMenu() {
        let app = launchAndEnterAmbient()
        let metric = wallboard(in: app)

        XCTAssertTrue(DemoLaunch.wait(for: metric, timeout: 60))
        XCTAssertNotEqual(metric.label, "Nothing pinned yet")
        XCTAssertTrue(
            metric.label.contains("Pinned dashboard"),
            "Ambient did not identify the pinned-dashboard provenance of its snapshot."
        )

        TVRemote.press(.menu)
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Example App metric 33"], timeout: 30))
    }

    func testAmbientReturnsOnSelect() {
        let app = launchAndEnterAmbient()
        XCTAssertTrue(DemoLaunch.wait(for: wallboard(in: app), timeout: 60))

        // Select is the wallboard's second documented exit, separate from the
        // Menu route above. Ambient consumes directional presses to cycle
        // metrics, so trying to focus an unrelated sidebar row from inside it
        // is not a real user path.
        TVRemote.press(.select)
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["Example App metric 33"], timeout: 30),
            "Select should release Ambient and return to Dashboards."
        )
    }

    func testAmbientCyclesOnARemotePress() {
        let app = launchAndEnterAmbient()
        let metric = wallboard(in: app)
        XCTAssertTrue(DemoLaunch.wait(for: metric, timeout: 60))
        let before = metric.label

        // `onMoveCommand` increments the wallboard's clock, cancelling and
        // restarting its 12-second tick task. The periodic auto-advance therefore
        // cannot satisfy this three-second manual-move observation window.
        TVRemote.press(.right)
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 3, until: { metric.exists && metric.label != before }),
            "Right did not change the wallboard metric inside the explicit three-second limit."
        )
    }
}
