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
    private indirect enum Witness {
        case text(String)
        case button(String)
        case identifier(String)
        case anyOf([Witness])
        case allOf([Witness])

        func isSatisfied(in app: XCUIApplication) -> Bool {
            switch self {
            case .text(let value):
                // SwiftUI combines `DataRow` and `ContentUnavailableView`
                // children into one accessibility label on visionOS. Match the
                // complete authored string inside that representation: the
                // witness copy remains exact, while the query does not assume
                // the visible `Text` survives as its own accessibility node.
                app.descendants(matching: .any)
                    .matching(NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@",
                        value,
                        value
                    ))
                    .firstMatch
                    .exists

            case .button(let label):
                app.buttons.matching(NSPredicate(
                    format: "label == %@ OR value == %@",
                    label,
                    label
                ))
                .firstMatch
                .exists

            case .identifier(let identifier):
                app.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .firstMatch
                    .exists

            case .anyOf(let witnesses):
                witnesses.contains { $0.isSatisfied(in: app) }

            case .allOf(let witnesses):
                witnesses.allSatisfy { $0.isSatisfied(in: app) }
            }
        }

        var expectation: String {
            switch self {
            case .text(let value):
                "exact text \(String(reflecting: value))"
            case .button(let label):
                "exact button \(String(reflecting: label))"
            case .identifier(let identifier):
                "identifier \(String(reflecting: identifier))"
            case .anyOf(let witnesses):
                "any of [\(witnesses.map(\.expectation).joined(separator: ", "))]"
            case .allOf(let witnesses):
                "all of [\(witnesses.map(\.expectation).joined(separator: ", "))]"
            }
        }
    }

    private enum Preparation {
        case selectMenu(pickerLabel: String, option: String)
        case revealText(String)
        case confirmThenReveal(initial: String, target: String)

        func perform(in app: XCUIApplication) -> Bool {
            switch self {
            case .selectMenu(let pickerLabel, let option):
                // Query the Picker through its stable accessibility label, not
                // the selected resource's text: that text is also rendered by
                // the section header and by the transient menu option. Vision
                // composes the Picker title with this custom label, so match
                // the stable label component on the button itself.
                let picker = app.buttons.matching(NSPredicate(
                    format: "label CONTAINS %@", pickerLabel
                )).firstMatch
                guard DemoLaunch.wait(until: {
                    picker.exists && picker.isHittable
                }) else {
                    return false
                }
                picker.tap()

                func exactHittableOption() -> XCUIElement? {
                    app.buttons.matching(NSPredicate(
                        format: "label == %@", option
                    )).allElementsBoundByIndex.first(where: { $0.isHittable })
                }
                guard DemoLaunch.wait(until: { exactHittableOption() != nil }),
                      let exactOption = exactHittableOption() else {
                    return false
                }
                exactOption.tap()

                // The captured Picker is the selection authority. A transient
                // Endpoints option or static heading cannot satisfy its value.
                return DemoLaunch.wait(until: {
                    picker.exists
                        && picker.isHittable
                        && (picker.value as? String) == option
                })

            case .revealText(let value):
                let witness = Witness.text(value)
                if witness.isSatisfied(in: app) {
                    return true
                }

                // The Support footer follows all nine deterministic demo rows,
                // so SwiftUI does not instantiate its accessibility node until
                // the list is scrolled. Keep the reveal action bounded while
                // retaining the exact authored copy as the terminal witness.
                for _ in 0..<12 {
                    app.swipeUp(velocity: .slow)
                    DemoLaunch.pause(0.25)
                    if witness.isSatisfied(in: app) {
                        return true
                    }
                }
                return false

            case .confirmThenReveal(let initial, let target):
                guard DemoLaunch.wait(until: {
                    Witness.text(initial).isSatisfied(in: app)
                }) else {
                    return false
                }
                if Witness.text(target).isSatisfied(in: app) {
                    return true
                }

                let collections = app.collectionViews.allElementsBoundByIndex
                guard let settingsList = collections.max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                }) else {
                    return false
                }

                // A List can discard its initial rows while instantiating later
                // ones, so prove the top witness before scrolling and retain
                // the later exact text as the terminal on-screen witness.
                for _ in 0..<12 {
                    settingsList.swipeUp(velocity: .slow)
                    DemoLaunch.pause(0.25)
                    if Witness.text(target).isSatisfied(in: app) {
                        return true
                    }
                }
                return false
            }
        }

        var expectation: String {
            switch self {
            case .selectMenu(let pickerLabel, let option):
                "select \(String(reflecting: option)) from \(String(reflecting: pickerLabel))"
            case .revealText(let value):
                "reveal exact text \(String(reflecting: value))"
            case .confirmThenReveal(let initial, let target):
                "confirm exact text \(String(reflecting: initial)), then reveal "
                    + "exact text \(String(reflecting: target))"
            }
        }
    }

    private struct Screen {
        let rawValue: String
        let title: String
        let preparation: Preparation?
        let witness: Witness

        init(
            _ rawValue: String,
            _ title: String,
            preparation: Preparation? = nil,
            witness: Witness
        ) {
            self.rawValue = rawValue
            self.title = title
            self.preparation = preparation
            self.witness = witness
        }
    }

    private static let analyze = [
        // `file_system.json` now names the authored recent dashboard
        // "Orbital operations". Keep this witness aligned with the object
        // index the Search screen actually renders, not the dashboard-list
        // fixture's unrelated "Example App metric 33" title.
        Screen("search", "Search", witness: .text("Orbital operations")),
        Screen(
            "dashboards",
            "Dashboards",
            witness: .allOf([
                .identifier("gethog.dashboard-hub"),
                .text("Project signal"),
            ])
        ),
        Screen("events", "Events", witness: .text("meteor_report_opened")),
        Screen("sessions", "Sessions", witness: .text("Alex Example")),
        Screen("insights", "Insights", witness: .text("Example meteor report")),
        Screen(
            "webAnalytics",
            "Web",
            witness: .anyOf([.text("Overview"), .text("No web traffic")])
        ),
        Screen(
            "clickmap",
            "Clickmap",
            witness: .anyOf([.text("Pages with a render"), .text("No clicks recorded")])
        ),
        Screen("people", "People", witness: .text("Sable Okafor")),
        Screen(
            "groups",
            "Groups",
            // `Harbor Analytics Lab` is one level deeper, after selecting a
            // group type. The root itself renders the authored type fixture.
            witness: .allOf([.text("Group types"), .text("Workspaces")])
        ),
        Screen("sql", "SQL", witness: .text("Run a query")),
    ]

    private static let monitor = [
        Screen(
            "errorTracking",
            "Errors",
            witness: .anyOf([.text("HarborRenderFault"), .text("No errors in this period")])
        ),
        Screen(
            "sessionSummaries",
            "Summaries",
            witness: .allOf([
                .text("AI summaries"),
                .text("The user refreshed the fictional dashboard widgets."),
            ])
        ),
        Screen(
            "llm",
            "LLM",
            witness: .anyOf([
                .text("Totals cover the traces on this page, not the whole period."),
                .text("No LLM traces"),
                .allOf([
                    .text("Traces by cost"),
                    .text("018f9000-000…"),
                ]),
            ])
        ),
        Screen(
            "tracing",
            "Tracing",
            witness: .anyOf([
                .text(
                    "One row per trace, showing its entry span. Tap for the spans inside it."
                ),
                .text("No spans"),
                .text("Tracing is locked"),
            ])
        ),
        Screen(
            "logs",
            "Logs",
            witness: .allOf([
                // The empty demo state has no row-list rotor. Its visible
                // filter is the button-styled "Errors only" toggle. SwiftUI's
                // accessibility element type is an implementation detail, so
                // query the authored text across all element types;
                // "Errors and fatals" names the rotor only when rows exist.
                .text("Errors only"),
                .anyOf([.text("No log lines"), .text("Logs is locked")]),
            ])
        ),
        Screen(
            "support",
            "Support",
            preparation: .revealText("Replies stay in PostHog"),
            witness: .anyOf([.text("Replies stay in PostHog"), .text("No support tickets")])
        ),
        Screen("inbox", "Inbox", witness: .text("Nothing to triage")),
        Screen("signals", "Signals", witness: .text("No reports yet")),
        Screen(
            "health",
            "Health",
            witness: .anyOf([
                .text("Nothing wrong"),
                .text("Active"),
                .text("Resolved"),
            ])
        ),
        Screen(
            "ingestion",
            "Ingestion",
            witness: .anyOf([
                .text("Quota limited wandering hedgehog"),
                .text("Ingestion looks clean"),
            ])
        ),
    ]

    private static let data = [
        Screen(
            "warehouse",
            "Warehouse",
            witness: .anyOf([
                .text("Sources"),
                .text("Tables"),
                .text("Nothing in the warehouse"),
            ])
        ),
        Screen("pipelines", "Pipelines", witness: .text("No pipelines")),
        Screen(
            "automation",
            "Automation",
            preparation: .selectMenu(pickerLabel: "Automation resource", option: "Endpoints"),
            witness: .allOf([
                .text("Usage"),
                .text(
                    "This project has no query endpoints, so there is nothing to have been called."
                ),
            ])
        ),
        Screen("actions", "Actions", witness: .text("No actions")),
        Screen("annotations", "Annotations", witness: .text("No annotations")),
        Screen(
            "taxonomy",
            "Taxonomy",
            // `$pageview` is absent from both current taxonomy fixtures;
            // `feature_used` is their first visible authored event row.
            witness: .text("feature_used")
        ),
    ]

    private static let experiment = [
        Screen("flags", "Flags", witness: .text("Example navigation preview")),
        Screen(
            "experiments",
            "Experiments",
            witness: .text("Example cache strategy trial")
        ),
        Screen("surveys", "Surveys", witness: .text("Example App metric 829")),
        Screen(
            "earlyAccess",
            "Early access",
            witness: .text("No early access features")
        ),
    ]

    private static let workspaceAndUtility = [
        Screen("notebooks", "Notebooks", witness: .text("Orbit field log")),
        Screen(
            "max",
            "Max",
            witness: .anyOf([.text("Threads"), .text("No Max conversations")])
        ),
        Screen("renders", "Renders", witness: .text("Example filename 0312")),
        Screen(
            "templates",
            "Templates",
            // `Example App metric 35` names a nested tile that the gallery card
            // does not render. This is the first featured template card title.
            witness: .text("Example App metric 125")
        ),
        Screen(
            "settings",
            "Settings",
            preparation: .confirmThenReveal(initial: "Account", target: "Personal API key"),
            witness: .text("Personal API key")
        ),
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

    /// Authenticated, read-only counterpart to the deterministic roster sweep.
    ///
    /// Search is the launch root, Settings is reached through its ornament
    /// control, and the 33 product roots are reached through the same section
    /// and row helpers as the interaction suite. No customer-authored title is
    /// used as an oracle and no detail or write control is activated.
    func testLivePATAllRootScreensRender() throws {
        try LiveCredentials.requireSweep()

        guard ExclusiveRun.claim() else { return }
        let utilityApp = launchLive(tab: "search")

        assertLiveRoot("Search", in: utilityApp)

        guard VisionSidebar.tap("Settings", in: utilityApp) else { return }
        assertLiveRoot("Settings", in: utilityApp)
        utilityApp.terminate()

        sweepLive(Self.analyze.dropFirst(), section: "Analyze")
        sweepLive(Self.monitor, section: "Monitor")
        sweepLive(Self.data, section: "Data")
        sweepLive(Self.experiment, section: "Experiment")
        sweepLive(
            Self.workspaceAndUtility.dropLast(),
            section: "Workspace",
            leavesAppForeground: true
        )
    }

    private func launchLive(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = LiveCredentials.environment
        app.launchEnvironment["GETHOG_TAB"] = tab
        app.launch()
        return app
    }

    private func sweep(_ screens: [Screen]) {
        for screen in screens {
            let app = DemoLaunch.launch(tab: screen.rawValue)
            let rootTitle = app.navigationBars[screen.title].firstMatch

            XCTAssertTrue(
                DemoLaunch.wait(for: rootTitle),
                "\(screen.title) never rendered its stable root title."
            )
            if let preparation = screen.preparation {
                XCTAssertTrue(
                    preparation.perform(in: app),
                    "\(screen.title) could not \(preparation.expectation)."
                )
            }
            XCTAssertTrue(
                DemoLaunch.wait(until: { screen.witness.isSatisfied(in: app) }),
                "\(screen.title) never reached its terminal witness: "
                    + "\(screen.witness.expectation)."
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

    private func sweepLive<S: Sequence>(
        _ screens: S,
        section sectionTitle: String,
        leavesAppForeground: Bool = false
    ) where S.Element == Screen {
        let screens = Array(screens)
        guard let first = screens.first else {
            return XCTFail("The live Vision \(sectionTitle) roster was empty.")
        }

        let app = launchLive(tab: first.rawValue)
        assertLiveRoot(first.title, in: app)

        let section = VisionSidebar.section(sectionTitle, in: app)
        guard DemoLaunch.wait(until: { section.exists && section.isHittable }) else {
            return XCTFail("The live Vision shell never offered \(sectionTitle).")
        }
        section.tap()

        for screen in screens.dropFirst() {
            guard VisionSidebar.tap(screen.title, in: app) else { continue }
            assertLiveRoot(screen.title, in: app)
        }

        if !leavesAppForeground {
            app.terminate()
        }
    }

    private func assertLiveRoot(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars[title].firstMatch, timeout: 60),
            "The live Vision \(title) root never rendered its stable title."
        )
        DemoLaunch.pause(0.75)
        DemoLaunch.settle(app, timeout: 20)
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "The app left the foreground while rendering live \(title)."
        )
    }
}
