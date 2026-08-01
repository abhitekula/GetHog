import XCTest

@MainActor
final class SignalGrammarAccessibilityTests: XCTestCase {
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
