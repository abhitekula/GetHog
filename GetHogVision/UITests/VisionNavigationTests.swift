import XCTest

@MainActor
final class VisionNavigationTests: XCTestCase {
    func testLaunchesToTheSidebar() {
        let app = DemoLaunch.launch()

        // The ornament exposes one value-bearing control per shared section.
        // Analyze is selected initially, so its first three rows are visible in
        // the main window beside the ornament.
        for section in ["Analyze", "Monitor", "Data", "Experiment", "Workspace"] {
            let control = VisionSidebar.section(section, in: app)
            XCTAssertTrue(
                DemoLaunch.wait(until: { control.exists && control.isHittable }),
                "The Vision sidebar did not offer its \(section) section."
            )
        }

        let analyzeSection = VisionSidebar.section("Analyze", in: app)
        analyzeSection.tap()

        for title in ["Dashboards", "Events", "Sessions", "Settings"] {
            XCTAssertNotNil(
                VisionSidebar.reveal(title, in: app),
                "The Vision sidebar did not offer \(title)."
            )
        }
    }

    func testSidebarRowsReachPrimaryScreens() {
        let app = DemoLaunch.launch()
        let analyzeSection = VisionSidebar.section("Analyze", in: app)
        guard DemoLaunch.wait(until: {
            analyzeSection.exists && analyzeSection.isHittable
        }) else {
            return XCTFail("The Vision sidebar did not offer its Analyze section.")
        }
        analyzeSection.tap()

        let visibleAnalyzeDestinations = [
            ("Dashboards", "Example App metric 33"),
            ("Events", "meteor_report_opened"),
            ("Sessions", "Alex Example")
        ]

        for (destination, anchor) in visibleAnalyzeDestinations {
            guard VisionSidebar.tap(destination, in: app) else { return }
            XCTAssertTrue(
                DemoLaunch.wait(for: app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", anchor, anchor)
                ).firstMatch),
                "\(destination) did not render its deterministic fixture."
            )
        }

        let experimentSection = VisionSidebar.section("Experiment", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { experimentSection.exists && experimentSection.isHittable }),
            "The Vision sidebar did not offer its Experiment section."
        )
        experimentSection.tap()

        guard VisionSidebar.tap("Flags", in: app) else { return }
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "example-navigation",
                    "example-navigation"
                )
            ).firstMatch),
            "Selecting Flags from the Experiment section did not render its fixture."
        )
    }

    func testSelectedSectionAndRowRestoreAfterRelaunch() {
        // No `GETHOG_TAB` on either launch: this is the actual SceneStorage
        // restoration path, not the DEBUG route used by the surface sweep.
        let app = DemoLaunch.launch()
        let experimentSection = VisionSidebar.section("Experiment", in: app)
        guard DemoLaunch.wait(until: {
            experimentSection.exists && experimentSection.isHittable
        }) else {
            return XCTFail("The Vision sidebar did not offer its Experiment section.")
        }
        experimentSection.tap()

        guard VisionSidebar.tap("Flags", in: app) else { return }
        let flagFixture = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "example-navigation",
                "example-navigation"
            )
        ).firstMatch
        guard DemoLaunch.wait(for: flagFixture) else {
            return XCTFail(
                "Selecting Flags before relaunch did not render its deterministic fixture."
            )
        }
        // `exists` becomes true on the first rendered frame. Give the screen
        // the same measured settle point the sweep uses before the process is
        // deliberately terminated.
        DemoLaunch.settle(app)

        app.terminate()
        let restored = DemoLaunch.launch()

        let restoredNavigationBars = restored.navigationBars.allElementsBoundByIndex
            .map { $0.identifier }

        XCTAssertTrue(
            DemoLaunch.wait(for: restored.navigationBars["Experiment"]),
            "Relaunch did not restore the Experiment section; mounted \(restoredNavigationBars)."
        )
        guard VisionSidebar.reveal("Flags", in: restored) != nil else { return }
        XCTAssertTrue(
            DemoLaunch.wait(for: restored.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "example-navigation",
                    "example-navigation"
                )
            ).firstMatch),
            "Relaunch restored the section but not the selected Flags screen."
        )
    }

    func testSettingsIsReachableFromItsSidebarRow() {
        let app = DemoLaunch.launch()
        guard VisionSidebar.tap("Settings", in: app) else { return }

        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Settings"]),
            "Selecting the Settings sidebar control did not render Settings."
        )

        // `SettingsRoot` is a long List; Sign out lives in its API-key section,
        // below the initially mounted account/project/alerts rows. Choose the
        // largest collection rather than the 320pt sidebar collection and
        // scroll the real content until the destructive row is hittable.
        let collections = app.collectionViews.allElementsBoundByIndex
        guard let settingsList = collections.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            return XCTFail("Settings rendered no scrollable List.")
        }
        let signOut = app.buttons["Sign out"]
        var scrolls = 0
        while (!signOut.exists || !signOut.isHittable) && scrolls < 12 {
            settingsList.swipeUp(velocity: .slow)
            scrolls += 1
        }

        XCTAssertTrue(
            signOut.exists && signOut.isHittable,
            "Settings never exposed its Sign out row after scrolling the content List."
        )
    }
}
