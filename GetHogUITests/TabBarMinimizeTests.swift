import XCTest

/// Keeps the semantic end of compact screens clear of the controls the floating
/// iOS tab bar actually draws.
///
/// The tab bar's accessibility container includes transparent material around
/// its controls, so its frame is not the obstruction. These tests union the real
/// buttons in both rendered states: the one-button collapsed pill and the five
/// expanded tab controls. Search and Settings then prove that a center tap opens
/// the row it names; Health's final freshness row is informational and is never
/// treated as a control.
@MainActor
final class TabBarMinimizeTests: XCTestCase {

    func testSearchLastDestinationCenterClearsCollapsedAndExpandedTabControls() throws {
        try assertBottomTargetClearsFloatingBar(
            onTab: "search",
            titled: "Search",
            target: { app in self.listRow(labelled: "Settings", in: app) },
            kind: .actionable(expectedNavigationTitle: "Settings")
        )
    }

    func testSettingsLastActionCenterClearsCollapsedAndExpandedTabControls() throws {
        try assertBottomTargetClearsFloatingBar(
            onTab: "settings",
            titled: "Settings",
            target: { app in self.listRow(labelled: "About GetHog", in: app) },
            kind: .actionable(expectedNavigationTitle: "About")
        )
    }

    func testHealthLastSemanticRowClearsCollapsedAndExpandedTabControls() throws {
        try assertBottomTargetClearsFloatingBar(
            onTab: "health",
            titled: "Health",
            target: { app in
                app.staticTexts
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Data updated"))
                    .firstMatch
            },
            kind: .informational
        )
    }

    func testSearchLastDestinationCenterClearsCollapsedAndExpandedTabControlsInDarkMode() throws {
        try assertBottomTargetClearsFloatingBar(
            onTab: "search",
            titled: "Search",
            target: { app in self.listRow(labelled: "Settings", in: app) },
            kind: .actionable(expectedNavigationTitle: "Settings"),
            extraArguments: ["-AppleInterfaceStyle", "Dark"]
        )
    }

    func testSettingsLastActionCenterClearsCollapsedAndExpandedTabControlsInDarkMode() throws {
        try assertBottomTargetClearsFloatingBar(
            onTab: "settings",
            titled: "Settings",
            target: { app in self.listRow(labelled: "About GetHog", in: app) },
            kind: .actionable(expectedNavigationTitle: "About"),
            extraArguments: ["-AppleInterfaceStyle", "Dark"]
        )
    }

    func testHealthLastSemanticRowClearsCollapsedAndExpandedTabControlsInDarkMode() throws {
        try assertBottomTargetClearsFloatingBar(
            onTab: "health",
            titled: "Health",
            target: { app in
                app.staticTexts
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Data updated"))
                    .firstMatch
            },
            kind: .informational,
            extraArguments: ["-AppleInterfaceStyle", "Dark"]
        )
    }

    // MARK: - Oracle

    private enum BottomTargetKind {
        case actionable(expectedNavigationTitle: String)
        case informational
    }

