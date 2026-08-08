import XCTest

final class HogQLDashboardTests: XCTestCase {
    private static let dashboardID = 725_102

    func testEveryHogQLDisplayAndIndependentEmptyStatesRender() {
        let app = DemoLaunch.launch(openURL: "gethog://dashboard/\(Self.dashboardID)")
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Synthetic HogQL gallery"]),
            "The synthetic HogQL dashboard never loaded."
        )

        let note = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Dashboard note.")
        ).firstMatch
        XCTAssertTrue(note.exists, "The text tile did not render as a dashboard note.")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dashboard note.")).count,
            0,
            "A dashboard note must not open an insight."
        )

        let expectedInsightTitles = [
            "Synthetic result table",
            "Synthetic values over time",
            "Synthetic area trend",
            "Synthetic grouped bars",
            "Synthetic stacked bars",
            "Synthetic share pie",
            "Synthetic channel heatmap",
            "Synthetic headline value",
            "Synthetic empty result",
            "Synthetic pending result",
        ]
        for title in expectedInsightTitles {
            let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            for _ in 0..<12 where !tile.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(tile.exists, "No rendered tile button was found for \(title).")
        }

        let empty = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Synthetic empty result")
        ).firstMatch
        XCTAssertTrue(empty.label.contains("completed with no rows"), empty.label)

        let pending = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Synthetic pending result")
        ).firstMatch
        XCTAssertTrue(pending.label.contains("not yet computed"), pending.label)
        XCTAssertTrue(pending.label.contains("Data not yet loaded"), pending.label)
    }
}
