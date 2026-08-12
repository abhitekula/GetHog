import XCTest

/// The source list persists section expansion instead of a drag-reordered tab
/// arrangement. This exercises the control, storage, and restoration together.
@MainActor
final class MacSidebarCustomizationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func sidebar(in app: XCUIApplication) -> XCUIElement {
        app.windows.descendants(matching: .any)["gethog.mac-sidebar"].firstMatch
    }

    private func sectionToggle(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let sourceList = sidebar(in: app)
        for type: XCUIElement.ElementType in [.disclosureTriangle, .button, .staticText] {
            let match = sourceList.descendants(matching: type)
                .matching(DemoLaunch.macTextPredicate(title))
                .firstMatch
            if match.exists { return match }
        }
        return sourceList.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate(title))
            .firstMatch
    }

    private func sidebarRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let rows = sidebar(in: app).descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate(title))
        if let hittable = rows.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            return hittable
        }
        return rows.firstMatch
    }

    private func go(_ title: String, in app: XCUIApplication) {
        let go = app.menuBars.menuBarItems["Go"]
        XCTAssertTrue(go.exists, "The menu bar exposed no Go menu.")
        go.click()
        let item = app.menuItems[title]
        XCTAssertTrue(DemoLaunch.wait(for: item, timeout: 5), "Go exposed no \(title) item.")
        item.click()
        DemoLaunch.settle(app)
    }

    private func sidebarIsVisible(_ app: XCUIApplication) -> Bool {
        let sourceList = sidebar(in: app)
        return sourceList.exists && sourceList.frame.width > 100
    }

    private func assertSidebarCommand(
        _ expected: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.menuBars.menuBarItems["View"].click()
        let command = app.menuItems[expected]
        XCTAssertTrue(
            DemoLaunch.wait(for: command, timeout: 5),
            "Rendered sidebar state exposed no \(expected) command.",
            file: file,
            line: line
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    private func setSidebarVisible(_ visible: Bool, in app: XCUIApplication) {
        guard sidebarIsVisible(app) != visible else { return }
        app.menuBars.menuBarItems["View"].click()
        let title = visible ? "Show Sidebar" : "Hide Sidebar"
        let command = app.menuItems[title]
        XCTAssertTrue(DemoLaunch.wait(for: command, timeout: 5), "View exposed no \(title).")
        command.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.sidebarIsVisible(app) == visible }),
            "View ▸ \(title) did not reach the requested rendered state."
        )
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

    func testSidebarCommandAndKeyboardShortcutShareRenderedState() {
        let app = DemoLaunch.launch()
        defer { app.terminate() }
        DemoLaunch.settle(app)

        let startedVisible = sidebarIsVisible(app)
        assertSidebarCommand(startedVisible ? "Hide Sidebar" : "Show Sidebar", in: app)

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.sidebarIsVisible(app) != startedVisible }),
            "⌃⌘S did not toggle the rendered sidebar."
        )
        assertSidebarCommand(startedVisible ? "Show Sidebar" : "Hide Sidebar", in: app)

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.sidebarIsVisible(app) == startedVisible }),
            "A second ⌃⌘S did not restore the rendered sidebar."
        )
        assertSidebarCommand(startedVisible ? "Hide Sidebar" : "Show Sidebar", in: app)
    }

    /// A destination reached without clicking its sidebar row must still leave
    /// that row visible and selected. Go, links, launch routing, and restored
    /// selection all terminate in the shell's one `open(_:)` policy; this
    /// drives the ordinary Go path, then relaunches with the selected row hidden
    /// to exercise restoration rather than a test-only defaults seam.
    func testOpeningDestinationExpandsAndRevealsItsOwningSection() {
        var app = DemoLaunch.launch()
        defer { app.terminate() }
        DemoLaunch.settle(app)

        let data = sectionToggle("Data", in: app)
        guard DemoLaunch.wait(for: data) else {
            return XCTFail("The sidebar exposed no Data disclosure control.")
        }
        let dataWasExpanded = sidebarRow("Warehouse", in: app).exists
        if dataWasExpanded { data.click() }
        XCTAssertTrue(
            DemoLaunch.wait(until: { !self.sidebarRow("Warehouse", in: app).exists }),
            "The test could not begin with Data collapsed."
        )

        let monitorWasExpanded = sidebarRow("Errors", in: app).exists
        setSidebarVisible(false, in: app)
        go("Warehouse", in: app)
        let selectedRoot = app.windows.descendants(matching: .any)["gethog.root.warehouse"]
            .firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: selectedRoot),
            "Go did not select Warehouse while the source list was hidden."
        )
        setSidebarVisible(true, in: app)
        let warehouse = sidebarRow("Warehouse", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(for: warehouse),
            "Showing the source list did not expose Data's selected Warehouse row."
        )
        XCTAssertTrue(
            DemoLaunch.wait(until: { warehouse.isHittable }),
            "Showing the source list did not reveal the selected Warehouse row."
        )
        XCTAssertTrue(
            warehouse.isSelected,
            "Showing the source list revealed Warehouse without its selected state."
        )
        XCTAssertEqual(
            sidebarRow("Errors", in: app).exists,
            monitorWasExpanded,
            "Opening Warehouse changed an unrelated Monitor expansion choice."
        )

        data.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { !self.sidebarRow("Warehouse", in: app).exists }),
            "The selected Warehouse row did not become hidden for the restoration oracle."
        )

        app.terminate()
        app = DemoLaunch.launch()
        let restored = sidebarRow("Warehouse", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(for: restored),
            "Restoring Warehouse did not reopen its owning Data section."
        )
        XCTAssertTrue(restored.isHittable, "Restoring Warehouse did not reveal its selected row.")

        // Restore the durable section choices this contract intentionally
        // exercised so later suites inherit no test-authored navigation state.
        let restoredData = sectionToggle("Data", in: app)
        if DemoLaunch.wait(for: restoredData),
           sidebarRow("Warehouse", in: app).exists != dataWasExpanded {
            restoredData.click()
        }
    }
}
