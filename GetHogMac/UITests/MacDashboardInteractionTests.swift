import XCTest

final class MacDashboardInteractionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRecentlyComputedDashboardOpensItsDetail() {
        let app = DemoLaunch.launch(tab: "dashboards")
        let recent = app.buttons["gethog.dashboard-recent-card.725101"].firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: recent))
        recent.click()

        let detail = app.descendants(matching: .any)["gethog.dashboard-detail.725101"]
        XCTAssertTrue(DemoLaunch.wait(for: detail))
        let actions = DemoLaunch.elements(labelled: "Dashboard actions", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: actions))
    }

    @MainActor
    func testDashboardSearchDoesNotLeaveAnUnmatchedRecentCard() {
        let app = DemoLaunch.launch(tab: "dashboards")
        let search = app.searchFields.firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: search))
        search.click()
        search.typeText("definitely-no-dashboard")

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["No matching dashboards"]))
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "gethog.dashboard-recent-card."
                )
            ).firstMatch.exists
        )
    }
}
