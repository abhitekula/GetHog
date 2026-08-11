import XCTest

/// A bounded, read-only authenticated sweep of the curated television shell.
///
/// Each destination receives a fresh process because tvOS focus cannot
/// reliably move from an arbitrary product root back into the sidebar. Stable
/// root identifiers prove page identity without recording customer-authored
/// titles or activating any row.
@MainActor
final class TVLivePATSurfaceTests: XCTestCase {
    private static let destinations = [
        "dashboards",
        "insights",
        "events",
        "sessions",
        "flags",
        "ambient",
        "settings",
    ]

    func testLivePATAllRootScreensRender() throws {
        try LiveCredentials.requireSweep()

        guard ExclusiveRun.claim() else { return }
        for destination in Self.destinations {
            let app = XCUIApplication()
            app.launchEnvironment = LiveCredentials.environment
            app.launchEnvironment["GETHOG_TAB"] = destination
            app.launch()

            let root = app.descendants(matching: .any)["gethog.tv.root.\(destination)"]
            XCTAssertTrue(
                DemoLaunch.wait(for: root, timeout: 60),
                "The live TV \(destination) root never rendered its stable anchor."
            )
            DemoLaunch.pause(0.75)
            XCTAssertTrue(
                LiveSurfaceState.waitForTerminalState(in: app, timeout: 60),
                "The live TV \(destination) root remained loading or failed."
            )
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "The app left the foreground while rendering live TV \(destination)."
            )
            app.terminate()
        }
    }
}
