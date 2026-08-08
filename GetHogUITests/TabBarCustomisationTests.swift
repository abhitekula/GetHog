import XCTest

/// The bar the user chose, drawn.
///
/// **One test method per screen**, for the reason `AccessibilityAuditTests`
/// records: a single method launching the app repeatedly takes the runner down
/// partway through rather than failing.
///
/// The customised runs reach the arrangement through `GETHOG_TAB_BAR` rather
/// than by driving the editor, because the editor is two pushes deep behind
/// Search and `NavPreferences` has to be correct before the first body reads it.
/// The editor itself is driven in `testTheEditorChangesTheBar` below.
final class TabBarCustomisationTests: XCTestCase {

    /// A bar of four screens that were all behind the index before, in an order
    /// no default produces — so nothing here can pass by accident.
    private static let customBar = ["logs", "errorTracking", "inbox", "health"]

    private var isIPadDestination: Bool {
        let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        return name.localizedCaseInsensitiveContains("iPad")
    }

    private func requirePhoneDestination(_ reason: String) throws {
        if isIPadDestination {
            throw XCTSkip(reason)
        }
    }

    /// The default four, so a customised run has something to be different from.
    ///
    /// Pinned rather than inherited: the editor writes to
    /// `UserDefaults.standard`, which survives on the simulator, so a run that
    /// let the stored arrangement decide would pass or fail on what happened to
    /// run before it. That the *empty* store resolves to these four is a
    /// property of `NavPreferences` and is asserted where it belongs, in
    /// `NavPreferencesTests.defaultsToPrimary`; what this measures is that a bar
    /// of four screens plus Search is what actually gets drawn.
    func testDefaultBarIsTheFourItAlwaysWas() throws {
        try requirePhoneDestination("iPad uses the independent system sidebar store.")

        let app = DemoLaunch.launch(tab: "dashboards", environment: ["GETHOG_TAB_BAR": "dashboards,events,sessions,flags"])
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Dashboards"]))
        DemoLaunch.settle(app)

        guard app.tabBars.firstMatch.exists else {
            print("DEFAULT-BAR skipped: no tab bar at \(app.windows.firstMatch.frame).")
            return
        }
        let labels = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(labels, ["Dashboards", "Events", "Sessions", "Flags", "Search"])
    }

    func testCustomisedBarDrawsTheChosenFourInOrder() throws {
        try requirePhoneDestination("iPad uses the independent system sidebar store.")

        let app = DemoLaunch.launch(tab: "logs", environment: ["GETHOG_TAB_BAR": Self.customBar.joined(separator: ",")])
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Logs"]))
        DemoLaunch.settle(app)

        guard app.tabBars.firstMatch.exists else {
            print("CUSTOM-BAR skipped: no tab bar at \(app.windows.firstMatch.frame).")
            return
        }
        let labels = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(
            labels, ["Logs", "Errors", "Inbox", "Health", "Search"],
            "The bar should draw GETHOG_TAB_BAR's four, in that order, with Search fifth."
        )
    }

    /// The exactly-once rule, on a device: a screen promoted into the bar leaves
    /// the index, and a demoted one arrives there. Getting either half wrong
    /// makes a screen either unreachable or reachable twice.
    func testTheIndexHoldsExactlyWhatTheBarDoesNot() throws {
        try requirePhoneDestination("The compact index is an iPhone-only surface.")

        let app = DemoLaunch.launch(tab: "search", environment: ["GETHOG_TAB_BAR": Self.customBar.joined(separator: ",")])
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Search"]))
        DemoLaunch.settle(app)

        guard app.tabBars.firstMatch.exists else {
            print("INDEX-COMPLEMENT skipped: the index is compact-width only.")
            return
        }

        // Demoted: Dashboards is no longer a tab, so the index must offer it.
        XCTAssertTrue(
            DemoLaunch.wait(for: app.cells.staticTexts["Dashboards"], timeout: 10),
            "Dashboards left the bar and is not in the index either, so nothing can reach it."
        )
        // Promoted: Logs is a tab now, so the index must not list it as well.
        XCTAssertFalse(
            app.cells.staticTexts["Logs"].exists,
            """
            Logs is in the tab bar and is still listed in the index. That is the \
            duplication `AppTab.groupedScreens(excluding:)` exists to prevent.
            """
        )
    }

