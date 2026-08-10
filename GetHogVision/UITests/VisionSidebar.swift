import XCTest

/// Drives the controls Vision's sidebar actually exposes to automation.
///
/// The value-bearing section tabs live in Vision's ornament window. Selecting
/// one mounts that section's persistent `List` in the main window, where each
/// product destination is a cell. Keep the queries separated by role so screen
/// content carrying the same title cannot impersonate either control.
@MainActor
enum VisionSidebar {
    static func item(_ title: String, in app: XCUIApplication) -> XCUIElement {
        if title == "Settings" {
            // Measured hierarchy: the parent control is label Settings with the
            // stable system-image identifier gearshape. Its two descendants are
            // also buttons, so matching label alone is ambiguous.
            return app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", "gearshape", "Settings"
            )).firstMatch
        }
        // Split-view product screens legitimately carry their own collections
        // and may repeat a destination title. The section list has a stable
        // identifier; a left-most-collection heuristic can otherwise return a
        // logically mounted but collapsed list and synthesize a tap behind the
        // foreground screen.
        let sectionList = app.collectionViews["gethog.vision.section-sidebar"].firstMatch
        return sectionList.buttons.matching(
            NSPredicate(format: "label == %@", title)
        ).firstMatch
    }

    static func destinationControl(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["gethog.vision.section-destination.\(title)"].firstMatch
    }

    static func section(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "section.\(title)", title
        )).firstMatch
    }

    static func reveal(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let sidebarItem = item(title, in: app)
        guard DemoLaunch.wait(until: { sidebarItem.exists && sidebarItem.isHittable }) else {
            XCTFail("The Vision sidebar never offered a hittable \(title) row.", file: file, line: line)
            return nil
        }
        return sidebarItem
    }

    @discardableResult
    static func tap(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        if title == "Settings" {
            guard let sidebarItem = reveal(title, in: app, file: file, line: line) else {
                return false
            }
            sidebarItem.tap()
            return true
        }

        // When the native roster collapses, visionOS can retain its children
        // in the accessibility hierarchy and even report them hittable behind
        // the foreground screen. Prefer the compact route control whenever it
        // is actually rendered. At wide widths that strip is intentionally
        // absent, so the visible roster becomes the single authority.
        let destinationControl = destinationControl(title, in: app)
        if DemoLaunch.wait(timeout: 2, until: {
            destinationControl.exists && destinationControl.isHittable
        }) {
            destinationControl.tap()
            return true
        }

        guard let sidebarItem = reveal(title, in: app, file: file, line: line) else {
            return false
        }
        sidebarItem.tap()
        return true
    }
}
