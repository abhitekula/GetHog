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

        // The native split chooses one truthful navigation surface at each
        // width: the compact route strip or the persistent wide roster.
        for title in ["Dashboards", "Events", "Sessions"] {
            XCTAssertNotNil(
                VisionSidebar.visibleDestinationControl(title, in: app),
                "The Analyze section did not offer a visible \(title) destination control."
            )
        }

        XCTAssertNotNil(
            VisionSidebar.reveal("Settings", in: app),
            "The Vision ornament did not offer Settings."
        )
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
                DemoLaunch.wait(for: app.navigationBars[destination]),
                "\(destination) did not become the mounted section destination."
            )
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

        // Flags is the section default, so it cannot prove the inner row
        // accepted a tap. Exercise a non-first destination instead.
        guard VisionSidebar.tap("Experiments", in: app) else { return }
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Experiments"]),
            "Selecting Experiments did not change the mounted section destination."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Example cache strategy trial",
                    "Example cache strategy trial"
                )
            ).firstMatch),
            "Selecting Experiments from the Experiment section did not render its fixture."
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

        guard VisionSidebar.tap("Experiments", in: app) else { return }
        let experimentFixture = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Example cache strategy trial",
                "Example cache strategy trial"
            )
        ).firstMatch
        guard DemoLaunch.wait(for: experimentFixture) else {
            return XCTFail(
                "Selecting Experiments before relaunch did not render its deterministic fixture."
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
        guard let restoredControl = VisionSidebar.visibleDestinationControl(
            "Experiments",
            in: restored
        ) else { return }
        if restoredControl.identifier == "gethog.vision.section-destination.Experiments" {
            XCTAssertEqual(
                restoredControl.value as? String,
                "Selected",
                "The restored compact route did not expose its selected state."
            )
        }
        XCTAssertTrue(
            DemoLaunch.wait(for: restored.navigationBars["Experiments"]),
            "Relaunch restored the section but not the Experiments destination."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: restored.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Example cache strategy trial",
                    "Example cache strategy trial"
                )
            ).firstMatch),
            "Relaunch restored the section but not the selected Experiments screen."
        )
    }

    func testSearchPushesSurveyDetailWithBackInsteadOfModalDone() {
        let query = "Telescope feedback"
        let app = DemoLaunch.launch(tab: "search")

        let field = app.searchFields.firstMatch
        guard DemoLaunch.wait(for: field) else {
            return XCTFail("Vision Search exposed no field to type in.")
        }
        field.tap()
        field.typeText(query)

        let result = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", query, query)
        ).firstMatch
        guard DemoLaunch.wait(for: result) else {
            return XCTFail("Search never offered the synthetic Telescope feedback survey.")
        }
        result.tap()

        let loadedTitle = app.navigationBars["Example App metric 829"].firstMatch
        let loadedDetail = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "PostHog doesn't store a status for a survey",
                "PostHog doesn't store a status for a survey"
            )
        ).firstMatch
        guard DemoLaunch.wait(for: loadedTitle), DemoLaunch.wait(for: loadedDetail) else {
            return XCTFail("Search did not render the loaded synthetic survey detail.")
        }

        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        XCTAssertEqual(done.count, 0, "Vision Search presented Survey detail as a modal sheet.")

        // visionOS renders the stack-owned control as a bare chevron and does
        // not expose the iOS `Back` label to XCUITest. It is the sole button in
        // this destination bar; returning to the preserved query below proves
        // its navigation behavior rather than relying on that platform label.
        let back = loadedTitle.buttons.firstMatch
        guard DemoLaunch.wait(until: { back.exists && back.isHittable }) else {
            return XCTFail("The pushed Survey detail exposed no Back control.")
        }
        back.tap()

        let restoredField = app.searchFields.firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: restoredField),
            "Back did not restore the Search field."
        )
        XCTAssertEqual(
            restoredField.value as? String,
            query,
            "Back discarded the user's Search query."
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
