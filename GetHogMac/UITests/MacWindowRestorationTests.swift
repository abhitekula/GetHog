import XCTest

/// Native window management driven through the menus that own it.
///
/// Menu-item existence is never the result. Each command must change a window
/// count, visibility, frame, or rendered surface in the way a person invoking
/// that command can observe.
@MainActor
final class MacWindowRestorationTests: XCTestCase {

    private static let isolatedLaunchArguments = ["-ApplePersistenceIgnoreState", "YES"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Every scenario starts from state restoration disabled and leaves one
    /// ordinary default-size main window behind. Terminate/relaunch is the only
    /// teardown that can recover every native state after an assertion aborts:
    /// a minimized window is not in `app.windows`, a full-screen transition may
    /// still own its Space, and an About panel can be frontmost without being a
    /// SwiftUI scene. The clean relaunch removes all of them at once.
    private func launchIsolated() -> XCUIApplication {
        let app = DemoLaunch.launch(extraArguments: Self.isolatedLaunchArguments)
        let sidebarWasVisible = sidebarIsVisible(in: app)

        addTeardownBlock { @MainActor in
            app.terminate()
            let reset = DemoLaunch.launch(extraArguments: Self.isolatedLaunchArguments)
            self.setSidebarVisible(sidebarWasVisible, in: reset)

            XCTAssertEqual(reset.windows.count, 1, "Teardown did not leave one ordinary main window.")
            let main = reset.windows.firstMatch
            XCTAssertEqual(main.frame.width, 1_200, accuracy: 3)
            XCTAssertEqual(main.frame.height, 780, accuracy: 3)
            XCTAssertGreaterThan(main.frame.minY, 0, "Teardown left the main window in full screen.")
            XCTAssertEqual(
                self.sidebarIsVisible(in: reset),
                sidebarWasVisible,
                "Teardown did not restore the scenario's initial sidebar visibility."
            )
        }
        return app
    }

    private func sidebarIsVisible(in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let outline = window.outlines.firstMatch
        let dashboards = outline.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate("Dashboards")).firstMatch
        return outline.exists && outline.frame.width > 100 && dashboards.exists
    }

