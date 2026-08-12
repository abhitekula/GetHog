import XCTest

/// Rendered proof that Mac list cards keep visible page ground between rows.
///
/// `listRowSpacing` is unavailable on macOS, so the accessible row frames are
/// the regression boundary: removing the background inset makes adjacent rows
/// meet. The same deterministic rows are checked at the compact-shell boundary
/// and at the app's default wide size.
@MainActor
final class MacListRhythmTests: XCTestCase {

    private struct ListCase {
        let title: String
        let firstRow: String
        let secondRow: String
    }

    private static let populatedCases = [
        ListCase(title: "Events", firstRow: "meteor_report_opened", secondRow: "meteor_filter_applied"),
        ListCase(title: "People", firstRow: "Sable Okafor", secondRow: "visitor:amber-comet-73"),
        ListCase(title: "Sessions", firstRow: "Alex Example", secondRow: "Casey Example"),
        ListCase(title: "Notebooks", firstRow: "Orbit field log", secondRow: "Telescope calibration notes"),
        ListCase(title: "Renders", firstRow: "Example filename 0312", secondRow: "Example filename 0314"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testRepresentativeListCardsKeepFourPointsOfVisibleSeparation() {
        let app = DemoLaunch.launch(tab: "events")

        for size in [
            CGSize(width: 1_280, height: 820),
            CGSize(width: 800, height: 600),
        ] {
            resize(app, to: size)
            for listCase in Self.populatedCases {
                XCTAssertTrue(
                    open(listCase.title, in: app),
                    "The Go menu could not reach \(listCase.title) at \(Int(size.width))pt."
                )
                assertCardSeparation(for: listCase, at: size, in: app)
            }
        }
    }

    /// DemoTransport intentionally declares `/conversations/` as an authored
    /// empty collection, so no deterministic Max rows exist to measure. Keep
    /// the representative case explicit rather than silently claiming coverage
    /// from the Max empty state.
    func testMaxListCardRhythmNeedsPopulatedDemoRows() throws {
        let app = DemoLaunch.launch(tab: "max")
        if DemoLaunch.waitForContent(
            containing: "No Max conversations",
            in: app,
            timeout: 5
        ) != nil {
            throw XCTSkip("DemoTransport has no populated deterministic Max conversation fixture.")
        }

        for size in [
            CGSize(width: 1_280, height: 820),
            CGSize(width: 800, height: 600),
        ] {
            resize(app, to: size)
            XCTAssertTrue(open("Max", in: app))
            assertFirstTwoCardSeparation(title: "Max", at: size, in: app)
        }
    }

    private func assertFirstTwoCardSeparation(
        title: String,
        at size: CGSize,
        in app: XCUIApplication
    ) {
        var frames: [CGRect] = []
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 15) {
                let outlines = app.windows.outlines.allElementsBoundByIndex
                    .sorted { $0.frame.minX < $1.frame.minX }
                guard let contentList = outlines.last else { return false }
                frames = contentList.buttons.allElementsBoundByIndex
                    .filter(\.isHittable)
                    .map(\.frame)
                    .sorted { $0.minY < $1.minY }
                return frames.count >= 2
            },
            "\(title) did not render two actionable rows."
        )
        guard frames.count >= 2 else { return }

        let separation = frames[1].minY - frames[0].maxY
        XCTAssertGreaterThanOrEqual(
            separation,
            4,
            "\(title) card backgrounds touch at \(Int(size.width))×\(Int(size.height))."
        )
    }

    private func assertCardSeparation(
        for listCase: ListCase,
        at size: CGSize,
        in app: XCUIApplication
    ) {
        guard let first = waitForRow(containing: listCase.firstRow, in: app) else {
            return XCTFail("\(listCase.title) did not render its first representative row.")
        }
        guard let second = waitForRow(containing: listCase.secondRow, in: app) else {
            return XCTFail("\(listCase.title) did not render its second representative row.")
        }

        let frames = [first.frame, second.frame].sorted { $0.minY < $1.minY }
        let separation = frames[1].minY - frames[0].maxY
        print(
            "MAC-LIST-RHYTHM \(listCase.title) size=\(Int(size.width))x\(Int(size.height)) "
                + "first=\(frames[0]) second=\(frames[1]) separation=\(separation)"
        )
        XCTAssertGreaterThanOrEqual(
            separation,
            4,
            "\(listCase.title) card backgrounds touch at \(Int(size.width))×\(Int(size.height))."
        )
    }

    /// Rows are actionable containers, never their title leaf. A title's text
    /// frame can sit many points from the next title even when the card
    /// backgrounds themselves touch, which would make the assertion vacuous.
    private func waitForRow(
        containing text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for type in [XCUIElement.ElementType.button, .cell] {
                let row = app.windows.descendants(matching: type)
                    .matching(NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@", text, text
                    ))
                    .firstMatch
                if row.exists { return row }
            }
            DemoLaunch.pause(0.25)
        }
        return nil
    }

    @discardableResult
    private func open(_ title: String, in app: XCUIApplication) -> Bool {
        let go = app.menuBars.menuBarItems["Go"]
        guard go.exists else { return false }
        go.click()
        let entry = app.menuItems[title]
        guard DemoLaunch.wait(for: entry, timeout: 5), entry.isEnabled else {
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        entry.click()
        DemoLaunch.settle(app)
        return true
    }

    private func resize(_ app: XCUIApplication, to size: CGSize) {
        let window = app.windows.firstMatch
        guard window.exists else { return }

        let frame = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width / 3, dy: 12))
            .press(
                forDuration: 0.3,
                thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.width / 3 - frame.minX, dy: 12))
            )

        func drag(from: CGVector, to: CGVector) {
            window.coordinate(withNormalizedOffset: .zero).withOffset(from)
                .press(
                    forDuration: 0.4,
                    thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(to)
                )
        }

        let start = window.frame
        drag(
            from: CGVector(dx: start.width - 3, dy: start.height / 2),
            to: CGVector(dx: size.width, dy: start.height / 2)
        )
        let intermediate = window.frame
        drag(
            from: CGVector(dx: intermediate.width / 2, dy: intermediate.height - 3),
            to: CGVector(dx: intermediate.width / 2, dy: size.height)
        )
        DemoLaunch.settle(app)

        XCTAssertEqual(window.frame.width, size.width, accuracy: 2)
        XCTAssertEqual(window.frame.height, size.height, accuracy: 2)
    }
}
