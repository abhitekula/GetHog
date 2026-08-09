import XCTest

@MainActor
final class TVNavigationTests: XCTestCase {
    func testSidebarRowsTakeFocusAndReachTheirScreens() {
        let destinations = [
            ("Insights", "Insights"),
            ("Events", "meteor_report_opened"),
            ("Sessions", "Alex Example,"),
            ("Flags", "example-navigation")
        ]

        for (title, fixture) in destinations {
            // Relaunch each walk at the shell's stable Dashboards focus. Once
            // a destination is selected, focus correctly moves into that
            // screen's content; repeatedly pressing Up is not a supported way
            // to reopen a `.sidebarAdaptable` sidebar on tvOS.
            let app = DemoLaunch.launch()
            TVSidebar.select(title, in: app)
            XCTAssertTrue(
                DemoLaunch.wait(for: app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fixture, fixture)
                ).firstMatch, timeout: 60),
                "Selecting the focused \(title) sidebar row did not reach its screen."
            )
        }
    }

    func testSettingsIsReachable() {
        let app = DemoLaunch.launch()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Example App metric 33",
                    "Example App metric 33"
                )
            ).firstMatch, timeout: 60),
            "The walk to Settings did not start on the rendered Dashboards screen."
        )
        TVSidebar.select("Settings", in: app)

        XCTAssertTrue(DemoLaunch.wait(for: app.buttons["Sign out"], timeout: 60))
    }

    func testFlagDetailOmitsUnavailableWidgetAndControlCenterAffordances() {
        let app = DemoLaunch.launch()
        TVSidebar.select("Flags", in: app)
        let flag = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "example-navigation")
        ).firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: flag, timeout: 60))
        // `FlagWidgetTip` lives on the list, so verify its TV compile-out
        // before navigating away from that hierarchy.
        XCTAssertEqual(DemoLaunch.elements(labelled: "Keep a flag to hand", in: app).count, 0)
        // Right leaves the sidebar for the list; Down moves from the list
        // container onto its first focusable row. The row's combined
        // accessibility container does not report `hasFocus` reliably on
        // tvOS, so the detail assertion is the navigation oracle.
        TVRemote.press(.right)
        TVRemote.press(.down)
        TVRemote.press(.select)

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["Live state"], timeout: 60))
        XCTAssertEqual(DemoLaunch.elements(labelled: "Allow quick toggle", in: app).count, 0)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Control Center")
            ).firstMatch.exists
        )
    }

    func testEventsOmitsSavedFilterAuthoringThatTVCannotPersist() {
        let app = DemoLaunch.launch()
        TVSidebar.select("Events", in: app)

        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts["meteor_report_opened"], timeout: 60))
        XCTAssertEqual(DemoLaunch.elements(labelled: "Saved filters", in: app).count, 0)
        XCTAssertEqual(DemoLaunch.elements(labelled: "Save current filters", in: app).count, 0)
    }
}

@MainActor
final class TVHogQLFocusTests: XCTestCase {
    private static let dashboardID = "725102"

    func testRemoteFocusRevealsAnOffscreenTableColumn() {
        let app = launchHogQLTile(index: 1)
        let dataCells = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "gethog.hogql-table.row.")
        )
        let trailingCells = dataCells.matching(
            NSPredicate(format: "identifier ENDSWITH %@", ".cell.11")
        )

        XCTAssertTrue(
            DemoLaunch.wait(until: { dataCells.count > 0 }),
            "The table never rendered an identified data cell."
        )
        XCTAssertTrue(
            TVRemote.focusAny(in: dataCells, by: .right, limit: 12),
            "The Siri Remote could not enter the HogQL table."
        )
        XCTAssertTrue(
            TVRemote.focusAny(in: trailingCells, by: .right, limit: 16),
            "Right presses did not move focus to the trailing HogQL table cell."
        )
        let focusedTrailingCell = TVRemote.focusedElement(in: trailingCells)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                focusedTrailingCell.exists && focusedTrailingCell.isHittable
            }),
            "Focusing the trailing table cell did not reveal its offscreen column."
        )
    }

    func testRemoteFocusRevealsAnOffscreenHeatmapColumn() {
        let app = launchHogQLTile(index: 7)
        let firstCell = app.staticTexts["region-01, email: 1"].firstMatch
        let trailingCell = app.staticTexts["region-32, email: 32"].firstMatch

        XCTAssertTrue(DemoLaunch.wait(for: firstCell), "The heatmap's first cell never rendered.")
        XCTAssertTrue(trailingCell.exists, "The deterministic trailing heatmap cell was absent.")
        XCTAssertTrue(
            TVRemote.focus(on: firstCell, by: .right, limit: 12),
            "The Siri Remote could not enter the HogQL heatmap."
        )
        XCTAssertTrue(
            TVRemote.focus(on: trailingCell, by: .right, limit: 36),
            "Right presses did not move focus to the trailing HogQL heatmap cell."
        )
        XCTAssertTrue(
            DemoLaunch.wait(until: { trailingCell.hasFocus && trailingCell.isHittable }),
            "Focusing the trailing heatmap cell did not reveal its offscreen column."
        )
    }

    private func launchHogQLTile(index: Int) -> XCUIApplication {
        DemoLaunch.launch(environment: [
            "GETHOG_OPEN_DASHBOARD": Self.dashboardID,
            "GETHOG_OPEN_TILE": String(index),
        ])
    }
}
