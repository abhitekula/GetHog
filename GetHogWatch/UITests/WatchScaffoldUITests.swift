import XCTest

/// Proves the shell launches and renders on this platform at all: the runner,
/// the host app, the launch, and the first of the four vertical pages.
///
/// Driven in demo mode so the assertion is about a deterministic fixture rather
/// than about whatever credential the simulator happens to hold — a launch with
/// no key renders a perfectly correct empty state, which would make this test
/// pass while proving nothing about the page it is meant to cover.
@MainActor
final class WatchScaffoldUITests: XCTestCase {
    func testDemoShellRendersTheHeadlineMetric() {
        let app = DemoLaunch.launch()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.staticTexts["Example daily engagement"], timeout: 30)
        )
    }
}
