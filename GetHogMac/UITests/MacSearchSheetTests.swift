import XCTest

/// The one Mac presentation that still *sheets* a detail the shell otherwise
/// pushes.
///
/// `MacRootView` pushes the four `presentsDetailAsSheet` details inline, so
/// `DetailSheetContainer` gives them no navigation stack on macOS — the hosting
/// stack already has the bar. Search is the exception: a survey result opens
/// `SurveySearchSheet`, a real sheet with nothing above it to inherit chrome
/// from, so that view supplies the stack and the Done button itself.
///
/// The regression this pins is specifically a *transition*: the sheet has two
/// states, and an earlier arrangement chromed only one of them. It came up with
/// a title bar while the survey loaded and lost it the instant the survey
/// arrived, leaving a modal with no way out. So Done is asserted **before and
/// after** the load, not once.
final class MacSearchSheetTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `file_system.json` holds exactly one survey, and its `ref` is the first
    /// id in `surveys.json` — so the sheet resolves to a real survey rather than
    /// the "no longer among its surveys" branch.
    private let indexedSurveyName = "Telescope feedback"

    /// `surveys.json`'s name for that same id, which is what the loaded sheet
    /// titles itself with.
    private let loadedSurveyName = "Example App metric 829"

    /// A sentence only `SurveyDetailSheet` writes, so "the survey loaded" cannot
    /// be satisfied by the search row still being on screen behind the sheet.
    private let loadedSurveyProof = "PostHog doesn't store a status for a survey"

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        // Label *or* value, and never `.any`: see `DemoLaunch.macContentTypes`
        // — a Mac `Text` carries its words as a value, and an app-wide `.any`
        // scan of a sheet-bearing window times the query out.
        DemoLaunch.waitForContent(containing: text, in: app, timeout: 0.1)
            ?? app.windows.descendants(matching: .staticText)
                .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
                .firstMatch
    }

    private func doneButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Done"].firstMatch
    }

    func testSurveySearchSheetKeepsItsDoneButtonAcrossTheLoad() {
        let app = DemoLaunch.launch(tab: "search")

        let field = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch
            : app.textFields.firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: field), "Search offered no field to type in.")
        field.click()
        field.typeText("Telescope")

        let result = element(containing: indexedSurveyName, in: app)
        XCTAssertTrue(DemoLaunch.wait(for: result), "Search never offered “\(indexedSurveyName)”.")
        result.click()

        // State one: the survey is still arriving.
        XCTAssertTrue(
            DemoLaunch.wait(for: doneButton(in: app)),
            "The survey sheet opened with no Done button."
        )

        // State two: it arrived. The chrome must not have gone with the change.
        XCTAssertTrue(
            DemoLaunch.wait(for: element(containing: loadedSurveyProof, in: app)),
            "The survey sheet never rendered the loaded survey."
        )
        XCTAssertTrue(
            doneButton(in: app).exists,
            "The survey sheet lost its Done button when the survey finished loading."
        )
        XCTAssertTrue(
            element(containing: loadedSurveyName, in: app).exists,
            "The loaded survey sheet is untitled."
        )

        // And it really dismisses, which is the whole point of asserting it.
        doneButton(in: app).click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { !self.element(containing: loadedSurveyProof, in: app).exists }),
            "Done did not close the survey sheet."
        )
    }
}