    private func setSidebarVisible(_ visible: Bool, in app: XCUIApplication) {
        guard sidebarIsVisible(in: app) != visible else { return }
        openMenu("View", in: app)
        let title = visible ? "Show Sidebar" : "Hide Sidebar"
        let item = app.menuItems[title]
        XCTAssertTrue(DemoLaunch.wait(for: item, timeout: 5), "View has no \(title) command.")
        item.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.sidebarIsVisible(in: app) == visible }),
            "View ▸ \(title) did not reach the requested sidebar state."
        )
    }

    private func openMenu(_ title: String, in app: XCUIApplication) {
        let menu = app.menuBars.menuBarItems[title]
        XCTAssertTrue(menu.exists, "The menu bar has no \(title) menu.")
        menu.click()
    }

    private func invoke(_ itemTitle: String, from menuTitle: String, in app: XCUIApplication) {
        openMenu(menuTitle, in: app)
        let item = app.menuItems[itemTitle]
        XCTAssertTrue(
            DemoLaunch.wait(for: item, timeout: 5),
            "\(menuTitle) has no \(itemTitle) command."
        )
        XCTAssertTrue(item.isEnabled, "\(menuTitle) ▸ \(itemTitle) is disabled.")
        item.click()
    }

    private func invokeMoveAndResize(_ itemTitle: String, in app: XCUIApplication) {
        openMenu("Window", in: app)
        let moveAndResize = app.menuItems["Move & Resize"]
        XCTAssertTrue(
            DemoLaunch.wait(for: moveAndResize, timeout: 5),
            "Window has no Move & Resize submenu on this macOS version."
        )
        XCTAssertTrue(moveAndResize.isEnabled, "Window ▸ Move & Resize is disabled.")
        moveAndResize.hover()
        let item = app.menuItems[itemTitle]
        XCTAssertTrue(
            DemoLaunch.wait(for: item, timeout: 5),
            "Window ▸ Move & Resize has no \(itemTitle) command."
        )
        XCTAssertTrue(item.isEnabled, "Move & Resize ▸ \(itemTitle) is disabled.")
        item.click()
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, accuracy: CGFloat = 2) -> Bool {
        abs(lhs.minX - rhs.minX) <= accuracy
            && abs(lhs.minY - rhs.minY) <= accuracy
            && abs(lhs.width - rhs.width) <= accuracy
            && abs(lhs.height - rhs.height) <= accuracy
    }

    // MARK: - Standard File and Window commands

    func testNewCloseAndMinimizeChangeVisibleWindowCounts() {
        let app = launchIsolated()
        let initialCount = app.windows.count
        XCTAssertEqual(initialCount, 1, "A clean demo launch did not start with one main window.")
        XCTAssertEqual(app.windows.firstMatch.frame.width, 1_200, accuracy: 3)
        XCTAssertEqual(app.windows.firstMatch.frame.height, 780, accuracy: 3)

        invoke("New Window", from: "File", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount + 1 }),
            "File ▸ New Window did not create a second main window."
        )

        invoke("Close", from: "File", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount }),
            "File ▸ Close did not remove the frontmost new window."
        )

        // Minimize the only main window. There is then no hidden extra window
        // for the next scenario to inherit; the common teardown relaunches it
        // into the ordinary known state after proving it left the visible set.
        invoke("Minimize", from: "Window", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == 0 }),
            "Window ▸ Minimize left the only main window in the visible window set."
        )
        XCTAssertNotEqual(app.state, .notRunning, "Minimizing the main window terminated the app.")
    }

    func testZoomFullScreenAndMoveResizeCommandsAchieveNativeBounds() {
        let app = launchIsolated()
        let window = app.windows.firstMatch
        let original = window.frame

        invoke("Zoom", from: "Window", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { !self.framesMatch(window.frame, original) }),
            "Window ▸ Zoom did not change the window bounds."
        )
        let zoomed = window.frame
        XCTAssertGreaterThan(zoomed.width * zoomed.height, original.width * original.height)

        invoke("Zoom", from: "Window", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.framesMatch(window.frame, original) }),
            "A second Window ▸ Zoom did not restore the prior bounds."
        )

        invoke("Enter Full Screen", from: "View", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 20, until: {
                window.frame.minY < 5 && !self.framesMatch(window.frame, original)
            }),
            "View ▸ Enter Full Screen did not achieve full-screen bounds."
        )
        let displayFrame = window.frame
        XCTAssertGreaterThanOrEqual(displayFrame.width, original.width)
        XCTAssertGreaterThanOrEqual(displayFrame.height, original.height)

        invoke("Exit Full Screen", from: "View", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 20, until: { self.framesMatch(window.frame, original) }),
            "View ▸ Exit Full Screen did not restore the pre-full-screen bounds."
        )

        invokeMoveAndResize("Left", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                abs(window.frame.minX - displayFrame.minX) <= 3
                    && abs(window.frame.width - displayFrame.width / 2) <= 4
            }),
            "Move & Resize ▸ Left did not place the window in the display's left half."
        )

        invokeMoveAndResize("Return to Previous Size", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.framesMatch(window.frame, original) }),
            "Return to Previous Size did not restore the pre-tile frame."
        )

        invokeMoveAndResize("Right", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                abs(window.frame.minX - displayFrame.midX) <= 4
                    && abs(window.frame.width - displayFrame.width / 2) <= 4
            }),
            "Move & Resize ▸ Right did not place the window in the display's right half."
        )
        invokeMoveAndResize("Return to Previous Size", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.framesMatch(window.frame, original) }),
            "Final Return to Previous Size did not leave the main window in its initial frame."
        )
    }

    // MARK: - Application and View commands

    func testSettingsAboutAndSidebarCommandsChangeRenderedSurfaces() {
        let app = launchIsolated()
        let sidebarWasVisible = sidebarIsVisible(in: app)

        setSidebarVisible(true, in: app)
        openMenu("View", in: app)
        let hide = app.menuItems["Hide Sidebar"]
        XCTAssertTrue(DemoLaunch.wait(for: hide, timeout: 5))
        hide.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { !self.sidebarIsVisible(in: app) }),
            "View ▸ Hide Sidebar left the source list visible."
        )
        openMenu("View", in: app)
        let show = app.menuItems["Show Sidebar"]
        XCTAssertTrue(DemoLaunch.wait(for: show, timeout: 5))
        show.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.sidebarIsVisible(in: app) }),
            "View ▸ Show Sidebar did not restore the source list."
        )

        let initialCount = app.windows.count
        invoke("Settings…", from: "GetHog", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount + 1 }),
            "GetHog ▸ Settings… did not open a settings window."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: DemoLaunch.elements(labelled: "Account", in: app).firstMatch),
            "The new settings window did not render its Account pane."
        )
        invoke("Close", from: "File", in: app)
        XCTAssertTrue(DemoLaunch.wait(until: { app.windows.count == initialCount }))

        invoke("About GetHog", from: "GetHog", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount + 1 }),
            "GetHog ▸ About GetHog did not open the native About window."
        )
        let aboutWindow = app.windows.matching(
            NSPredicate(format: "label CONTAINS %@", "About GetHog")
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: aboutWindow, timeout: 5),
            "The additional window was not the native About GetHog surface."
        )
        invoke("Close", from: "File", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount }),
            "File ▸ Close did not dismiss the About window."
        )
        setSidebarVisible(sidebarWasVisible, in: app)
    }

    // MARK: - Product tear-offs

    func testDashboardAndRecordingTearOffsCreateRenderedWindows() {
        let app = launchIsolated()
        let initialCount = app.windows.count

        app.typeKey("1", modifierFlags: .command)
        DemoLaunch.settle(app)
        let dashboard = app.buttons["gethog.dashboard-card.725101"].firstMatch
        for _ in 0..<8 where !dashboard.exists {
            app.scrollViews["gethog.dashboard-hub"].swipeUp(velocity: .slow)
        }
        XCTAssertTrue(DemoLaunch.wait(for: dashboard), "The demo dashboard row never appeared.")
        dashboard.rightClick()
        let dashboardTearOff = app.menuItems["Open in new window"]
        XCTAssertTrue(DemoLaunch.wait(for: dashboardTearOff, timeout: 5))
        dashboardTearOff.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount + 1 }),
            "The dashboard tear-off created no second window."
        )
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                app.windows.descendants(matching: .any)
                    .matching(NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@",
                        DemoLaunch.firstTileTitle,
                        DemoLaunch.firstTileTitle
                    )).count >= 2
            }),
            "The dashboard tear-off never rendered the selected dashboard."
        )
        let dashboardWindow = app.windows.matching(
            NSPredicate(format: "label CONTAINS %@", "Example App metric 33")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: dashboardWindow, timeout: 5))
        XCTAssertEqual(dashboardWindow.frame.width, 1_000, accuracy: 3)
        XCTAssertEqual(dashboardWindow.frame.height, 700, accuracy: 3)
        invoke("Close", from: "File", in: app)
        XCTAssertTrue(DemoLaunch.wait(until: { app.windows.count == initialCount }))

        app.typeKey("3", modifierFlags: .command)
        DemoLaunch.settle(app)
        guard let recording = DemoLaunch.waitForContent(containing: "Alex Example", in: app) else {
            return XCTFail("The demo recording row never appeared.")
        }
        recording.rightClick()
        let recordingTearOff = app.menuItems["Open in new window"]
        XCTAssertTrue(DemoLaunch.wait(for: recordingTearOff, timeout: 5))
        recordingTearOff.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount + 1 }),
            "The recording tear-off created no second window."
        )
        let personWindow = app.windows.matching(
            NSPredicate(format: "label CONTAINS %@", "Alex Example")
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: personWindow, timeout: 30),
            "The recording tear-off never became the selected person's window."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: personWindow.buttons["Session replay"], timeout: 30),
            "The recording tear-off never rendered its replay stage."
        )
        XCTAssertEqual(personWindow.frame.width, 1_000, accuracy: 3)
        XCTAssertEqual(personWindow.frame.height, 700, accuracy: 3)
        invoke("Close", from: "File", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount }),
            "File ▸ Close did not dismiss the recording tear-off."
        )
    }
}