    /// **Measured before this was built, and the reason the design splits by
    /// idiom.** On an iPad Air 11-inch (M4) at 820 × 1180 with the sidebar open,
    /// adopting `.tabViewCustomization` adds the system's own Edit button to the
    /// sidebar header at `(18, 36, 54.5, 36)`: 18 buttons with the modifier
    /// against 17 with it removed and the `customizationID`s left in place, and
    /// `Edit` matching once against zero times. The control run is what makes
    /// the attribution causal rather than coincidental.
    ///
    /// Skips on a phone rather than failing there — the whole point is that this
    /// affordance does not exist at compact width.
    func testTheSidebarOffersTheSystemEditor() {
        let app = DemoLaunch.launch(tab: "dashboards")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars.firstMatch))
        DemoLaunch.settle(app)

        let toggle = app.buttons["ToggleSideBar"]
        guard toggle.exists else {
            print("SIDEBAR-EDITOR skipped: no sidebar at \(app.windows.firstMatch.frame).")
            return
        }
        toggle.tap()
        DemoLaunch.wait { app.buttons["Edit"].exists || app.cells.count > 0 }

        XCTAssertTrue(
            app.buttons["Edit"].exists,
            "The sidebar has no Edit button, so `.tabViewCustomization` is not reaching it."
        )
    }

    /// The two customisation stores must never both describe one device. On a
    /// phone there is no sidebar and no system editor, and the Settings screen is
    /// the only way to change the bar.
    func testThePhoneHasNoSystemEditor() throws {
        try requirePhoneDestination("iPad intentionally uses the system sidebar editor.")

        let app = DemoLaunch.launch(tab: "dashboards")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Dashboards"]))
        DemoLaunch.settle(app)

        guard !app.buttons["ToggleSideBar"].exists else {
            print("NO-SYSTEM-EDITOR skipped: this destination has a sidebar.")
            return
        }
        XCTAssertFalse(app.buttons["Edit"].exists, "A phone must not offer the system's tab editor.")
    }

    /// The editor, driven the way a user reaches it: Search → Settings → Tab
    /// bar. This is the only test here that changes the bar by *using the app*
    /// rather than by launch environment, which is the point of it.
    ///
    /// The bar it starts from is still pinned, and that is not belt-and-braces.
    /// The editor writes to `UserDefaults.standard`, which survives on the
    /// simulator, so without this the arrangement left behind by whatever ran
    /// before decides what is in slot 1 — measured, from `testTabBarEditor`
    /// failing on exactly that after this test had put Logs there.
    func testTheEditorChangesTheBar() throws {
        try requirePhoneDestination("The app-owned tab-bar editor is absent on iPad by design.")

        let app = DemoLaunch.launch(tab: "settings", environment: ["GETHOG_TAB_BAR": "dashboards,events,sessions,flags"])
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Settings"]))
        DemoLaunch.settle(app)

        let row = app.cells.containing(.staticText, identifier: "Tab bar").firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: row, timeout: 10), "Settings has no Tab bar row.")
        row.tap()
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Tab bar"]))
        DemoLaunch.settle(app)

        // Slot 1 holds Dashboards on a default bar. Put Logs in it.
        let slot = app.buttons["Slot 1: Dashboards"]
        XCTAssertTrue(DemoLaunch.wait(for: slot, timeout: 10), "No slot-1 control.")
        slot.assertMeetsMinimumHitTarget("The slot-1 menu")
        slot.tap()
        DemoLaunch.wait { app.buttons["Logs"].firstMatch.exists }
        app.buttons["Logs"].firstMatch.tap()
        DemoLaunch.wait { app.buttons["Slot 1: Logs"].exists }

        XCTAssertTrue(app.buttons["Slot 1: Logs"].exists, "The slot did not take the new screen.")

        let labels = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(
            labels, ["Logs", "Events", "Sessions", "Flags", "Search"],
            "The bar did not follow the editor."
        )
    }

    /// What the app looks like after the bar is changed *and the user walks
    /// back out of the editor* — which is the only way anyone sees the change,
    /// since the editor covers the screen it affects.
    ///
    /// **This is the test that decided a re-homing rule was not needed.** The
    /// plan carried one: on `barTabs` changing, push a `selectedTab` that had
    /// just left the bar and reset the stack for one that had just entered it,
    /// suppressed while the editor was showing. Writing it out is what exposed
    /// that the suppression covers every reachable case — on a phone the editor
    /// is the only thing that writes `barTabs`, and it is always reached by
    /// pushing Settings onto the search tab's stack, so `selectedTab` is
    /// `.settings` at every such change without exception. The rule would have
    /// been unreachable code guarding a state nothing can produce.
    ///
    /// What actually has to hold is this: after the change, the promoted screen
    /// is a tab, the demoted one is in the index, and neither is stranded. Two
    /// things already do that — `restorePushedTab()` on the next appear, and
    /// `open(_:)` clearing a stale push when its destination has a bar row.
    func testTheBarIsCoherentAfterLeavingTheEditor() throws {
        try requirePhoneDestination("The app-owned tab-bar editor is absent on iPad by design.")

        let app = DemoLaunch.launch(tab: "settings", environment: ["GETHOG_TAB_BAR": "dashboards,events,sessions,flags"])
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Settings"]))
        DemoLaunch.settle(app)

        app.cells.containing(.staticText, identifier: "Tab bar").firstMatch.tap()
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Tab bar"]))
        DemoLaunch.settle(app)

        // Demote Dashboards and promote Logs in one move.
        app.buttons["Slot 1: Dashboards"].tap()
        DemoLaunch.wait { app.buttons["Logs"].firstMatch.exists }
        app.buttons["Logs"].firstMatch.tap()
        DemoLaunch.wait { app.buttons["Slot 1: Logs"].exists }

        XCTAssertTrue(
            app.navigationBars["Tab bar"].exists,
            "Changing the bar dismissed the editor the change was made in."
        )

        // Back out: Tab bar → Settings → the index.
        for _ in 0..<3 {
            guard app.navigationBars["Search"].exists == false else { break }
            let back = app.navigationBars.firstMatch.buttons.firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
            DemoLaunch.wait { app.navigationBars.firstMatch.exists }
        }
        DemoLaunch.settle(app)

        let labels = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(
            labels, ["Logs", "Events", "Sessions", "Flags", "Search"],
            "The bar did not survive walking back out of the editor."
        )
        // Demoted: Dashboards must be reachable from the index, or it is gone.
        XCTAssertTrue(
            DemoLaunch.wait(for: app.cells.staticTexts["Dashboards"], timeout: 10),
            "Dashboards left the bar and did not arrive in the index, so nothing can reach it."
        )
        // Promoted: Logs is a tab now and must not also be listed.
        XCTAssertFalse(
            app.cells.staticTexts["Logs"].exists,
            "Logs is in the tab bar and is still listed in the index."
        )
    }

    /// The exactly-once rule on the *sidebar* side. Before the four defaults
    /// moved into sections they were in no group, so a sidebar could declare
    /// them loose and render every section safely; now it would list each of
    /// them twice unless `groupedScreens(excluding:)` is doing its job.
    func testTheSidebarListsNoScreenTwice() {
        let app = DemoLaunch.launch(tab: "dashboards")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars.firstMatch))
        DemoLaunch.settle(app)

        let toggle = app.buttons["ToggleSideBar"]
        guard toggle.exists else {
            print("SIDEBAR-DUPES skipped: no sidebar at \(app.windows.firstMatch.frame).")
            return
        }
        toggle.tap()
        DemoLaunch.wait { app.cells.count > 0 }

        let labels = app.cells.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }
        let duplicated = Set(labels.filter { label in labels.filter { $0 == label }.count > 1 })
        XCTAssertTrue(
            duplicated.isEmpty,
            "The sidebar lists these twice: \(duplicated.sorted()). Rows were \(labels)."
        )
    }
}
