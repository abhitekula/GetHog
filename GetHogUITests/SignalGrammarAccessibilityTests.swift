import XCTest

@MainActor
final class SignalGrammarAccessibilityTests: XCTestCase {
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
