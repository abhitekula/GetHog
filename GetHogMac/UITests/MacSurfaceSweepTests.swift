import XCTest

/// The deterministic 34-root Mac audit at every supported adaptive mode.
///
/// Destination order is read from the running Go menu, whose production layout
/// is derived from `AppTab.sections`, after the loose Search row is verified.
/// The table below is metadata — anchors and ownership — rather than a second
/// navigation list. A missing/extra/reordered menu item fails before the sweep,
/// so adding an `AppTab` cannot silently leave a green 34-item copied array.
///
/// Each cell proves terminal content, the selected root's sole project toolbar,
/// and its exact search ownership. A sidebar label is never accepted as a
/// loaded witness: sidebar labels remain mounted for unselected destinations.
@MainActor
final class MacSurfaceSweepTests: XCTestCase {

    override func setUpWithError() throws {
        // A sweep is worth more finished than stopped: one screen that fails to
        // render should still leave photographs of the ones after it, which is
        // exactly the evidence needed to tell "this screen is broken" from "the
        // shell fell over".
        continueAfterFailure = true
    }

    // MARK: - The surface

    /// Assertions layered onto the code-derived destination order.
    private struct DestinationContract {
        let title: String
        let anchor: String
        let searchPrompt: String?
        let alternateSearchPrompt: String?
        let index: Int

        init(
            _ index: Int,
            _ title: String,
            _ anchor: String,
            search: String? = nil,
            alternateSearch: String? = nil
        ) {
            self.index = index
            self.title = title
            self.anchor = anchor
            self.searchPrompt = search
            alternateSearchPrompt = alternateSearch
        }

        var searchPrompts: [String] {
            [searchPrompt, alternateSearchPrompt].compactMap { $0 }
        }
    }

    private static let contracts: [DestinationContract] = [
        .init(
            1,
            "Search",
            "Orbital operations",
            search: "Search names and folders",
            alternateSearch: "Search screens, names and folders"
        ),
        .init(2, "Dashboards", "Project signal", search: "Search dashboards"),
        .init(3, "Events", "meteor_report_opened", search: "Filter events"),
        .init(4, "Sessions", "Alex Example", search: "Search person email"),
        .init(5, "Insights", "Example meteor report", search: "Search insight names"),
        .init(6, "Web", "sample visitors", search: "Filter pages"),
        .init(7, "Clickmap", "Pages with a render"),
        .init(8, "People", "Sable Okafor", search: "Search persons"),
        .init(9, "Groups", "example-team"),
        .init(10, "SQL", "Browse tables and columns"),
        .init(11, "Errors", "HarborRenderFault"),
        .init(12, "Summaries", "1 summarized session", search: "Search the narrative or person"),
        .init(13, "LLM", "synthetic-id-0099", search: "Search traces"),
        .init(14, "Tracing", "No spans", search: "Filter by span name"),
        .init(15, "Logs", "No log lines", search: "Search log messages"),
        .init(
            16,
            "Support",
            "Scheduled report attachments are unreadable",
            search: "Search tickets"
        ),
        .init(17, "Inbox", "Nothing to triage", search: "Search tasks"),
        .init(18, "Signals", "No reports yet"),
        .init(19, "Health", "SDK out of date"),
        .init(20, "Ingestion", "Cannot merge already identified", search: "Search warnings"),
        .init(21, "Warehouse", "gethog.warehouse-terminal", search: "Search sources, tables and views"),
        .init(22, "Pipelines", "No pipelines", search: "Search pipelines"),
        .init(23, "Automation", "Workflows chain messaging and automation steps behind a trigger"),
        .init(24, "Actions", "No actions", search: "Search actions"),
        .init(25, "Annotations", "No annotations", search: "Search annotations"),
        .init(26, "Taxonomy", "feature_used", search: "Search events"),
        .init(27, "Flags", "example-navigation", search: "Search flag key or name"),
        .init(28, "Experiments", "Example cache strategy trial"),
        .init(29, "Surveys", "Example App metric 829"),
        .init(30, "Early access", "No early access features", search: "Search features"),
        .init(31, "Notebooks", "Orbit field log", search: "Search notebooks"),
        .init(32, "Max", "No Max conversations", search: "Search conversations"),
        .init(33, "Renders", "Example filename 0312", search: "Search filename or session"),
        .init(34, "Templates", "Example App metric 125", search: "Search templates"),
    ]

