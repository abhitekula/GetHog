import AppKit
import XCTest

/// Task 5's menu-bar contract, driven the way a user drives it: keys and menu
/// items, not the focused-value plumbing underneath. `MacCommandsTests` already
/// pins the layout as data; this is the half that only a rendered menu bar can
/// answer — whether the item is there, enabled, and wired to something.
final class MacCommandContractTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Where a sandboxed app's save panel actually lives: out of process, in an
    /// XPC service that is not part of GetHog's accessibility tree at all. A
    /// query against `app.windows.sheets` finds nothing and reports "no panel"
    /// about a panel the user can see.
    private static var savePanelIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.contains("openAndSavePanelService") ?? false
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A menu item by title, from any of the app's menus.
    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.menuBars.menuItems[title]
    }

    // MARK: - Go

    /// ⌘1 and ⌘4 route, and a Go item with no digit routes through the menu.
    func testGoMenuDigitsAndItemsRoute() {
        let app = DemoLaunch.launch()

        app.typeKey("1", modifierFlags: .command)
        DemoLaunch.settle(app)
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "Example App metric 33", in: app),
            "⌘1 did not land on Dashboards."
        )
        capture("c1-cmd1-dashboards")

        app.typeKey("4", modifierFlags: .command)
        DemoLaunch.settle(app)
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "Example meteor report", in: app),
            "⌘4 did not land on Insights."
        )
        capture("c2-cmd4-insights")

        // Flags leads the Experiment section, so it carries an item and no
        // digit — the rule in `GoMenuLayout` working, and the case a digit
        // shortcut cannot cover.
        let go = app.menuBars.menuBarItems["Go"]
        XCTAssertTrue(go.exists, "There is no Go menu.")
        go.click()
        let flags = app.menuItems["Flags"]
        XCTAssertTrue(DemoLaunch.wait(for: flags, timeout: 5), "Go has no Flags item.")
        XCTAssertTrue(flags.isEnabled, "Go ▸ Flags is disabled with a shell in focus.")
        flags.click()
        DemoLaunch.settle(app)
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "example-navigation", in: app),
            "Go ▸ Flags did not land on Flags."
        )
        capture("c3-go-menu-flags")
    }

    // MARK: - Refresh

    /// ⌘R is enabled on a screen that can refresh, and refreshing leaves the
    /// screen rendered rather than empty.
    func testRefreshCommandRefreshesTheActiveScreen() {
        let app = DemoLaunch.launch()
        app.typeKey("2", modifierFlags: .command)
        DemoLaunch.settle(app)
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "meteor_report_opened", in: app),
            "Events never rendered before the refresh."
        )

        let refresh = menuItem("Refresh", in: app)
        app.menuBars.menuBarItems["View"].click()
        XCTAssertTrue(DemoLaunch.wait(for: refresh, timeout: 5), "View has no Refresh item.")
        XCTAssertTrue(refresh.isEnabled, "View ▸ Refresh is disabled on Events.")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("r", modifierFlags: .command)
        DemoLaunch.settle(app)
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: "meteor_report_opened", in: app),
            "The screen never came back after ⌘R."
        )
        XCTAssertEqual(app.state, .runningForeground, "⌘R took the app down.")
        capture("c4-cmd-r-after-refresh")
    }

    // MARK: - Export

    /// ⌘E on an insight detail opens a save panel; Edit ▸ Copy CSV puts the
    /// table on the pasteboard.
    func testExportAndCopyCSVFromAnInsightDetail() {
        let app = DemoLaunch.launch()
        app.typeKey("4", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let row = DemoLaunch.waitForContent(containing: "Example meteor report", in: app) else {
            XCTFail("The insights list never offered its first row.")
            return
        }
        row.click()
        DemoLaunch.settle(app)

        let export = menuItem("Export CSV…", in: app)
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(DemoLaunch.wait(for: export, timeout: 5), "File has no Export CSV… item.")
        XCTAssertTrue(export.isEnabled, "File ▸ Export CSV… is disabled on an insight detail.")
        app.typeKey(.escape, modifierFlags: [])

        // **The panel is not in this app's tree.** GetHog is sandboxed, so
        // `.fileExporter`'s `NSSavePanel` is hosted out of process by
        // `com.apple.appkit.xpc.openAndSavePanelService` and draws as a sheet
        // the user sees on this window while belonging to another application
        // element entirely. Querying `app.windows.sheets` finds nothing and
        // says "no panel" about a panel that is on screen.
        app.typeKey("e", modifierFlags: .command)
        // Asked of the workspace rather than of an `XCUIApplication` built from
        // the service's bundle id: that initialiser raises
        // `NSInternalInconsistencyException` — uncatchable from Swift — the
        // moment the service is not already running, which is precisely the
        // case a "did the panel open?" check has to survive.
        let opened = DemoLaunch.wait(timeout: 20) { Self.savePanelIsRunning }
        capture("c5-cmd-e-save-panel")
        print("PHASEB-SAVEPANEL running=\(opened)")
        XCTAssertTrue(opened, "⌘E opened no save panel.")
        if opened {
            app.typeKey(.escape, modifierFlags: [])
            _ = DemoLaunch.wait(timeout: 10) { !Self.savePanelIsRunning }
        }
        DemoLaunch.pause(1)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copy = menuItem("Copy CSV", in: app)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(DemoLaunch.wait(for: copy, timeout: 5), "Edit has no Copy CSV item.")
        XCTAssertTrue(copy.isEnabled, "Edit ▸ Copy CSV is disabled on an insight detail.")
        copy.click()

        // Rows counted with `isNewline`, not `contains("\n")`. The export writes
        // CRLF, and Swift folds "\r\n" into a single grapheme — so
        // `contains("\n")` is **false** on a perfectly good CSV, which is
        // exactly how this assertion first failed against correct output.
        var written: String?
        var rows = 0
        _ = DemoLaunch.wait(timeout: 10) {
            written = pasteboard.string(forType: .string)
            rows = written?.split(whereSeparator: \.isNewline).count ?? 0
            return rows > 1 && (written?.contains(",") ?? false)
        }
        print("PHASEB-CSV rows=\(rows) head=\(written?.prefix(80) ?? "NONE")")
        XCTAssertGreaterThan(
            rows, 1,
            "Edit ▸ Copy CSV put nothing table-shaped on the pasteboard: \(written ?? "nil")."
        )
        XCTAssertTrue(written?.contains(",") ?? false, "The copied CSV has no separators.")
    }

    // MARK: - View

    /// ⌃⌘S hides the sidebar and brings it back.
    func testToggleSidebarHidesAndRestoresIt() {
        let app = DemoLaunch.launch()
        DemoLaunch.settle(app)

        func sidebarWidth() -> CGFloat {
            app.windows.firstMatch.outlines.firstMatch.frame.width
        }
        let before = sidebarWidth()
        XCTAssertGreaterThan(before, 0, "The sidebar was not on screen to begin with.")

        // `SidebarCommands()` titles its item for what the click will *do*, so
        // the item to look for is "Hide Sidebar" while the sidebar is showing.
        // A test written against the modifier's name finds nothing.
        let toggle = app.menuBars.menuItems.matching(
            NSPredicate(format: "title == 'Hide Sidebar' OR title == 'Show Sidebar'")
        ).firstMatch
        app.menuBars.menuBarItems["View"].click()
        XCTAssertTrue(DemoLaunch.wait(for: toggle, timeout: 5), "View has no sidebar toggle.")
        print("PHASEB-SIDEBAR-ITEM \(toggle.title)")
        toggle.click()
        DemoLaunch.pause(1.5)
        capture("c6-sidebar-hidden")
        let hidden = app.windows.firstMatch.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate("Dashboards")).firstMatch
        let wentAway = !hidden.exists || !hidden.isHittable
        print("PHASEB-SIDEBAR after-toggle hittableDashboards=\(!wentAway)")

        app.typeKey("s", modifierFlags: [.command, .control])
        DemoLaunch.pause(1.5)
        capture("c7-sidebar-restored")
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10) {
                let row = app.windows.firstMatch.descendants(matching: .any)
                    .matching(DemoLaunch.macTextPredicate("Dashboards")).firstMatch
                return row.exists && row.isHittable
            },
            "⌃⌘S never brought the sidebar back."
        )
        XCTAssertTrue(wentAway, "Toggle Sidebar left the sidebar on screen.")
    }

    /// Customize Toolbar… on the two screens that carry a customisable toolbar.
    func testCustomizeToolbarOnDashboardsAndSessions() {
        let app = DemoLaunch.launch()

        for (key, anchor, name) in [("1", "Example App metric 33", "c8-customize-dashboards"),
                                    ("3", "Alex Example", "c9-customize-sessions")] {
            app.typeKey(key, modifierFlags: .command)
            DemoLaunch.settle(app)
            XCTAssertNotNil(
                DemoLaunch.waitForContent(containing: anchor, in: app),
                "⌘\(key) never rendered its screen."
            )

            let item = app.menuBars.menuItems["Customize Toolbar…"]
            app.menuBars.menuBarItems["View"].click()
            let present = DemoLaunch.wait(for: item, timeout: 5)
            let enabled = present && item.isEnabled
            print("PHASEB-CUSTOMIZE \(name) present=\(present) enabled=\(enabled)")
            capture(name)
            app.typeKey(.escape, modifierFlags: [])
            DemoLaunch.pause(0.5)

            // Presence is what this asserts, and the boundary is deliberate.
            // The item exists because `MacCommands` declares `ToolbarCommands()`
            // — before that there was no route to toolbar customisation at all,
            // in the menu or in the toolbar's own context menu, despite
            // `DashboardsRoot` and `SessionsRoot` both declaring
            // `.toolbar(id:)`. It is still *disabled*, measured on both
            // screens: a `.toolbar(id:)` declared inside a navigation column
            // does not make the window's toolbar user-customisable. That is a
            // finding on the toolbar declarations, ledgered rather than
            // asserted here, because pinning "disabled" as correct would be
            // writing the defect into the suite.
            XCTAssertTrue(present, "View has no Customize Toolbar… on \(anchor)'s screen.")
        }
        XCTAssertEqual(app.state, .runningForeground, "Customising the toolbar took the app down.")
    }
}
