import XCTest

@MainActor
enum TVRemote {
    static func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            XCUIRemote.shared.press(button)
        }
    }

    /// Moves focus a bounded number of times. A focus engine that refuses to
    /// move must fail the test rather than leaving a remote loop running.
    static func focus(
        on element: XCUIElement,
        by direction: XCUIRemote.Button,
        limit: Int = 8
    ) -> Bool {
        var remaining = limit
        return DemoLaunch.wait(timeout: Double(limit) + 1) {
            if element.hasFocus { return true }
            guard remaining > 0 else { return false }
            XCUIRemote.shared.press(direction)
            remaining -= 1
            return element.hasFocus
        }
    }

    /// Moves focus to any currently mounted element in a query. Re-resolving
    /// the focused match after every press keeps lazy containers free to
    /// recycle rows without leaving the test pinned to a stale element.
    static func focusAny(
        in query: XCUIElementQuery,
        by direction: XCUIRemote.Button,
        limit: Int = 8
    ) -> Bool {
        var remaining = limit
        return DemoLaunch.wait(timeout: Double(limit) + 1) {
            if focusedElement(in: query).exists { return true }
            guard remaining > 0 else { return false }
            XCUIRemote.shared.press(direction)
            remaining -= 1
            return focusedElement(in: query).exists
        }
    }

    static func focusedElement(in query: XCUIElementQuery) -> XCUIElement {
        query.matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }
}

@MainActor
enum TVSidebar {
    static func item(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
    }

    static func select(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let item = item(title, in: app)
        XCTAssertTrue(
            TVRemote.focus(on: item, by: .down),
            "The \(title) sidebar row never took focus.",
            file: file,
            line: line
        )
        TVRemote.press(.select)
    }
}