    private func assertBottomTargetClearsFloatingBar(
        onTab tab: String,
        titled title: String,
        target: @MainActor (XCUIApplication) -> XCUIElement,
        kind: BottomTargetKind,
        extraArguments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        if deviceName.localizedCaseInsensitiveContains("iPad") {
            throw XCTSkip(
                "Floating tab-bar minimisation is an iPhone behavior; iPad uses the system sidebar."
            )
        }

        let app = DemoLaunch.launch(tab: tab, extraArguments: extraArguments, file: file, line: line)
        guard require(
            DemoLaunch.wait(for: app.navigationBars[title]),
            "\(title) never rendered, so bottom-chrome geometry was not measured.",
            file: file,
            line: line
        ) else { return }
        DemoLaunch.settle(app)

        let bar = app.tabBars.firstMatch
        guard require(
            bar.exists,
            "\(title) has no compact tab bar to measure.",
            file: file,
            line: line
        ) else { return }

        let windowFrame = app.windows.firstMatch.frame
        guard require(
            windowFrame.width > 0 && windowFrame.height > 0,
            "\(title) published no usable window frame.",
            file: file,
            line: line
        ) else { return }
        guard require(
            bar.frame.midY > windowFrame.midY,
            "\(title) put its tab bar at \(bar.frame) in \(windowFrame), not over bottom content.",
            file: file,
            line: line
        ) else { return }
        guard require(
            bar.buttons.count == 5,
            "\(title) should begin with five expanded tab buttons; found \(bar.buttons.count).",
            file: file,
            line: line
        ) else { return }

        // Scroll only upward through the screen, bounded. The target may not
        // exist yet because SwiftUI's List has not built rows below the fold.
        // `isHittable` is deliberately not the loop predicate: XCTest can throw
        // while asking it about a lazily-created offscreen row.
        for _ in 0..<16 {
            if collapsedStateIsReady(
                bar: bar,
                target: target(app),
                windowFrame: windowFrame,
                requiresLowerHalf: tab == "search"
            ) {
                break
            }
            if tab == "search" {
                app.swipeUp(velocity: .slow)
            } else {
                app.swipeUp()
            }
            DemoLaunch.pause(0.3)
        }
        DemoLaunch.pause(0.5)

        let collapsedControl = bar.buttons.firstMatch
        guard require(
            bar.buttons.count == 1,
            "\(title) never reached the one-button collapsed state; found \(bar.buttons.count).",
            file: file,
            line: line
        ) else { return }
        guard require(
            (collapsedControl.value as? String) == "Collapsed",
            "\(title)'s sole tab control did not publish the required Collapsed value.",
            file: file,
            line: line
        ) else { return }

        let collapsedTarget = target(app)
        guard let collapsedTargetFrame = visibleFrame(
            of: collapsedTarget,
            in: windowFrame,
            title: title,
            state: "collapsed",
            file: file,
            line: line
        ) else { return }
        if tab == "search" {
            guard require(
                collapsedTargetFrame.midY > windowFrame.midY,
                "Search's last screen destination was not measured in the lower half: "
                    + "target=\(collapsedTargetFrame) window=\(windowFrame).",
                file: file,
                line: line
            ) else { return }
        }
        let collapsedObstruction = tabBarObstruction(bar)
        guard require(
            !collapsedObstruction.isNull,
            "\(title)'s collapsed tab bar has no rendered button union.",
            file: file,
            line: line
        ) else { return }

        let collapsedCenter = CGPoint(
            x: collapsedTargetFrame.midX,
            y: collapsedTargetFrame.midY
        )
        logGeometry(
            title: title,
            state: "collapsed",
            targetFrame: collapsedTargetFrame,
            center: collapsedCenter,
            obstruction: collapsedObstruction,
            buttonCount: bar.buttons.count,
            windowFrame: windowFrame
        )
        XCTAssertFalse(
            collapsedObstruction.contains(collapsedCenter),
            """
            BOTTOM-CHROME-OVERLAP \(title) collapsed target=\(collapsedTargetFrame) \
            center=\(collapsedCenter) controls=\(collapsedObstruction) window=\(windowFrame)
            """,
            file: file,
            line: line
        )
        guard !collapsedObstruction.contains(collapsedCenter) else { return }

        // Tapping the selected collapsed control expands the real five-button
        // bar without changing the list offset. The second measurement must
        // therefore protect the exact content position proved above.
        collapsedControl.tap()
        guard require(
            DemoLaunch.wait(timeout: 8) { bar.buttons.count == 5 },
            "\(title)'s collapsed control did not expand the bar to five buttons.",
            file: file,
            line: line
        ) else { return }
        guard require(
            bar.buttons.count == 5,
            "\(title) expanded to \(bar.buttons.count) buttons instead of five.",
            file: file,
            line: line
        ) else { return }

        let expandedTarget = target(app)
        guard let expandedTargetFrame = visibleFrame(
            of: expandedTarget,
            in: windowFrame,
            title: title,
            state: "expanded",
            file: file,
            line: line
        ) else { return }
        let expandedObstruction = tabBarObstruction(bar)
        guard require(
            !expandedObstruction.isNull,
            "\(title)'s expanded tab bar has no rendered button union.",
            file: file,
            line: line
        ) else { return }

        let expandedCenter = CGPoint(
            x: expandedTargetFrame.midX,
            y: expandedTargetFrame.midY
        )
        logGeometry(
            title: title,
            state: "expanded",
            targetFrame: expandedTargetFrame,
            center: expandedCenter,
            obstruction: expandedObstruction,
            buttonCount: bar.buttons.count,
            windowFrame: windowFrame
        )
        XCTAssertFalse(
            expandedObstruction.contains(expandedCenter),
            """
            BOTTOM-CHROME-OVERLAP \(title) expanded target=\(expandedTargetFrame) \
            center=\(expandedCenter) controls=\(expandedObstruction) window=\(windowFrame)
            """,
            file: file,
            line: line
        )
        guard !expandedObstruction.contains(expandedCenter) else { return }

        switch kind {
        case let .actionable(expectedNavigationTitle):
            guard require(
                expandedTarget.isHittable,
                "\(title)'s actionable bottom row is geometrically visible but not hittable.",
                file: file,
                line: line
            ) else { return }
            expandedTarget.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
            XCTAssertTrue(
                DemoLaunch.wait(for: app.navigationBars[expectedNavigationTitle], timeout: 10),
                """
                BOTTOM-CHROME-ROUTING Tapping \(title)'s bottom-row center did not open \
                \(expectedNavigationTitle). Visible titles: \
                \(app.navigationBars.allElementsBoundByIndex.map { $0.identifier })
                """,
                file: file,
                line: line
            )

        case .informational:
            // Health's final freshness row communicates state. Geometry is its
            // whole contract here; no tappability or enabled-state claim is made.
            break
        }
    }

