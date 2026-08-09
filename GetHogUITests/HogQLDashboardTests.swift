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

    func testCompactResultTableDoesNotTrapDashboardScrolling() {
        let app = DemoLaunch.launch(openURL: "gethog://dashboard/\(Self.dashboardID)")
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Synthetic HogQL gallery"]),
            "The synthetic HogQL dashboard never loaded."
        )

        let table = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Synthetic result table")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: table), "The compact result table never rendered.")
        let initialY = table.frame.minY

        table.swipeUp(velocity: .slow)

        XCTAssertTrue(
            DemoLaunch.wait(timeout: 5) { table.exists && table.frame.minY < initialY - 40 },
            "A vertical swipe beginning on the compact table did not move the dashboard."
        )
    }

    func testCompactResultTableScrollsHorizontallyWithoutOpeningInsight() {
        let app = DemoLaunch.launch(openURL: "gethog://dashboard/\(Self.dashboardID)")
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Synthetic HogQL gallery"]),
            "The synthetic HogQL dashboard never loaded."
        )

        let table = app.scrollViews["gethog.hogql-result-table"].firstMatch
        let tile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Synthetic result table")
        ).firstMatch
        let trailingColumn = app.staticTexts["gethog.hogql-table.column.11"].firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: table), "The compact table scroll view never rendered.")
        XCTAssertTrue(tile.exists, "The scroll-aware table tile was no longer an accessible button.")
        XCTAssertTrue(trailingColumn.exists, "The trailing synthetic column was not in the table.")
        XCTAssertFalse(trailingColumn.isHittable, "The trailing column unexpectedly began on screen.")

        // The shared synthetic gallery deliberately overflows on tvOS too, so
        // this table now has twelve columns. Traverse a bounded number of
        // view-width strokes rather than baking the old six-column distance
        // into the gesture contract.
        for _ in 0..<8 where !trailingColumn.isHittable {
            table.swipeLeft(velocity: .slow)
        }

        XCTAssertFalse(
            DemoLaunch.wait(timeout: 2) {
                app.buttons["Done"].exists || app.buttons["Close insight"].exists
            },
            "A horizontal table swipe opened the insight instead of scrolling the table."
        )
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 5) { trailingColumn.exists && trailingColumn.isHittable },
            "Bounded horizontal swipes did not reveal the trailing table column."
        )

        // The table owns horizontal drags, but the rest of the card still owns
        // taps. Aim above the table rather than relying on XCUIElement's centre,
        // which lands inside the scroll surface on this tile.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 5) {
                app.buttons["Done"].exists || app.buttons["Close insight"].exists
            },
            "Making the table scrollable removed tap-to-open from the rest of its tile."
        )
    }
}
