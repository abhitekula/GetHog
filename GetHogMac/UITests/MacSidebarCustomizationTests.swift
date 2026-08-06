import XCTest

/// `TabViewCustomization` persistence: the sidebar the user rearranged is the
/// sidebar they get back.
///
/// `MacRootView` stores the customisation in `@AppStorage("sidebarCustomization")`
/// and stamps every section and destination with a `customizationID`. Whether
/// that round-trips is not something a unit test can answer — the drag, the
/// encode and the restore all happen inside SwiftUI — so it is measured here,
/// by reading the sidebar's order out of the accessibility tree before and
/// after a relaunch.
final class MacSidebarCustomizationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The sidebar's destinations, top to bottom.
    ///
    /// Read off the first outline only: on a split-view screen the *content*
    /// list is an outline too, and folding both together would report an order
    /// that is not the sidebar's.
    private func order(in app: XCUIApplication) -> [String] {
        let sidebar = app.windows.outlines.firstMatch
        return sidebar.descendants(matching: .staticText).allElementsBoundByIndex
            .compactMap { element in
                let value = "\(element.value ?? "")"
                return value.isEmpty ? nil : value
            }
    }

    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.windows.outlines.firstMatch.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate(title))
            .firstMatch
    }

    func testASidebarRearrangementSurvivesARelaunch() {
        let app = DemoLaunch.launch()
        DemoLaunch.settle(app)
        let before = order(in: app)
        print("PHASEB-SIDEBAR-ORDER before=\(before)")
        capture("h1-sidebar-before")
        XCTAssertTrue(before.contains("Dashboards"), "The sidebar did not render its destinations.")

        // Drag Web up above Dashboards — three rows, all inside the Analyze
        // section, so the move is one a customisation can legally hold.
        let source = row("Web", in: app)
        let target = row("Dashboards", in: app)
        guard source.exists, target.exists else {
            XCTFail("The sidebar is missing the rows this drag needs.")
            return
        }
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 1.0,
                thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.3))
            )
        DemoLaunch.pause(2)
        let after = order(in: app)
        print("PHASEB-SIDEBAR-ORDER after=\(after)")
        capture("h2-sidebar-after-drag")

        guard after != before else {
            // Recorded, not swallowed: a drag that does not take is a fact
            // about this harness or this control, and either way the
            // persistence half below has nothing to measure.
            XCTFail("The sidebar drag changed nothing; order stayed \(before).")
            return
        }

        app.terminate()
        let relaunched = DemoLaunch.launch()
        DemoLaunch.settle(relaunched)
        let restored = order(in: relaunched)
        print("PHASEB-SIDEBAR-ORDER restored=\(restored)")
        capture("h3-sidebar-after-relaunch")
        XCTAssertEqual(
            restored, after,
            "The rearranged sidebar did not survive a relaunch."
        )
    }
}
