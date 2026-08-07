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
        // The native List exposes an unlabeled Cell whose full-width
        // StaticText is the selectable element. Scope to the left-most
        // collection: split-view screens legitimately carry their own lists
        // and may repeat a destination title in content.
        if let sectionList = app.collectionViews.allElementsBoundByIndex.min(by: {
            $0.frame.minX < $1.frame.minX
        }) {
            return sectionList.staticTexts.matching(
                NSPredicate(format: "label == %@", title)
            ).firstMatch
        }
        return app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
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
        guard let sidebarItem = reveal(title, in: app, file: file, line: line) else {
            return false
        }
        sidebarItem.tap()
        return true
    }
}