    private enum Mode {
        case window(label: String, size: CGSize)
        case fullScreen

        var label: String {
            switch self {
            case .window(let label, _): label
            case .fullScreen: "native-full-screen"
            }
        }
    }

    // MARK: - Tests

    func testAllDestinationsAt640x480() {
        sweep(.window(label: "640x480", size: CGSize(width: 640, height: 480)))
    }

    func testAllDestinationsAt800x600() {
        sweep(.window(label: "800x600", size: CGSize(width: 800, height: 600)))
    }

    func testAllDestinationsAt1000x700() {
        sweep(.window(label: "1000x700", size: CGSize(width: 1_000, height: 700)))
    }

    func testAllDestinationsAt1280x820() {
        sweep(.window(label: "1280x820", size: CGSize(width: 1_280, height: 820)))
    }

    func testAllDestinationsAtNativeFullScreen() {
        sweep(.fullScreen)
    }

    // MARK: - Focused deterministic states

    func testRendersLoadingFailedAndEmptyStatesAreExclusive() {
        var app = DemoLaunch.launch(
            tab: "renders",
            environment: [
                "GETHOG_DEMO_RENDERS_STATE": "loading",
                "GETHOG_DEMO_RENDERS_LOADING_DELAY_MS": "8000",
            ]
        )
        let loading = app.descendants(matching: .any)["gethog.load-state.loading"]
        XCTAssertTrue(DemoLaunch.wait(for: loading, timeout: 5), "Renders exposed no loading witness.")
        XCTAssertNil(
            DemoLaunch.waitForContent(containing: "Example filename 0312", in: app, timeout: 1),
            "The held loading state leaked loaded content."
        )
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "Example filename 0312", in: app, timeout: 20),
            "Renders never left the held loading state."
        )
        app.terminate()

        app = DemoLaunch.launch(
            tab: "renders",
            environment: ["GETHOG_DEMO_RENDERS_STATE": "failed"]
        )
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "Couldn't load renders", in: app),
            "The deterministic failure was not distinguished from empty."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Try again"].firstMatch),
            "The initial Renders failure offered no retry."
        )
        XCTAssertNil(
            DemoLaunch.waitForContent(containing: "No renders", in: app, timeout: 1),
            "The deterministic failure was presented as a successful empty response."
        )
        app.terminate()

        app = DemoLaunch.launch(
            tab: "renders",
            environment: ["GETHOG_DEMO_RENDERS_STATE": "empty"]
        )
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "No renders", in: app),
            "The successful empty Renders response had no honest empty state."
        )
        XCTAssertFalse(app.buttons["Try again"].firstMatch.exists, "Successful empty offered failure retry.")
        XCTAssertNil(
            DemoLaunch.waitForContent(containing: "Example filename 0312", in: app, timeout: 1),
            "The empty response retained an ordinary render row."
        )
    }

    func testRendersNoMatchLongTextAndStaleStatesRetainTheirMeaning() {
        var app = DemoLaunch.launch(tab: "renders")
        guard let field = visibleSearchField(prompt: "Search filename or session", in: app) else {
            return XCTFail("Renders exposed no search field for the no-match probe.")
        }
        field.click()
        field.typeText("zzzz-no-match-fixture")
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "No matches", in: app),
            "Renders did not distinguish a client-side no-match from project-empty."
        )
        XCTAssertNil(
            DemoLaunch.waitForContent(containing: "No renders", in: app, timeout: 1),
            "A no-match was flattened into successful project-empty."
        )
        app.terminate()

        let longFilename =
            "Example orbital telemetry render with an intentionally long fictional filename for narrow-window verification 0312.mp4"
        app = DemoLaunch.launch(
            tab: "renders",
            environment: ["GETHOG_DEMO_RENDERS_STATE": "long-text"]
        )
        resize(app, to: CGSize(width: 560, height: 420))
        guard let longRow = DemoLaunch.waitForContent(containing: longFilename, in: app) else {
            return XCTFail("The named long-text scenario did not render its fixed fictional value.")
        }
        XCTAssertGreaterThan(longRow.frame.width, 0, "The long row collapsed at 560×420.")
        XCTAssertLessThanOrEqual(
            longRow.frame.maxX,
            app.windows.firstMatch.frame.maxX + 1,
            "The long fictional filename overflowed the narrow window."
        )
        app.terminate()

        app = DemoLaunch.launch(
            tab: "renders",
            environment: ["GETHOG_DEMO_RENDERS_STATE": "stale"]
        )
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "Example filename 0312", in: app),
            "The stale scenario never established last-good content."
        )
        app.typeKey("r", modifierFlags: .command)
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "Couldn't refresh renders", in: app),
            "The deterministic refresh failure produced no stale-state banner."
        )
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "Example filename 0312", in: app),
            "The stale refresh discarded its last-good render row."
        )
    }

    func testServerBackedNoMatchProbeReturnsAnEventsNoMatch() {
        let app = DemoLaunch.launch(
            tab: "events",
            environment: ["GETHOG_DEMO_SURFACE_NO_MATCH": "1"]
        )
        guard let field = visibleSearchField(prompt: "Filter events", in: app) else {
            return XCTFail("Events exposed no search field for the server no-match probe.")
        }
        field.click()
        field.typeText("zzzz-no-match-fixture")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "No events", in: app),
            "The shape-correct query no-match response did not reach Events' terminal state."
        )
        XCTAssertNil(
            DemoLaunch.waitForContent(containing: "meteor_report_opened", in: app, timeout: 1),
            "The no-match response retained an ordinary event row."
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Manual, authenticated counterpart to the deterministic demo sweep.
    ///
    /// Normal CI never spends a real workspace's request budget: without the
    /// opt-in control file this test is skipped before it creates an
    /// application. The runner reads the untracked credential file directly;
    /// XCUITest then hands its two allowlisted values to the app as process
    /// environment, never as an argument, fixture, screenshot label, or
    /// diagnostic string.
    func testLivePATAllRootScreensRender() throws {
        try LiveCredentials.requireSweep()

        guard ExclusiveRun.claim() else { return }
        let app = XCUIApplication()
        app.launchEnvironment = LiveCredentials.environment
        app.launchEnvironment["GETHOG_TAB"] = "dashboards"
        app.launch()

        let dashboardDestination = app.windows.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate("Dashboards"))
            .firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: dashboardDestination, timeout: 60),
            "The authenticated Mac shell never rendered its dashboard destination."
        )

        let roots = Self.contracts
        for screen in roots {
            open(screen.title, in: app)
            // Observe the screen settling instead of sleeping through an
            // assumed request duration.
            DemoLaunch.settle(app, timeout: 20)
            if screen.title == "Warehouse" {
                XCTAssertTrue(
                    waitForWarehouseTerminalState(in: app),
                    "The live Warehouse screen never left its redacted loading state."
                )
            }
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "The app was gone by live \(screen.title)."
            )
            captureLiveWindow(
                app,
                name: String(format: "live-%02d-%@", screen.index, slug(screen.title))
            )
        }

        open("Dashboards", in: app)
        let dashboardCards = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                "gethog.dashboard-card.",
                "gethog.dashboard-recent-card."
            )
        )
        var dashboardCard: XCUIElement?
        guard DemoLaunch.wait(timeout: 60, until: {
            dashboardCard = dashboardCards.allElementsBoundByIndex.first { $0.isHittable }
            return dashboardCard != nil
        }), let dashboardCard else {
            XCTFail("The live dashboard hub never exposed an actionable dashboard card.")
            return
        }
        let dashboardPrefixes = [
            "gethog.dashboard-card.",
            "gethog.dashboard-recent-card.",
        ]
        guard let dashboardPrefix = dashboardPrefixes.first(where: {
            dashboardCard.identifier.hasPrefix($0)
        }) else {
            XCTFail("The selected live dashboard card had no stable identifier prefix.")
            return
        }
        let dashboardID = String(dashboardCard.identifier.dropFirst(dashboardPrefix.count))
        guard !dashboardID.isEmpty else {
            XCTFail("The selected live dashboard card had an empty stable identifier suffix.")
            return
        }
        dashboardCard.click()

        let dashboardDetail = app.descendants(matching: .any)[
            "gethog.dashboard-detail.\(dashboardID)"
        ]
        guard DemoLaunch.wait(for: dashboardDetail, timeout: 60) else {
            XCTFail("The live dashboard card never opened its matching stable detail root.")
            return
        }
        let dashboardActions = DemoLaunch.elements(labelled: "Dashboard actions", in: app).firstMatch
        guard DemoLaunch.wait(timeout: 60, until: {
            dashboardActions.exists && dashboardActions.isHittable
        }) else {
            XCTFail("The live dashboard detail never exposed its actions.")
            return
        }
        XCTAssertEqual(app.state, .runningForeground, "The live dashboard detail took the app down.")
        captureLiveWindow(app, name: "live-dashboard-detail")

        let windowsBefore = app.windows.count
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count > windowsBefore }),
            "The live sweep could not open Settings with Command-comma."
        )
        DemoLaunch.settle(app, timeout: 20)
        captureLiveWindow(app, name: "live-35-settings")
    }

    /// The flows a list row opens, which is where an iOS-ism survives longest:
    /// a detail that was a sheet on the phone has to fill the Mac's detail
    /// column, and a screenshot is the only thing that says whether it does.
    func testDetailFlowsRender() {
        let app = DemoLaunch.launch()
        normalize(app, to: .window(label: "560x420", size: CGSize(width: 560, height: 420)))

        for (title, rowText, name) in Self.detailFlows {
            open(title, in: app)
            if title == "Search", let field = visibleSearchField(
                prompts: ["Search screens, names and folders", "Search names and folders"],
                in: app
            ) {
                field.click()
                field.typeText(rowText)
            }
            if title == "Dashboards" {
                let row = app.buttons["gethog.dashboard-card.725101"].firstMatch
                var scrolls = 0
                while !row.exists && scrolls < 12 {
                    app.scrollViews["gethog.dashboard-hub"].scroll(byDeltaX: 0, deltaY: -180)
                    scrolls += 1
                }
                guard DemoLaunch.wait(for: row) else {
                    XCTFail("Dashboards never offered gethog.dashboard-card.725101.")
                    continue
                }
                row.click()
                let detail = app.descendants(matching: .any)["gethog.dashboard-detail.725101"]
                XCTAssertTrue(
                    DemoLaunch.wait(for: detail),
                    "The dashboard card did not open its matching detail root."
                )
                assertBackRestores(
                    title: title,
                    rootAnchor: "gethog.dashboard-hub",
                    attachmentName: "\(name)-560x420",
                    in: app
                )
                XCTAssertEqual(app.state, .runningForeground, "Dashboards' detail took the app down.")
                continue
            }
            if title == "Warehouse", let field = visibleSearchField(
                prompt: "Search sources, tables and views",
                in: app
            ) {
                field.click()
                field.typeText(rowText)
            }
            guard let row = DemoLaunch.waitForContent(containing: rowText, in: app) else {
                XCTFail("\(title) never offered a row containing \(rowText).")
                continue
            }
            row.click()
            assertBackRestores(
                title: title,
                rootAnchor: rowText,
                attachmentName: "\(name)-560x420",
                in: app
            )
            XCTAssertEqual(app.state, .runningForeground, "\(title)'s detail took the app down.")
        }
    }

    private func assertBackRestores(
        title: String,
        rootAnchor: String,
        attachmentName: String,
        in app: XCUIApplication
    ) {
        let back = app.windows.buttons["Back"].firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: back), "\(title)'s compact detail offered no Back control.")
        XCTAssertTrue(back.isHittable, "\(title)'s compact Back control was not usable.")
        capture(app, name: attachmentName)
        back.click()

        if rootAnchor.hasPrefix("gethog.") {
            XCTAssertTrue(
                DemoLaunch.wait(for: app.windows.descendants(matching: .any)[rootAnchor]),
                "Back did not restore \(title)'s root."
            )
        } else {
            XCTAssertNotNil(
                DemoLaunch.waitForContent(containing: rootAnchor, in: app),
                "Back did not restore \(title)'s loaded anchor."
            )
        }
    }

    /// Destination, deterministic actionable row, and attachment stem.
    ///
    /// Empty roots are represented by their terminal state in the 170-cell
    /// matrix and cannot honestly promise Back. These populated roots each
    /// prove the compact push and return path once, including the Mac-hoisted
    /// LLM/Experiments/Surveys details.
    private static let detailFlows: [(String, String, String)] = [
        ("Search", "Orbital operations", "d01-search-detail"),
        ("Events", "meteor_report_opened", "d02-event-detail"),
        ("People", "Sable Okafor", "d03-person-detail"),
        ("Groups", "example-team", "d04-group-type-detail"),
        ("Errors", "HarborRenderFault", "d05-error-detail"),
        ("Summaries", "Succeeded", "d06-summary-detail"),
        ("LLM", "synthetic-id-0099", "d1-llm-detail"),
        ("Support", "Scheduled report attachments are unreadable", "d08-support-detail"),
        ("Warehouse", "example_meteor_delivery_failures", "d09-warehouse-detail"),
        ("Taxonomy", "feature_used", "d10-taxonomy-detail"),
        ("Flags", "example-navigation", "d11-flag-detail"),
        ("Experiments", "Example cache strategy trial", "d12-experiment-detail"),
        ("Surveys", "Example App metric 829", "d13-survey-detail"),
        ("Dashboards", "Example App metric 33", "d14-dashboard-detail"),
        ("Sessions", "Alex Example", "d15-replay-detail"),
        ("Insights", "Example meteor report", "d16-insight-detail"),
        ("Notebooks", "Orbit field log", "d17-notebook-detail"),
        ("Renders", "Example filename 0312", "d18-render-detail"),
        ("Templates", "Example App metric 125", "d19-template-detail"),
    ]

    /// The pointer over a chart, photographed at the two positions that decide
    /// whether the hover scrub is right.
    ///
    /// This is the regression guard the hover work left owed. It does not
    /// assert the readout's text: the hover overlay is `accessibilityHidden`
    /// by design — a clear rectangle over every chart would otherwise be a stop
    /// on the VoiceOver tour — so the readout is not addressable by the query
    /// this suite could write in advance, and an assertion invented for it
    /// would pin the wrong thing. What it does is put the pointer where the
    /// answer is and keep the pictures.
    ///
    /// The two positions are the point: the plot centre is the case that has
    /// to work, and the margin just inside the plot edge is the 12pt
    /// scale-padding band where `ChartHover`'s selection can resolve to `nil`
    /// and blank a readout that should have held its last real sample. Read
    /// the two shots side by side; a blank margin shot is the finding.
    func testChartHoverHoldsItsReadout() {
        let app = DemoLaunch.launch()

        open("Dashboards", in: app)
        guard let row = DemoLaunch.waitForContent(containing: "Example App metric 33", in: app) else {
            XCTFail("The dashboard list never offered its first row.")
            return
        }
        row.click()

        guard let tile = DemoLaunch.waitForContent(
            containing: DemoLaunch.firstTileTitle, in: app
        ) else {
            XCTFail("The dashboard detail never rendered \(DemoLaunch.firstTileTitle).")
            return
        }
        DemoLaunch.settle(app)

        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        DemoLaunch.settle(app)
        capture(app, name: "h1-chart-hover-centre")

        // Just inside the left edge of the plot — the scale-padding band.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.6)).hover()
        DemoLaunch.settle(app)
        capture(app, name: "h2-chart-hover-margin")

        XCTAssertEqual(app.state, .runningForeground, "Hovering the chart took the app down.")
    }

    // MARK: - The sweep

    private func sweep(_ mode: Mode) {
        let app = DemoLaunch.launch()
        normalize(app, to: mode)

        let derived = authoritativeDestinationOrder(in: app)
        XCTAssertEqual(
            derived,
            Self.contracts.map(\.title),
            "The runtime AppTab-derived destination order drifted from the audit metadata."
        )
        guard derived == Self.contracts.map(\.title) else { return }

        for contract in Self.contracts {
            open(contract.title, in: app)
            assertSelectedToolbar(for: contract, in: app)
            prepareLoadedAnchor(for: contract, in: app)
            if contract.anchor.hasPrefix("gethog.") {
                let anchor = app.windows.descendants(matching: .any)[contract.anchor]
                XCTAssertTrue(
                    DemoLaunch.wait(for: anchor, timeout: 60),
                    "\(mode.label) \(contract.title) never rendered \(contract.anchor)."
                )
            } else {
                XCTAssertNotNil(
                    DemoLaunch.waitForContent(containing: contract.anchor, in: app),
                    "\(mode.label) \(contract.title) never rendered “\(contract.anchor)”."
                )
            }
            XCTAssertFalse(
                app.windows.buttons["Back"].firstMatch.isHittable,
                "\(contract.title) retained another destination's pushed navigation state."
            )
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "The app was gone by \(contract.title) at \(mode.label)."
            )
            capture(
                app,
                name: String(
                    format: "%02d-%@-%@",
                    contract.index,
                    slug(contract.title),
                    mode.label
                )
            )
        }
    }

    /// The loose Search root puts the compact screen index before project
    /// objects. Narrowing to its fixed fictional object makes the loaded anchor
    /// visible without scrolling a lazy list and also proves that the field is
    /// wired to the selected screen rather than merely present in the toolbar.
    private func prepareLoadedAnchor(
        for contract: DestinationContract,
        in app: XCUIApplication
    ) {
        guard contract.title == "Search" else { return }
        guard let field = visibleSearchField(
            prompts: contract.searchPrompts,
            in: app
        ) else {
            return XCTFail("Search exposed no field for its loaded-anchor probe.")
        }
        field.click()
        field.typeText(contract.anchor)
    }

    /// Search is the one loose root. Every other title comes from the enabled
    /// items SwiftUI built from `GoMenuLayout.sections()` / `AppTab.sections`.
    private func authoritativeDestinationOrder(in app: XCUIApplication) -> [String] {
        var looseSearch = sidebarItem("Search", in: app)
        var revealedSidebar = false
        if !looseSearch.exists || !looseSearch.isHittable {
            app.typeKey("s", modifierFlags: [.command, .control])
            revealedSidebar = DemoLaunch.wait(timeout: 10, until: {
                looseSearch = sidebarItem("Search", in: app)
                return looseSearch.exists && looseSearch.isHittable
            })
        }
        XCTAssertTrue(
            looseSearch.exists && looseSearch.isHittable,
            "The loose Search root was absent from the Mac source list."
        )
        if revealedSidebar {
            app.typeKey("s", modifierFlags: [.command, .control])
            _ = DemoLaunch.wait(timeout: 10, until: { !looseSearch.isHittable })
        }

        let go = app.menuBars.menuBarItems["Go"]
        guard go.exists else {
            XCTFail("The AppTab-derived Go menu was absent.")
            return []
        }
        go.click()
        guard DemoLaunch.wait(timeout: 5, until: { app.menus.firstMatch.exists }) else {
            XCTFail("The Go menu never opened.")
            return []
        }
        let menu = app.menus.firstMatch
        let productTitles = menu.menuItems.allElementsBoundByIndex
            .filter { $0.isEnabled && !$0.title.isEmpty }
            .map(\.title)
        app.typeKey(.escape, modifierFlags: [])
        return ["Search"] + productTitles
    }

    /// Only the selected root may own toolbar/search state. Content anchors
    /// alone cannot prove that: every destination label remains in the sidebar.
    private func assertSelectedToolbar(
        for contract: DestinationContract,
        in app: XCUIApplication
    ) {
        let projectControls = app.windows.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Current project:",
                "Current project:"
            )
        ).allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(
            projectControls.count,
            1,
            "\(contract.title) did not exclusively own one visible project toolbar."
        )

        let knownPrompts = Self.contracts.flatMap(\.searchPrompts)
        let visibleSearchFields = (app.searchFields.allElementsBoundByIndex
            + app.textFields.allElementsBoundByIndex).filter { element in
                guard element.isHittable else { return false }
                let description = [element.label, element.placeholderValue ?? "", "\(element.value ?? "")"]
                    .joined(separator: " ")
                return knownPrompts.contains {
                    description.localizedCaseInsensitiveContains($0)
                }
            }

        if !contract.searchPrompts.isEmpty {
            let owners = visibleSearchFields.filter { element in
                let description = [
                    element.label,
                    element.placeholderValue ?? "",
                    "\(element.value ?? "")",
                ]
                    .joined(separator: " ")
                return contract.searchPrompts.contains {
                    description.localizedCaseInsensitiveContains($0)
                }
            }
            XCTAssertEqual(
                owners.count,
                1,
                "\(contract.title) did not exclusively own one of its valid search prompts."
            )
            XCTAssertEqual(
                visibleSearchFields.count,
                1,
                "An unselected destination retained a second search field on \(contract.title)."
            )
        } else {
            XCTAssertTrue(
                visibleSearchFields.isEmpty,
                "A searchable unselected root retained toolbar ownership on \(contract.title)."
            )
        }
    }

    private func visibleSearchField(
        prompt: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        visibleSearchField(prompts: [prompt], in: app)
    }

    private func visibleSearchField(
        prompts: [String],
        in app: XCUIApplication
    ) -> XCUIElement? {
        (app.searchFields.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex)
            .first { element in
                guard element.isHittable else { return false }
                let description = [
                    element.label,
                    element.placeholderValue ?? "",
                    "\(element.value ?? "")",
                ].joined(separator: " ")
                return prompts.contains {
                    description.localizedCaseInsensitiveContains($0)
                }
            }
    }

    private func normalize(_ app: XCUIApplication, to mode: Mode) {
        switch mode {
        case .fullScreen:
            enterFullScreen(app)
        case .window(_, let size):
            leaveFullScreen(app)
            resize(app, to: size)
        }
    }

    private func leaveFullScreen(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.exists, window.frame.minY < 50 else { return }
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 15, until: { window.frame.minY >= 50 }),
            "The sweep could not leave persisted full screen."
        )
    }

    private func enterFullScreen(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.exists else { return XCTFail("The sweep had no main window.") }
        if window.frame.minY >= 50 {
            app.typeKey("f", modifierFlags: [.command, .control])
        }
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 15, until: { window.frame.minY < 50 }),
            "The window never reached native full screen."
        )
        XCTAssertGreaterThan(window.frame.width, 1_280)
        XCTAssertGreaterThan(window.frame.height, 820)
    }

    /// Moves the title bar away from the display edge, then uses long edge
    /// grabs. A corner is a few points square and silently misses; each edge is
    /// hundreds of points long. Completion is observed from frame geometry.
    private func resize(_ app: XCUIApplication, to size: CGSize) {
        leaveFullScreen(app)
        let window = app.windows.firstMatch
        guard window.exists else { return XCTFail("The sweep had no main window.") }
        let frame = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width / 3, dy: 12))
            .press(
                forDuration: 0.3,
                thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.width / 3 - frame.minX, dy: 12))
            )
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10, until: { window.frame.minX < 8 }),
            "The window could not move to a resize-safe origin."
        )

        let start = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: start.width - 3, dy: start.height / 2))
            .press(
                forDuration: 0.4,
                thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: size.width, dy: start.height / 2))
            )
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10, until: { abs(window.frame.width - size.width) <= 1 }),
            "The window missed the requested width \(size.width)."
        )

        let middle = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: middle.width / 2, dy: middle.height - 3))
            .press(
                forDuration: 0.4,
                thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: middle.width / 2, dy: size.height))
            )
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10, until: { abs(window.frame.height - size.height) <= 1 }),
            "The window missed the requested height \(size.height)."
        )
        XCTAssertEqual(window.frame.width, size.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, size.height, accuracy: 1)
    }

    // MARK: - Helpers

    /// The sidebar destination carrying an exact title, scoped the way
    /// `MacNavigationTests.sidebarItem` scopes it — the content area can
    /// legitimately carry the same word, and the menu bar certainly does.
    private func sidebarItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // Every outline, not just the first. On a split-view screen the
        // content list is *also* an outline — measured: the Sessions list
        // reports `Outline, label: 'Sidebar'` at x=271 — so `firstMatch` can
        // resolve to the content column, miss the destination, and fall through
        // to an app-wide query that returns a zero-size off-screen duplicate.
        // Asking every outline for a hittable match removes the ambiguity.
        for sidebar in app.outlines.allElementsBoundByIndex {
            let scoped = sidebar.descendants(matching: .any)
                .matching(DemoLaunch.macTextPredicate(title))
            if let hittable = scoped.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                return hittable
            }
        }
        return app.windows.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate(title))
            .firstMatch
    }

    /// Clicks a sidebar destination, failing the test if it is not there.
    /// The default pass's route: a missing destination is a finding.
    private func open(_ title: String, in app: XCUIApplication) {
        let reached = title == "Search"
            ? reachLooseSearch(in: app)
            : openViaGoMenu(title, in: app)
        if !reached {
            XCTFail("No sidebar destination labelled \(title).")
        }
    }

    /// Search deliberately has no Go item. At compact widths the source list is
    /// collapsed, so reveal it through the native Toggle Sidebar command and
    /// select the one loose `MacRootView.looseTabs` row.
    private func reachLooseSearch(in app: XCUIApplication) -> Bool {
        var item = sidebarItem("Search", in: app)
        if !item.exists || !item.isHittable {
            app.typeKey("s", modifierFlags: [.command, .control])
            guard DemoLaunch.wait(timeout: 10, until: {
                item = sidebarItem("Search", in: app)
                return item.exists && item.isHittable
            }) else { return false }
        }
        item.click()
        DemoLaunch.settle(app)
        return true
    }

    /// Clicks a sidebar destination and says whether it got there, scrolling the
    /// sidebar to it first if it is below the fold — thirty-four rows do not fit
    /// 820pt, and the rows at the bottom of Workspace are exactly the ones
    /// nobody has looked at.
    ///
    /// Returning a `Bool` rather than failing is what lets the screenshot-only
    /// size passes keep their promise not to fail the run; `open` puts the
    /// failure back for the passes that assert.
    @discardableResult
    private func reach(_ title: String, in app: XCUIApplication) -> Bool {
        var item = sidebarItem(title, in: app)
        // **A missing row is a reason to try the menu, not to give up.** This
        // returned `false` here, which is why the narrow and wide passes
        // produced no screenshots at all: at 800×600 the split view collapses
        // its sidebar, so *no* destination row exists, the 30-second existence
        // wait timed out on every screen, and the Go-menu fallback forty lines
        // below — which needs no sidebar and would have worked — was never
        // reached. Five seconds, because a row that is going to appear has
        // appeared by then; the launch gate already waited for the shell.
        guard DemoLaunch.wait(for: item, timeout: 5) else {
            return openViaGoMenu(title, in: app)
        }

        // Existence is not reachability in a scrolling outline.
        // Scroll monotonically toward the bottom, then back toward the top.
        // The first attempt alternated direction and therefore netted zero,
        // which is why the Workspace rows were never reached and their
        // screenshots caught the *previous* screen still on display.
        var scrolls = 0
        while !item.isHittable && scrolls < 12 {
            app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: -120)
            item = sidebarItem(title, in: app)
            scrolls += 1
        }
        while !item.isHittable && scrolls < 24 {
            app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: 120)
            item = sidebarItem(title, in: app)
            scrolls += 1
        }

        // Last resort, and a check in its own right: the Go menu lists every
        // destination and needs no scrolling. If the sidebar could not be made
        // to reach a screen but the menu can, the sweep still photographs the
        // screen and the difference is itself worth knowing.
        guard item.isHittable else { return openViaGoMenu(title, in: app) }

        item.click()
        DemoLaunch.settle(app)
        return true
    }


    /// Routes to a destination through the Go menu, which needs no scrolling
    /// because a menu is not a viewport. Also a check in its own right: if the
    /// sidebar could not be made to reach a screen but the menu can, the sweep
    /// still photographs the screen and the difference is worth knowing.
    private func openViaGoMenu(_ title: String, in app: XCUIApplication) -> Bool {
        let go = app.menuBars.menuBarItems["Go"]
        guard go.exists else { return false }
        go.click()
        let entry = app.menuItems[title]
        guard DemoLaunch.wait(for: entry, timeout: 5), entry.isEnabled else {
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        entry.click()
        DemoLaunch.settle(app)
        return true
    }

    /// The whole screen, not the window: the Dock and the menu bar are part of
    /// what a Mac sweep is checking, and a window-scoped shot would crop out
    /// the app icon this task also fixed.
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Authenticated evidence is intentionally window-scoped.
    ///
    /// The deterministic sweep above owns the entire simulator desktop, so the
    /// menu bar and Dock are useful shell evidence there. A manual live sweep
    /// runs in the developer's real GUI session; a full-screen attachment can
    /// capture unrelated applications behind GetHog. The front app window is
    /// the complete product surface and the only privacy-safe boundary.
    private func captureLiveWindow(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "The live sweep had no GetHog window for \(name).")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for one of Warehouse's three truthful terminal compositions.
    ///
    /// SwiftUI's redaction skeleton is not a progress indicator, so the generic
    /// `settle` helper can finish while the list still contains placeholders.
    /// `WarehouseRoot` publishes a state-only identifier after the three
    /// requests resolve. It contains no project data and remains available when
    /// accessibility-sized lazy lists keep lower section headers off-screen.
    private func waitForWarehouseTerminalState(in app: XCUIApplication) -> Bool {
        let terminal = app.descendants(matching: .any)["gethog.warehouse-terminal"]
        return DemoLaunch.wait(for: terminal, timeout: 60)
    }

    private func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
