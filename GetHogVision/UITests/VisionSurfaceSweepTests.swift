import XCTest

/// Launches every Vision catalog destination against deterministic demo data.
///
/// Navigation itself is covered through the real ornament and sidebar in
/// `VisionNavigationTests`. This sweep uses the DEBUG launch route deliberately:
/// each screen gets a clean process and a stable root-title assertion even when
/// another screen in its section fails. Screenshots are deliberately absent:
/// `XCUIScreen.main` returns a 1×1 black image on the Vision simulator, so an
/// XCTest attachment would look like evidence while containing no rendered UI.
@MainActor
final class VisionSurfaceSweepTests: XCTestCase {
    private struct Screen {
        let rawValue: String
        let title: String

        init(_ rawValue: String, _ title: String) {
            self.rawValue = rawValue
            self.title = title
        }
    }

    private static let analyze = [
        Screen("search", "Search"),
        Screen("dashboards", "Dashboards"),
        Screen("events", "Events"),
        Screen("sessions", "Sessions"),
        Screen("insights", "Insights"),
        Screen("webAnalytics", "Web"),
        Screen("clickmap", "Clickmap"),
        Screen("people", "People"),
        Screen("groups", "Groups"),
        Screen("sql", "SQL"),
    ]

    private static let monitor = [
        Screen("errorTracking", "Errors"),
        Screen("sessionSummaries", "Summaries"),
        Screen("llm", "LLM"),
        Screen("tracing", "Tracing"),
        Screen("logs", "Logs"),
        Screen("support", "Support"),
        Screen("inbox", "Inbox"),
        Screen("signals", "Signals"),
        Screen("health", "Health"),
        Screen("ingestion", "Ingestion"),
    ]

    private static let data = [
        Screen("warehouse", "Warehouse"),
        Screen("pipelines", "Pipelines"),
        Screen("automation", "Automation"),
        Screen("actions", "Actions"),
        Screen("annotations", "Annotations"),
        Screen("taxonomy", "Taxonomy"),
    ]

    private static let experiment = [
        Screen("flags", "Flags"),
        Screen("experiments", "Experiments"),
        Screen("surveys", "Surveys"),
        Screen("earlyAccess", "Early access"),
    ]

    private static let workspaceAndUtility = [
        Screen("notebooks", "Notebooks"),
        Screen("max", "Max"),
        Screen("renders", "Renders"),
        Screen("templates", "Templates"),
        Screen("settings", "Settings"),
    ]

    /// The UI runner cannot import the host app's internal `AppTab`. This is
    /// therefore the mirrored `AppTab.allCases` roster, and the invariant test
    /// below pins both its current count and the absence of duplicate raw ids.
    private static let allScreens =
        analyze + monitor + data + experiment + workspaceAndUtility

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testAnalyzeScreensRender() {
        sweep(Self.analyze)
    }

    func testMonitorScreensRender() {
        sweep(Self.monitor)
    }

    func testDataScreensRender() {
        sweep(Self.data)
    }

    func testExperimentScreensRender() {
        sweep(Self.experiment)
    }

    func testWorkspaceAndUtilityScreensRender() {
        sweep(Self.workspaceAndUtility)
    }

    func testMirroredRosterContains35UniqueDestinations() {
        XCTAssertEqual(
            Self.allScreens.count,
            35,
            "Update the Vision sweep whenever AppTab.allCases changes."
        )
        XCTAssertEqual(
            Set(Self.allScreens.map(\.rawValue)).count,
            35,
            "Every mirrored raw value must appear exactly once in the Vision sweep."
        )
    }

    private func sweep(_ screens: [Screen]) {
        for screen in screens {
            let app = DemoLaunch.launch(tab: screen.rawValue)
            let rootTitle = app.navigationBars[screen.title].firstMatch

            XCTAssertTrue(
                DemoLaunch.wait(for: rootTitle),
                "\(screen.title) never rendered its stable root title."
            )
            DemoLaunch.settle(app)
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "The app left the foreground while rendering \(screen.title)."
            )

            app.terminate()
        }
    }
}
