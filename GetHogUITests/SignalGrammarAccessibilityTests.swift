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

    func testCoreFourOverviewScenesAreSingularOnIPad() throws {
        let device = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(device.lowercased().contains("ipad"))

        let cases = [
            (tab: "dashboards", heading: "Project signal"),
            (tab: "events", heading: "Event signal"),
            (tab: "sessions", heading: "Replay signal"),
            (tab: "flags", heading: "Rollout signal"),
        ]

        for item in cases {
            let app = DemoLaunch.launch(tab: item.tab)
            DemoLaunch.settle(app)
            // The initial identifier contract reported 19/4/4/6 matches because
            // SwiftUI inherited each outer identifier onto scene descendants.
            // Those descendants expose sibling frames rather than one stable
            // container frame, so frame grouping was no more truthful. The
            // user-facing heading is the stable singular landmark: a second
            // rendered summary necessarily renders a second heading.
            let headings = app.staticTexts.matching(
                NSPredicate(format: "label == %@", item.heading)
            )
            XCTAssertEqual(
                headings.count,
                1,
                "\(item.tab) must expose one \(item.heading) heading"
            )
            app.terminate()
        }
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

    func testDashboardOverviewUsesLinearAX5TopologyOnIPad() throws {
        try requireIPad()
        let app = DemoLaunch.launch(tab: "dashboards", extraArguments: ax5Arguments)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        XCTAssertGreaterThan(app.frame.width, 700, "The test did not get a regular-width window.")

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
        let pinned = renderedFrame(
            DemoLaunch.elements(labelled: "Pinned", in: app).firstMatch,
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
        assertFollows(computed, dashboards, "Computed must follow Dashboards in a linear AX5 order.")
        assertFollows(generated, computed, "Generated must follow Computed in a linear AX5 order.")
        assertFollows(pinned, generated, "The pinned preview must follow project metrics at AX5.")
        assertFollows(firstTile, pinned, "Pinned content must follow its heading at AX5.")
        assertFollows(
            secondTile,
            firstTile,
            "Pinned dashboard tiles must stack linearly at AX5 instead of sharing a narrow row."
        )
    }

    func testEventsOverviewUsesLinearAX5TopologyOnIPad() throws {
        try requireIPad()
        let app = DemoLaunch.launch(tab: "events", extraArguments: ax5Arguments)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        XCTAssertGreaterThan(app.frame.width, 700, "The test did not get a regular-width window.")

        let eventSignal = renderedFrame(
            DemoLaunch.elements(labelled: "Event signal", in: app).firstMatch,
            named: "Event signal"
        )
        let scope = renderedFrame(
            DemoLaunch.elements(
                labelled: "The 4 most recent events, not the project's history.",
                in: app
            ).firstMatch,
            named: "event feed scope"
        )
        let events = renderedFrame(
            DemoLaunch.elements(labelled: "Events, 4", in: app).firstMatch,
            named: "Events metric"
        )
        let kinds = renderedFrame(
            DemoLaunch.elements(labelled: "Kinds, 4", in: app).firstMatch,
            named: "Kinds metric"
        )
        let people = renderedFrame(
            DemoLaunch.elements(labelled: "People, 3", in: app).firstMatch,
            named: "People metric"
        )
        let reach = renderedFrame(
            DemoLaunch.elements(labelled: "Reaching back, 3m", in: app).firstMatch,
            named: "Reaching back metric"
        )
        let frequency = renderedFrame(
            DemoLaunch.elements(labelled: "Most frequent", in: app).firstMatch,
            named: "Most frequent section"
        )

        assertFollows(scope, eventSignal, "The feed scope must follow the Events identity at AX5.")
        assertFollows(events, scope, "Events metrics must follow their scope at AX5.")
        assertFollows(kinds, events, "Kinds must follow Events in a linear AX5 order.")
        assertFollows(people, kinds, "People must follow Kinds in a linear AX5 order.")
        assertFollows(reach, people, "Reach must follow People in a linear AX5 order.")
        assertFollows(frequency, reach, "Event rankings must follow the summary at AX5.")
    }

    func testFlagsOverviewUsesLinearAX5TopologyOnIPad() throws {
        try requireIPad()
        let app = DemoLaunch.launch(tab: "flags", extraArguments: ax5Arguments)
        defer { app.terminate() }
        DemoLaunch.settle(app)

        XCTAssertGreaterThan(app.frame.width, 700, "The test did not get a regular-width window.")

        let rolloutSignal = renderedFrame(
            DemoLaunch.elements(labelled: "Rollout signal", in: app).firstMatch,
            named: "Rollout signal"
        )
        let flags = renderedFrame(
            DemoLaunch.elements(labelled: "Flags, 9", in: app).firstMatch,
            named: "Flags metric"
        )
        let enabledMetric = renderedFrame(
            DemoLaunch.elements(labelled: "Enabled, 9", in: app).firstMatch,
            named: "Enabled metric"
        )
        let enabled = renderedFrame(
            DemoLaunch.elements(labelled: "9 enabled", in: app).firstMatch,
            named: "Enabled status"
        )
        let disabled = renderedFrame(
            DemoLaunch.elements(labelled: "0 disabled", in: app).firstMatch,
            named: "Disabled status"
        )
        let archived = renderedFrame(
            DemoLaunch.elements(labelled: "0 archived", in: app).firstMatch,
            named: "Archived status"
        )

        assertFollows(flags, rolloutSignal, "Flag metrics must follow the identity at AX5.")
        assertFollows(enabledMetric, flags, "Enabled must follow Flags in a linear AX5 order.")
        assertFollows(enabled, enabledMetric, "Flag state totals must follow the metrics at AX5.")
        assertFollows(disabled, enabled, "Disabled must follow Enabled in a linear AX5 order.")
        assertFollows(archived, disabled, "Archived must follow Disabled in a linear AX5 order.")
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
