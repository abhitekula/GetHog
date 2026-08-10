import AppKit
import XCTest

/// The status item, in a real menu bar.
///
/// `MacMenuBarTests` pins the election, the spelling and the toggler's state
/// machine as pure values. What only a running app can answer is whether the
/// extra is *inserted* and whether its label is the headline metric rather than
/// the placeholder glyph — which is what this asserts, off the item's own
/// accessibility title.
///
/// **The popover is deliberately not driven here.** Its rows, the overflow menu
/// and the quick-toggle round trip all need the status item to be clickable,
/// and whether it is depends on the machine rather than on the app: a menu bar
/// with no room, or a third-party menu-bar manager, parks the item outside the
/// visible bar. Measured on the machine this was written on — a `Hidden Bar`
/// install — the item reports its frame at x = -4276 and XCUITest refuses to
/// click it, while its title reads perfectly. A test that asserted the popover
/// would fail for a reason that has nothing to do with GetHog.
final class MacMenuBarExtraTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testStatusItemCarriesTheHeadlineMetric() {
        let app = DemoLaunch.launch()
        DemoLaunch.settle(app)

        let item = app.statusItems.firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: item, timeout: 15),
            "No GetHog status item in the menu bar."
        )
        // `MenuBarHeadline.accessibilityLabel` — "GetHog: <title>, <value>" once
        // a snapshot exists, and the bare app name before the first sync. Read
        // off `title` rather than `label`: the item carries it there, the same
        // Mac value-versus-label split `DemoLaunch.macTextPredicate` exists for.
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 15) {
                item.title.hasPrefix("GetHog") && item.title.contains(",")
            },
            "The status item never adopted the freshly published headline snapshot."
        )
        let title = item.title
        print("PHASEB-STATUSITEM frame=\(item.frame) title=\(title)")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "d1-status-item"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(
            title.hasPrefix("GetHog"),
            "The status item's spoken label is not the one MenuBarHeadline writes: \(title)."
        )
        XCTAssertTrue(
            title.contains(","),
            "The status item shows the placeholder rather than a metric: \(title)."
        )
    }
}
