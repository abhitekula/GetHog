import XCTest

/// The Mac shell in demo mode, driven the way the iOS audit targets drive the
/// phone: deterministic fixtures, polled waits, one runner per machine.
///
/// What is measured is the shell itself — the sidebar reaching each primary
/// screen, a dashboard tearing off into its own window, Settings answering ⌘,
/// — because those are the behaviors `GetHogMac` adds around screens the iOS
/// targets already exercise. Every content assertion is pinned to an element
/// only its demo fixture can produce, so passing means the screen rendered,
/// not a placeholder that happened to share a word with it.
final class MacNavigationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The pinned first row of `dashboards_list.json`, which leads the list.
    private let firstDashboardTitle = "Example App metric 33"

    // MARK: - Queries

    /// Every element whose label contains the text, of any type.
    ///
    /// List rows fold their fields into one accessibility label, so an
    /// exact-label query cannot find "the row for this dashboard" — and the
    /// element type a SwiftUI row lands on is an implementation detail that
    /// pinning would make this suite fail on.
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// The sidebar destination carrying an exact title.
    ///
    /// Scoped to the sidebar's outline when one exists, because the content
    /// area can legitimately carry the same word — a window titled "Events"
    /// above an Events feed — and the test must click the navigation, not the
    /// content. The app-wide fallback keeps the query honest if the sidebar
    /// stops being an outline: an element that is not there fails the wait
    /// rather than silently matching something else.
    private func sidebarItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let sidebar = app.outlines.firstMatch
        if sidebar.exists {
            let scoped = sidebar.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", title))
                .firstMatch
            if scoped.exists { return scoped }
        }
        return DemoLaunch.elements(labelled: title, in: app).firstMatch
    }

    private func openSidebarItem(_ title: String, in app: XCUIApplication) {
        let item = sidebarItem(title, in: app)
        XCTAssertTrue(DemoLaunch.wait(for: item), "No sidebar destination labelled \(title).")
        item.click()
        DemoLaunch.settle(app)
    }

    // MARK: - Tests

    func testLaunchesToSidebar() {
        let app = DemoLaunch.launch()

        for title in ["Dashboards", "Events", "Sessions", "Flags"] {
            XCTAssertTrue(
                DemoLaunch.wait(for: sidebarItem(title, in: app)),
                "The sidebar never offered \(title)."
            )
        }
    }

    func testSidebarReachesEachPrimaryScreen() {
        let app = DemoLaunch.launch()

        let screens: [(tab: String, fixtureText: String)] = [
            ("Events", "meteor_report_opened"),
            ("Sessions", "Alex Example"),
            ("Flags", "example-navigation"),
            ("Dashboards", firstDashboardTitle),
        ]
        for screen in screens {
            openSidebarItem(screen.tab, in: app)
            XCTAssertTrue(
                DemoLaunch.wait(for: element(containing: screen.fixtureText, in: app)),
                "\(screen.tab) never showed “\(screen.fixtureText)” from its fixture."
            )
        }
    }

    func testDashboardTearsOffIntoItsOwnWindow() {
        let app = DemoLaunch.launch()

        openSidebarItem("Dashboards", in: app)
        let row = element(containing: firstDashboardTitle, in: app)
        XCTAssertTrue(DemoLaunch.wait(for: row), "The list never offered \(firstDashboardTitle).")
        row.click()

        // The detail fetches on open; its first tile is the proof it loaded.
        XCTAssertTrue(
            DemoLaunch.wait(for: element(containing: DemoLaunch.firstTileTitle, in: app)),
            "The dashboard detail never rendered its first tile."
        )

        let windowsBefore = app.windows.count
        let actions = DemoLaunch.elements(labelled: "Dashboard actions", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: actions), "The dashboard toolbar menu never appeared.")
        actions.click()

        let tearOff = app.menuItems["Open in new window"]
        XCTAssertTrue(DemoLaunch.wait(for: tearOff, timeout: 5), "The actions menu offered no tear-off.")
        tearOff.click()

        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count > windowsBefore }),
            "Open in new window produced no second window."
        )

        // The tear-off resolves the dashboard again from its id alone —
        // `WindowTarget` carries identifiers, never decoded models — so the
        // same tile renders once per window.
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", DemoLaunch.firstTileTitle))
                    .count >= 2
            }),
            "The second window never rendered the dashboard it was opened for."
        )
    }

    func testSettingsOpensWithCommandComma() {
        let app = DemoLaunch.launch()

        let windowsBefore = app.windows.count
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count > windowsBefore }),
            "⌘, never opened the Settings scene."
        )
    }
}
