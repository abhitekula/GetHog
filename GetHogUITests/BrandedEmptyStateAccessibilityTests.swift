import XCTest

@MainActor
final class BrandedEmptyStateAccessibilityTests: XCTestCase {
    func testBrandedEmptyDashboards() throws {
        try auditEmptyState(tab: "dashboards", title: "No dashboards")
    }

    func testBrandedEmptyInsights() throws {
        try auditEmptyState(tab: "insights", title: "No saved insights")
    }

    func testBrandedEmptySessions() throws {
        try auditEmptyState(tab: "sessions", title: "No sessions")
    }

    func testBrandedWorkspaceActionRemainsReachableAtAX5() {
        let app = DemoLaunch.launch(
            tab: "annotations",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["No annotations"]))

        let action = app.buttons["Write one"]
        for _ in 0..<8 where !action.isHittable {
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        XCTAssertTrue(
            action.isHittable,
            "The branded workspace action must remain reachable at AX5."
        )
    }

    /// Full-canvas explanatory prose is a reading block, not a banner. On an
    /// 11-inch iPad the Actions description currently stretches across nearly
    /// the whole canvas, well past one comfortable eye movement; the same
    /// shared primitive draws Pipelines and every other full-screen empty state.
    func testFullCanvasEmptyStateUsesReadableMeasureOnIPad() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The wide empty-state measure is rendered on iPad."
        )

        let app = DemoLaunch.launch(tab: "actions")
        defer { app.terminate() }

        let description = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "events or clicks")
        ).firstMatch
        guard DemoLaunch.wait(for: description) else {
            return XCTFail("The Actions empty-state description never rendered.")
        }

        XCTAssertGreaterThan(
            description.frame.width,
            300,
            "The width query did not resolve the full explanatory sentence."
        )
        XCTAssertLessThanOrEqual(
            description.frame.width,
            560.5,
            "Full-canvas empty-state prose is \(description.frame.width)pt wide, past its 560pt readable measure."
        )
    }

    /// AX5 is allowed to scroll; it is not allowed to strand the only recovery
    /// action behind the tab bar. A bounded native swipe is the user path this
    /// contract protects rather than requiring long prose and its action to fit
    /// together in the initial viewport.
    func testActionsEmptyStateActionRemainsReachableAtAX5() {
        let app = DemoLaunch.launch(
            tab: "actions",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        defer { app.terminate() }

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["No actions"]))
        let action = app.buttons["Define one in PostHog"]
        for _ in 0..<8 where !action.isHittable {
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        XCTAssertTrue(
            action.isHittable,
            "The Actions empty-state action cannot be reached at AX5 after bounded scrolling."
        )
    }

    /// Automation is a report with one empty section, not an empty screen. Its
    /// `List` already owns scrolling and its section header already says
    /// Workflows, so the result belongs in the compact inline state rather than
    /// repeating a full-canvas icon and title inside the row.
    func testAutomationEmptySectionUsesCompactStateAtAX5() {
        let app = DemoLaunch.launch(
            tab: "automation",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        defer { app.terminate() }

        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Automation"]))
        let compactSentence = app.staticTexts[
            "Workflows chain messaging and automation steps behind a trigger. This project has none."
        ]
        XCTAssertTrue(
            DemoLaunch.wait(for: compactSentence),
            "Automation did not render its empty List section as one compact explanatory state."
        )
        XCTAssertFalse(
            app.staticTexts["No workflows"].exists,
            "Automation still embeds a full-canvas empty-state title inside its Workflows section."
        )
    }

    /// A search miss is one row in the traces report, not a replacement for the
    /// report. Keeping the heading and explanation in one compact sentence makes
    /// this mutation-sensitive: putting `EmptyStateView` back in the section
    /// splits them into its full-canvas title and description again.
    func testLLMSearchMissUsesCompactSectionState() {
        let app = DemoLaunch.launch(tab: "llm")
        defer { app.terminate() }

        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["LLM"]))
        let search = app.searchFields.firstMatch
        if !search.exists {
            let searchButton = app.navigationBars["LLM"].buttons["Search"].firstMatch
            guard DemoLaunch.wait(for: searchButton) else {
                return XCTFail("LLM did not expose its trace-search control.")
            }
            searchButton.tap()
        }
        guard DemoLaunch.wait(for: search) else {
            return XCTFail("LLM did not expose trace search.")
        }
        search.tap()

        let query = "unmatched synthetic trace"
        search.typeText(query)

        let compactSentence = app.staticTexts[
            "No matching traces. No traces matched “\(query)”."
        ]
        XCTAssertTrue(
            DemoLaunch.wait(for: compactSentence),
            "The LLM search miss did not remain a compact row in its traces section."
        )
        XCTAssertFalse(
            app.staticTexts["No matching traces"].exists,
            "The LLM traces section still embeds a full-canvas empty-state title."
        )
    }

    /// Search keeps the local screen index above project objects, so an object
    /// miss is one report row rather than a replacement for the whole tab. This
    /// catches the helper-hidden form of the same full-canvas nesting bug.
    func testProjectSearchMissUsesCompactSectionState() throws {
        let source = try String(
            contentsOf: ExclusiveRun.repositoryRoot
                .appending(path: "GetHog/Sources/Search/ProjectSearchView.swift"),
            encoding: .utf8
        )
        let objectsStart = try XCTUnwrap(source.range(of: "// MARK: - Objects"))
        let recentStart = try XCTUnwrap(source.range(of: "// MARK: - No query"))
        let objectsSource = source[objectsStart.upperBound..<recentStart.lowerBound]
        XCTAssertFalse(
            objectsSource.contains("LockedCapabilityView("),
            "Project Search put the whole-screen permission state inside a List row."
        )

        let app = DemoLaunch.launch(tab: "search")
        defer { app.terminate() }

        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Search"]))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: search), "Search did not expose its query field.")
        search.tap()

        // A single token keeps focus stable while the live filter replaces the
        // result rows. The retained failure recording proved that a multiword
        // `typeText` call lost focus after its first token on this screen.
        let query = "unmatched"
        search.typeText(query)

        // Both regular and compact width have truthful, intentionally different
        // explanations. The contract is their shared structure: title and
        // explanation are one row label, and that label carries the query.
        let compactSentence = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@",
                "No matches.",
                query
            )
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: compactSentence),
            "The project-index search miss did not remain a compact row."
        )
        XCTAssertFalse(
            app.staticTexts["No matches"].exists,
            "Project Search still embeds a full-canvas empty-state title in its List."
        )
    }

    private func auditEmptyState(tab: String, title: String) throws {
        let app = DemoLaunch.launch(
            tab: tab,
            environment: ["GETHOG_DEMO_EMPTY_COLLECTION": tab]
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts[title]),
            "The forced-empty \(tab) screen never rendered its expected title."
        )
        DemoLaunch.settle(app)
        let leakedAssets = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "BrandEmpty"))
        XCTAssertEqual(
            leakedAssets.count,
            0,
            "Decorative illustration asset names must not enter the accessibility tree."
        )
        // These are the two audit classes measured as strict across GetHog's
        // existing rendered sweep. The other classes flag system search fields,
        // antialiased ink, and supported partial Dynamic Type ranges here too.
        try app.performAccessibilityAudit(for: [
            .sufficientElementDescription,
            .trait,
        ])
    }
}
