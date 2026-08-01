import XCTest

/// Every screen `AppTab` names, photographed in demo mode.
///
/// Thirty-five cases, enumerated by hand rather than by reflection: the UI-test
/// target does not link the app module, so `AppTab.allCases` is not reachable
/// here, and the same is true of `AccessibilityAuditTests` next door. The cost is
/// that a new tab has to be added here too; the benefit is that a screen which
/// stops rendering fails under its own name.
///
/// The second argument is the screen's **own** navigation title and it is load
/// bearing — see `ScreenshotCase.captureRoot`.
final class RootScreenshotTests: ScreenshotCase {

    // MARK: The four primary tabs

    func testDashboards() { captureRoot("dashboards", titled: "Dashboards") }
    func testEvents() { captureRoot("events", titled: "Events") }
    func testSessions() { captureRoot("sessions", titled: "Sessions") }
    func testFlags() { captureRoot("flags", titled: "Flags") }

    // MARK: Search — the fifth tab, and the index of everything below

    func testSearch() { captureRoot("search", titled: "Search") }

    // MARK: Analyze

    func testInsights() { captureRoot("insights", titled: "Insights") }
    func testWebAnalytics() { captureRoot("webAnalytics", titled: "Web") }
    func testClickmap() { captureRoot("clickmap", titled: "Clickmap") }
    func testPeople() { captureRoot("people", titled: "People") }
    func testGroups() { captureRoot("groups", titled: "Groups") }
    func testSQL() { captureRoot("sql", titled: "SQL") }

    // MARK: Monitor

    func testErrorTracking() { captureRoot("errorTracking", titled: "Errors") }
    func testSessionSummaries() { captureRoot("sessionSummaries", titled: "Summaries") }
    func testLLM() { captureRoot("llm", titled: "LLM") }
    func testTracing() { captureRoot("tracing", titled: "Tracing") }
    func testLogs() { captureRoot("logs", titled: "Logs") }
    func testSupport() { captureRoot("support", titled: "Support") }
    func testInbox() { captureRoot("inbox", titled: "Inbox") }
    func testSignals() { captureRoot("signals", titled: "Signals") }
    func testHealth() { captureRoot("health", titled: "Health") }
    func testIngestion() { captureRoot("ingestion", titled: "Ingestion") }

    // MARK: Data

    func testWarehouse() { captureRoot("warehouse", titled: "Warehouse") }
    func testPipelines() { captureRoot("pipelines", titled: "Pipelines") }
    func testAutomation() { captureRoot("automation", titled: "Automation") }
    func testActions() { captureRoot("actions", titled: "Actions") }
    func testAnnotations() { captureRoot("annotations", titled: "Annotations") }
    func testTaxonomy() { captureRoot("taxonomy", titled: "Taxonomy") }

    // MARK: Experiment

    func testExperiments() { captureRoot("experiments", titled: "Experiments") }
    func testSurveys() { captureRoot("surveys", titled: "Surveys") }
    func testEarlyAccess() { captureRoot("earlyAccess", titled: "Early access") }

    // MARK: Workspace

    func testNotebooks() { captureRoot("notebooks", titled: "Notebooks") }
    func testMax() { captureRoot("max", titled: "Max") }
    func testRenders() { captureRoot("renders", titled: "Renders") }
    func testTemplates() { captureRoot("templates", titled: "Templates") }

    // MARK: Utility

    func testSettings() { captureRoot("settings", titled: "Settings") }

    // MARK: The screen demo mode cannot reach

    /// The first screen every real user sees, and the one no `-GetHogDemo`
    /// launch can photograph.
    ///
    /// Demo mode hands `AppModel` an `InMemoryTokenStore` already holding a
    /// credential, so `bootstrap()` finds one and the app is past onboarding
    /// before the first frame. This launches plain — no demo argument, no
    /// `GETHOG_API_KEY` — and therefore against a real, empty
    /// `KeychainTokenStore`. No request is made: the welcome step asks for
    /// nothing until a key is typed, so this still spends nothing from the
    /// organisation's shared rate-limit budget.
    ///
    /// Waiting on "Get started" rather than a navigation title is the guard as
    /// much as the sync: if this simulator does hold a credential from an earlier
    /// session the app comes up on Dashboards, and this records a failure rather
    /// than filing a picture of Dashboards under `onboarding`.
    func testOnboarding() {
        capture(
            launching: { Screenshot.launch($0, demo: false) },
            steps: [
                ScreenshotStep("onboarding") {
                    DemoLaunch.wait(for: $0.buttons["Get started"])
                }
            ]
        )
    }
}
