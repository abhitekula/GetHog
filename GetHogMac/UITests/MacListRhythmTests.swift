import XCTest

/// Rendered proof that Mac list cards keep visible page ground between rows.
///
/// `listRowSpacing` is unavailable on macOS, so the clipped background frames
/// are the regression boundary. The DEBUG Mac marker is attached to the colored
/// shape *inside* its vertical padding: a 3pt inset produces 6pt between
/// adjacent marker frames, while reverting it to 1pt produces 2pt and fails the
/// 4pt threshold below. The same deterministic rows are checked at the
/// compact-shell boundary and at the app's default wide size.
@MainActor
final class MacListRhythmTests: XCTestCase {

    private struct ListCase {
        let title: String
        let route: String
    }

    private static let populatedCases = [
        ListCase(title: "Events", route: "events"),
        ListCase(title: "People", route: "people"),
        ListCase(title: "Sessions", route: "sessions"),
        ListCase(title: "Notebooks", route: "notebooks"),
        ListCase(title: "Max", route: "max"),
        ListCase(title: "Renders", route: "renders"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testRepresentativeListCardsKeepFourPointsOfVisibleSeparation() {
        let app = DemoLaunch.launch(
            tab: "events",
            environment: ["GETHOG_DEMO_MAX_CONVERSATIONS": "1"]
        )

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

    private func assertCardSeparation(
        for listCase: ListCase,
        at size: CGSize,
        in app: XCUIApplication
    ) {
        let prefix = "gethog.list-card-background.\(listCase.route)."
        var frames: [CGRect] = []
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 15) {
                frames = app.windows.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
                    .allElementsBoundByIndex
                    .map(\.frame)
                    .filter { !$0.isEmpty && !$0.isNull }
                    .sorted { $0.minY < $1.minY }
                return frames.count >= 2
            },
            "\(listCase.title) did not expose two clipped card-background frames."
        )
        guard frames.count >= 2 else { return }

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