    private func listRow(labelled label: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: label).firstMatch
    }

    private func collapsedStateIsReady(
        bar: XCUIElement,
        target: XCUIElement,
        windowFrame: CGRect,
        requiresLowerHalf: Bool
    ) -> Bool {
        guard bar.buttons.count == 1,
              (bar.buttons.firstMatch.value as? String) == "Collapsed",
              target.exists
        else { return false }

        let frame = target.frame
        guard frame.width > 0,
              frame.height > 0,
              windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        else { return false }
        return !requiresLowerHalf || frame.midY > windowFrame.midY
    }

    private func visibleFrame(
        of target: XCUIElement,
        in windowFrame: CGRect,
        title: String,
        state: String,
        file: StaticString,
        line: UInt
    ) -> CGRect? {
        guard require(
            target.exists,
            "\(title)'s bottom target was never found in the \(state) state.",
            file: file,
            line: line
        ) else { return nil }

        let frame = target.frame
        guard require(
            frame.width > 0 && frame.height > 0,
            "\(title)'s bottom target published the zero frame \(frame) in the \(state) state.",
            file: file,
            line: line
        ) else { return nil }
        guard require(
            windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY)),
            "\(title)'s bottom target stayed offscreen at \(frame) in \(windowFrame).",
            file: file,
            line: line
        ) else { return nil }
        return frame
    }

    /// The container includes transparent material, while the buttons are the
    /// pixels that can intercept a semantic-center tap.
    private func tabBarObstruction(_ bar: XCUIElement) -> CGRect {
        bar.buttons.allElementsBoundByIndex.reduce(into: CGRect.null) { frame, button in
            frame = frame.union(button.frame)
        }
    }

    private func logGeometry(
        title: String,
        state: String,
        targetFrame: CGRect,
        center: CGPoint,
        obstruction: CGRect,
        buttonCount: Int,
        windowFrame: CGRect
    ) {
        print(
            "BOTTOM-CHROME \(title) state=\(state) target=\(targetFrame) "
                + "center=\(center) controls=\(obstruction) "
                + "buttons=\(buttonCount) window=\(windowFrame)"
        )
    }

    @discardableResult
    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString,
        line: UInt
    ) -> Bool {
        guard condition() else {
            XCTFail("BOTTOM-CHROME-HARNESS \(message)", file: file, line: line)
            return false
        }
        return true
    }
}
