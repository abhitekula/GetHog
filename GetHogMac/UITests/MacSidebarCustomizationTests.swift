import XCTest

/// The source list persists section expansion instead of a drag-reordered tab
/// arrangement. This exercises the control, storage, and restoration together.
final class MacSidebarCustomizationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func sectionToggle(_ title: String, in app: XCUIApplication) -> XCUIElement {
        for type: XCUIElement.ElementType in [.disclosureTriangle, .button, .staticText] {
            let match = app.windows.descendants(matching: type)
                .matching(DemoLaunch.macTextPredicate(title))
                .firstMatch
            if match.exists { return match }
        }
        return app.windows.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate(title))
            .firstMatch
    }

    private func sidebarRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.windows.outlines.firstMatch.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate(title))
            .firstMatch
    }

    func testSectionCollapsePersistsAcrossRelaunch() {
        let app = DemoLaunch.launch()
        DemoLaunch.settle(app)

        let toggle = sectionToggle("Data", in: app)
        guard DemoLaunch.wait(for: toggle) else {
            return XCTFail("The sidebar exposed no Data section disclosure control.")
        }
        let wasExpanded = sidebarRow("Warehouse", in: app).exists
        toggle.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.sidebarRow("Warehouse", in: app).exists != wasExpanded }),
            "Toggling Data did not change its destination visibility."
        )
        let changedExpansion = !wasExpanded

        app.terminate()
        let relaunched = DemoLaunch.launch()
        DemoLaunch.settle(relaunched)
        XCTAssertEqual(
            sidebarRow("Warehouse", in: relaunched).exists,
            changedExpansion,
            "The Data section did not restore its expansion state after relaunch."
        )

        // Return the durable preference to its starting state so this contract
        // remains independent of later sidebar tests.
        let restoredToggle = sectionToggle("Data", in: relaunched)
        guard DemoLaunch.wait(for: restoredToggle) else {
            return XCTFail("The relaunched sidebar exposed no Data disclosure control.")
        }
        restoredToggle.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                self.sidebarRow("Warehouse", in: relaunched).exists == wasExpanded
            }),
            "The test could not restore Data's original expansion state."
        )
    }
}
