import XCTest

/// Proves the shell launches and renders on this platform at all: the runner,
/// the host app, the launch, and the first of the four vertical pages.
///
/// Driven in demo mode so the assertion is about a deterministic fixture rather
/// than about whatever credential the simulator happens to hold — a launch with
/// no key renders a perfectly correct empty state, which would make this test
/// pass while proving nothing about the page it is meant to cover.
@MainActor
final class WatchScaffoldUITests: XCTestCase {
    func testDemoShellRendersTheHeadlineMetric() {
        let app = DemoLaunch.launch()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["Example daily engagement"], timeout: 30)
        )
    }

    /// Catches the manual Region picker losing its watch-native row treatment:
    /// a bare picker in the entry VStack collapses to a clipped strip whose
    /// selected value is not a usable control.
    func testFirstEntryRegionPickerIsFullWidthAndOpensChoices() {
        guard ExclusiveRun.claim() else { return }

        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["No key yet"], timeout: 30),
            "The credential-free first-entry flow did not appear."
        )

        let selectedRegion = app.staticTexts["US Cloud"]
        for _ in 0..<3 where !selectedRegion.exists {
            app.swipeUp()
        }
        guard DemoLaunch.wait(for: selectedRegion, timeout: 5) else {
            return XCTFail("The first-entry flow never rendered its selected Region value.")
        }

        let regionControl = app.buttons
            .containing(.staticText, identifier: "US Cloud")
            .firstMatch
        guard DemoLaunch.wait(for: regionControl, timeout: 5) else {
            return XCTFail("US Cloud was visible but was not inside a tappable Region control.")
        }

        let appFrame = app.frame
        let controlFrame = regionControl.frame
        XCTAssertGreaterThanOrEqual(
            controlFrame.width, appFrame.width * 0.75,
            "The Region control did not occupy a usable full-width row."
        )
        XCTAssertGreaterThanOrEqual(
            controlFrame.height, 32,
            "The Region control collapsed below a legible watchOS row height."
        )
        XCTAssertGreaterThanOrEqual(
            selectedRegion.frame.minY, controlFrame.minY,
            "The selected Region text was clipped above its control."
        )
        XCTAssertLessThanOrEqual(
            selectedRegion.frame.maxY, controlFrame.maxY,
            "The selected Region text was clipped below its control."
        )

        regionControl.tap()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["EU Cloud"], timeout: 5),
            "Tapping Region did not open its cloud choices."
        )
        XCTAssertTrue(app.buttons["Self-hosted"].exists)
    }

    /// A rejected key is replaced in the scope where it failed. Defaulting the
    /// form to US Cloud would send an EU key to the wrong host, while dropping
    /// a self-hosted URL leaves no visible record of the endpoint to repair.
    func testRejectedCredentialRetainsCloudAndSelfHostedEndpoints() {
        guard ExclusiveRun.claim() else { return }

        let app = XCUIApplication()
        app.launchArguments = ["-GetHogDemo"]
        app.launchEnvironment["GETHOG_DEMO"] = "1"

        func launch(_ scenario: String) {
            app.terminate()
            app.launchEnvironment["GETHOG_WATCH_SCENARIO"] = scenario
            app.launch()
            XCTAssertTrue(
                DemoLaunch.wait(for: app.staticTexts["Couldn't refresh"], timeout: 30),
                "The synthetic rejected credential did not reach replacement entry."
            )
        }

        func reveal(_ element: XCUIElement) {
            for _ in 0..<6 where !element.exists {
                app.swipeUp()
            }
        }

        let retainedCopy = app.staticTexts[
            "Endpoint retained below. You can edit it before replacing the API key, "
                + "or send it again from your iPhone."
        ]

        launch("rejected-eu")
        reveal(retainedCopy)
        XCTAssertTrue(retainedCopy.exists, "Replacement copy did not explain endpoint retention.")
        let euCloud = app.staticTexts["EU Cloud"]
        reveal(euCloud)
        XCTAssertTrue(euCloud.exists, "The rejected EU credential defaulted to another endpoint.")
        XCTAssertFalse(app.staticTexts["US Cloud"].exists)

        launch("rejected-self-hosted")
        reveal(retainedCopy)
        XCTAssertTrue(retainedCopy.exists, "Replacement copy did not say the endpoint stays editable.")
        let selfHosted = app.staticTexts["Self-hosted"]
        reveal(selfHosted)
        XCTAssertTrue(
            selfHosted.exists,
            "The rejected self-hosted credential did not retain its endpoint kind."
        )
        XCTAssertFalse(app.staticTexts["US Cloud"].exists)

        let serverURL = app.textFields.matching(
            NSPredicate(format: "value == %@", "https://synthetic.example.test")
        ).firstMatch
        reveal(serverURL)
        XCTAssertTrue(
            serverURL.exists,
            "The rejected self-hosted credential hid its retained server URL."
        )
    }
}
