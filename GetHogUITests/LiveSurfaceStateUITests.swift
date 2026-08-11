import XCTest

/// Pins the data-free gate used by live root sweeps without spending a live
/// request. DemoTransport's delay and failure seams make each state repeatable.
@MainActor
final class LiveSurfaceStateUITests: XCTestCase {
    func testGateRejectsAnActiveLoadingState() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_DEMO_DASHBOARD_LIST_DELAY_MS": "5000"]
        )
        defer { app.terminate() }

        XCTAssertFalse(
            LiveSurfaceState.waitForTerminalState(in: app, timeout: 0.5),
            "The live gate accepted a dashboard whose request was still loading."
        )
    }

    func testGateRejectsAnAuthoredFailureState() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_DEMO_DASHBOARD_LIST_FAILURE": "1"]
        )
        defer { app.terminate() }

        XCTAssertFalse(
            LiveSurfaceState.waitForTerminalState(in: app, timeout: 5),
            "The live gate accepted the dashboard load-failure state."
        )
    }

    func testGateAcceptsACompletedTerminalState() {
        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        XCTAssertTrue(
            LiveSurfaceState.waitForTerminalState(in: app, timeout: 10),
            "The live gate rejected the completed dashboard list."
        )
    }
}
