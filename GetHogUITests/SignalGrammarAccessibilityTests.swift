import XCTest

@MainActor
final class SignalGrammarAccessibilityTests: XCTestCase {
    private let ax5Arguments = [
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityXXXL",
    ]

    private func requireIPad(file: StaticString = #filePath, line: UInt = #line) throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard deviceName.localizedCaseInsensitiveContains("iPad") else {
            throw XCTSkip("Regular-width AX5 topology is measured in the iPad detail pane.")
        }
    }

    private func requireIPhone(file: StaticString = #filePath, line: UInt = #line) throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard deviceName.localizedCaseInsensitiveContains("iPhone") else {
            throw XCTSkip("Compact AX5 project identity is measured on iPhone.")
        }
    }

    private func requireRegularWidth(_ app: XCUIApplication) throws {
        let window = app.windows.firstMatch.frame
        guard window.width > 700 else {
            throw XCTSkip(
                "The \(window.width)-point app window is compact; this assertion measures the regular-width detail pane."
            )
        }
    }

    private func renderedFrame(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect {
        XCTAssertTrue(
            DemoLaunch.wait(for: element),
            "\(name) never appeared.",
            file: file,
            line: line
        )
        let frame = element.frame
        XCTAssertFalse(frame.isEmpty, "\(name) has no rendered frame.", file: file, line: line)
        return frame
    }

    private func assertFollows(
        _ lower: CGRect,
        _ upper: CGRect,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            lower.minY,
            upper.maxY,
            message,
            file: file,
            line: line
        )
    }

    private func assertSharesRow(
        _ first: CGRect,
        _ second: CGRect,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            first.midY,
            second.midY,
            accuracy: 16,
            message,
            file: file,
            line: line
        )
    }

    func testDashboardOverviewSceneIsSingularOnIPad() throws {
        try assertOverviewSceneIsSingular(tab: "dashboards", heading: "Project signal")
    }

    func testEventsOverviewSceneIsSingularOnIPad() throws {
        try assertOverviewSceneIsSingular(tab: "events", heading: "Event signal")
    }

    func testSessionsOverviewSceneIsSingularOnIPad() throws {
        try assertOverviewSceneIsSingular(tab: "sessions", heading: "Replay signal")
    }

    func testFlagsOverviewSceneIsSingularOnIPad() throws {
        try assertOverviewSceneIsSingular(tab: "flags", heading: "Rollout signal")
    }

    private func assertOverviewSceneIsSingular(tab: String, heading: String) throws {
        try requireIPad()

        let app = DemoLaunch.launch(tab: tab)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        try requireRegularWidth(app)

        // The initial identifier contract reported 19/4/4/6 matches because
        // SwiftUI inherited each outer identifier onto scene descendants.
        // Those descendants expose sibling frames rather than one stable
        // container frame, so frame grouping was no more truthful. The
        // user-facing heading is the stable singular landmark: a second
        // rendered summary necessarily renders a second heading.
        let headings = app.staticTexts.matching(
            NSPredicate(format: "label == %@", heading)
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: headings.firstMatch),
            "\(tab) never exposed its \(heading) heading"
        )
        XCTAssertEqual(
            headings.count,
            1,
            "\(tab) must expose one \(heading) heading"
        )
    }

    func testSessionsSummaryUsesLinearAccessibilityLayoutOnIPad() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard deviceName.localizedCaseInsensitiveContains("iPad") else {
            throw XCTSkip("Sessions summary topology is measured in the iPad detail pane.")
        }

        let app = DemoLaunch.launch(
            tab: "sessions",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        DemoLaunch.settle(app)
        try requireRegularWidth(app)

        let summary = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                "gethog.signal-summary.sessions"
            )
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: summary),
            "The Sessions signal summary never appeared in the iPad detail pane."
        )

        let scope = DemoLaunch.elements(
            labelled: "Across the 5 recordings loaded, not the whole project.",
            in: app
        ).firstMatch
        let recordings = DemoLaunch.elements(labelled: "Recordings, 5", in: app).firstMatch

        XCTAssertTrue(scope.exists, "The summary lost its exact loaded-page scope text.")
        XCTAssertTrue(recordings.exists, "The summary lost its combined Recordings metric.")
        XCTAssertFalse(scope.frame.isEmpty, "The loaded-page scope text has no rendered frame.")
        XCTAssertFalse(recordings.frame.isEmpty, "The Recordings metric has no rendered frame.")
        XCTAssertGreaterThan(
            recordings.frame.minY,
            scope.frame.maxY,
            "At AX5 the metrics must follow the scope text vertically, not sit beside it."
        )
    }

    func testDashboardOverviewUsesCompactMetricsAndLinearChartsAtAX5OnIPad() throws {
        try requireIPad()
        let app = DemoLaunch.launch(tab: "dashboards", extraArguments: ax5Arguments)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        try requireRegularWidth(app)

        let projectSignal = renderedFrame(
            DemoLaunch.elements(labelled: "Project signal", in: app).firstMatch,
            named: "Project signal"
        )
        let dashboards = renderedFrame(
            DemoLaunch.elements(labelled: "Dashboards, 11", in: app).firstMatch,
            named: "Dashboards metric"
        )
        let computed = renderedFrame(
            DemoLaunch.elements(labelled: "Computed, 2", in: app).firstMatch,
            named: "Computed metric"
        )
        let generated = renderedFrame(
            DemoLaunch.elements(labelled: "Generated, 6", in: app).firstMatch,
            named: "Generated metric"
        )
        let pinnedPreview = app.descendants(matching: .any)[
            "gethog.dashboard-pinned-preview"
        ].firstMatch
        let pinned = renderedFrame(
            pinnedPreview.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Pinned"))
                .firstMatch,
            named: "Pinned section"
        )
        let firstTile = renderedFrame(
            DemoLaunch.elements(labelled: "Example weekly engagement pulse", in: app).firstMatch,
            named: "first pinned tile"
        )
        let secondTile = renderedFrame(
            DemoLaunch.elements(labelled: "Example daily engagement", in: app).firstMatch,
            named: "second pinned tile"
        )

        assertFollows(dashboards, projectSignal, "Dashboard metrics must follow the identity at AX5.")
        assertSharesRow(
            computed,
            dashboards,
            "Regular-width AX5 must keep the short dashboard metrics on one readable row."
        )
        assertSharesRow(
            generated,
            dashboards,
            "Generated must share the regular-width AX5 metric row."
        )
        assertFollows(
            pinned,
            dashboards.union(computed).union(generated),
            "The pinned preview must follow the complete project metric row at AX5."
        )
        assertFollows(firstTile, pinned, "Pinned content must follow its heading at AX5.")
        assertFollows(
            secondTile,
            firstTile,
            "Pinned dashboard tiles must stack linearly at AX5 instead of sharing a narrow row."
        )
    }

    func testEventsAX5UsesFullWidthListAndPushNavigationOnIPad() throws {
        try requireIPad()
        let app = DemoLaunch.launch(tab: "events", extraArguments: ax5Arguments)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        try requireRegularWidth(app)

        XCTAssertFalse(
            DemoLaunch.elements(labelled: "Event signal", in: app).firstMatch.exists,
            "AX5 retained the regular split-view overview beside the feed."
        )
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "meteor_report_opened")
        ).firstMatch
        let rowFrame = renderedFrame(row, named: "first event row")
        XCTAssertGreaterThan(
            rowFrame.width,
            app.windows.firstMatch.frame.width * 0.7,
            "The AX5 event feed remained squeezed into a split-view sidebar."
        )

        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["meteor_report_opened"]),
            "The full-width AX5 event row did not push its detail."
        )
    }

    func testFlagsAX5UsesFullWidthListAndPushNavigationOnIPad() throws {
        try requireIPad()
        let app = DemoLaunch.launch(tab: "flags", extraArguments: ax5Arguments)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        try requireRegularWidth(app)

        XCTAssertFalse(
            DemoLaunch.elements(labelled: "Rollout signal", in: app).firstMatch.exists,
            "AX5 retained the regular split-view overview beside the flag list."
        )
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "example-chart-density")
        ).firstMatch
        let rowFrame = renderedFrame(row, named: "first flag row")
        XCTAssertGreaterThan(
            rowFrame.width,
            app.windows.firstMatch.frame.width * 0.7,
            "The AX5 flag list remained squeezed into a split-view sidebar."
        )

        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["example-chart-density"]),
            "The full-width AX5 flag row did not push its detail."
        )
    }

    func testProjectIdentityRemainsCompleteAtAX5OnIPhone() throws {
        try requireIPhone()
        let app = DemoLaunch.launch(tab: "dashboards", extraArguments: ax5Arguments)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        let organization = app.staticTexts["Northstar Sandbox"].firstMatch
        let project = app.staticTexts["Starling Metrics Lab"].firstMatch
        let organizationFrame = renderedFrame(organization, named: "organization identity")
        let projectFrame = renderedFrame(project, named: "project identity")
        let window = app.windows.firstMatch.frame

        XCTAssertTrue(window.contains(organizationFrame), "The AX5 organization identity is clipped.")
        XCTAssertTrue(window.contains(projectFrame), "The AX5 project identity is clipped.")
        assertFollows(
            projectFrame,
            organizationFrame,
            "AX5 must give the complete project its own line below the organization."
        )
    }

    func testProjectStampPreservesProjectSwitcherSemantics() {
        let app = DemoLaunch.launch(tab: "dashboards")
        DemoLaunch.settle(app)

        let switcher = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current project:")
        ).firstMatch

        XCTAssertTrue(switcher.exists)
        XCTAssertTrue(switcher.isHittable)
        switcher.tap()
        let menuProject = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Starling Metrics Lab")
        ).firstMatch
        XCTAssertTrue(menuProject.waitForExistence(timeout: 3))
    }
}
