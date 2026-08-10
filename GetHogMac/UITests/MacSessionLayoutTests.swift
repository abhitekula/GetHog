import XCTest

@MainActor
final class MacSessionLayoutTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSessionCardsHaveAtLeastFourPointsBetweenAdjacentFrames() {
        let app = DemoLaunch.launch(tab: "sessions")
        DemoLaunch.settle(app)

        let first = sessionCard(
            id: "018f1000-0000-7000-8000-000000000001",
            person: "Alex Example",
            in: app
        )
        let second = sessionCard(
            id: "018f1000-0000-7000-8000-000000000002",
            person: "Morgan Example",
            in: app
        )
        XCTAssertTrue(DemoLaunch.wait(for: first))
        XCTAssertTrue(DemoLaunch.wait(for: second))

        let orderedFrames = [first.frame, second.frame].sorted { $0.minY < $1.minY }
        let gap = orderedFrames[1].minY - orderedFrames[0].maxY
        XCTAssertGreaterThanOrEqual(
            gap,
            4,
            "Adjacent session cards had only \(gap)pt between their rendered frames."
        )
    }

    func testSessionHeaderUsesBalancedDetailColumnInsets() {
        let app = DemoLaunch.launch(tab: "sessions")
        let row = sessionCard(
            id: "018f1000-0000-7000-8000-000000000001",
            person: "Alex Example",
            in: app
        )
        XCTAssertTrue(DemoLaunch.wait(for: row))
        row.click()

        let stableHeader = app.windows.descendants(matching: .any)["gethog.session-header"]
        let header: XCUIElement
        if DemoLaunch.wait(for: stableHeader, timeout: 3) {
            header = stableHeader
        } else {
            // Before the stable anchor exists, use the header's combined
            // identity row. Its spacer claims the same inner width as the card,
            // so unequal outer-column insets remain observable in RED.
            let contentBoundary = app.windows.outlines.allElementsBoundByIndex
                .map { $0.frame.maxX }
                .max() ?? app.windows.firstMatch.frame.minX
            let candidates = app.windows.descendants(matching: .any)
                .matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Alex Example",
                    "Alex Example"
                ))
                .allElementsBoundByIndex
                .filter { $0.frame.minX >= contentBoundary && $0.frame.width > 100 }
            guard let fallback = candidates.max(by: { $0.frame.width < $1.frame.width }) else {
                return XCTFail("The session detail exposed no measurable header identity.")
            }
            header = fallback
        }

        let contentOutline = app.windows.outlines.allElementsBoundByIndex
            .filter { $0.frame.maxX < header.frame.minX }
            .max { $0.frame.maxX < $1.frame.maxX }
        let window = app.windows.firstMatch.frame
        let detailMinX = contentOutline?.frame.maxX ?? window.minX
        let leadingInset = header.frame.minX - detailMinX
        let trailingInset = window.maxX - header.frame.maxX

        XCTAssertEqual(
            leadingInset,
            trailingInset,
            accuracy: 12,
            "The session header used \(leadingInset)pt leading and \(trailingInset)pt trailing insets."
        )
    }

    /// The person-label fallback exists only to let the geometry test exercise
    /// the pre-fix tree during RED. Once production supplies the stable anchor,
    /// every GREEN run takes the identifier branch.
    private func sessionCard(id: String, person: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["gethog.session-card.\(id)"]
        if DemoLaunch.wait(for: identified, timeout: 3) {
            return identified
        }
        return app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@",
            person
        )).firstMatch
    }
}
