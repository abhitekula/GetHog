import XCTest

/// Native window management driven through the menus that own it.
///
/// Menu-item existence is never the result. Each command must change a window
/// count, visibility, frame, or rendered surface in the way a person invoking
/// that command can observe.
@MainActor
final class MacWindowRestorationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
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
        let app = DemoLaunch.launch(
            extraArguments: ["-ApplePersistenceIgnoreState", "YES"]
        )
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

        invoke("New Window", from: "File", in: app)
        XCTAssertTrue(DemoLaunch.wait(until: { app.windows.count == initialCount + 1 }))
        invoke("Minimize", from: "Window", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count == initialCount }),
            "Window ▸ Minimize left the minimized window in the visible window set."
        )
        XCTAssertTrue(app.windows.firstMatch.isHittable, "Minimizing the front window stranded the app.")
    }

    func testZoomFullScreenAndMoveResizeCommandsAchieveNativeBounds() {
        let app = DemoLaunch.launch(
            extraArguments: ["-ApplePersistenceIgnoreState", "YES"]
        )
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
    }

    // MARK: - Application and View commands

    func testSettingsAboutAndSidebarCommandsChangeRenderedSurfaces() {
        let app = DemoLaunch.launch()
        let mainWindow = app.windows.firstMatch

        func sidebarIsVisible() -> Bool {
            let outline = mainWindow.outlines.firstMatch
            let dashboards = outline.descendants(matching: .any)
                .matching(DemoLaunch.macTextPredicate("Dashboards")).firstMatch
            return outline.exists && outline.frame.width > 100 && dashboards.exists
        }

        if !sidebarIsVisible() {
            openMenu("View", in: app)
            let show = app.menuItems["Show Sidebar"]
            XCTAssertTrue(DemoLaunch.wait(for: show, timeout: 5))
            show.click()
            XCTAssertTrue(DemoLaunch.wait(until: sidebarIsVisible))
        }
        openMenu("View", in: app)
        let hide = app.menuItems["Hide Sidebar"]
        XCTAssertTrue(DemoLaunch.wait(for: hide, timeout: 5))
        hide.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { !sidebarIsVisible() }),
            "View ▸ Hide Sidebar left the source list visible."
        )
        openMenu("View", in: app)
        let show = app.menuItems["Show Sidebar"]
        XCTAssertTrue(DemoLaunch.wait(for: show, timeout: 5))
        show.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: sidebarIsVisible),
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
    }

    // MARK: - Product tear-offs

    func testDashboardAndRecordingTearOffsCreateRenderedWindows() {
        let app = DemoLaunch.launch()
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
    }
}
