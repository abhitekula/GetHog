import AppKit
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

    /// The sidebar destination carrying an exact title.
    ///
    /// Scoped to the sidebar's outline when one exists, because the content
    /// area can legitimately carry the same word — a window titled "Events"
    /// above an Events feed — and the test must click the navigation, not the
    /// content. The app-wide fallback keeps the query honest if the sidebar
    /// stops being an outline: an element that is not there fails the wait
    /// rather than silently matching something else.
    private func sidebarItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // Every outline, not just the first. On a split-view screen the
        // content list is *also* an outline — measured: the Sessions list
        // reports `Outline, label: 'Sidebar'` at x=271 — so `firstMatch` can
        // resolve to the content column, miss the destination, and fall through
        // to an app-wide query that returns a zero-size off-screen duplicate.
        // Asking every outline for a hittable match removes the ambiguity.
        var offscreen: XCUIElement?
        for sidebar in app.outlines.allElementsBoundByIndex {
            let scoped = sidebar.descendants(matching: .any)
                .matching(DemoLaunch.macTextPredicate(title))
            if let hittable = scoped.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                return hittable
            }
            if offscreen == nil, scoped.firstMatch.exists { offscreen = scoped.firstMatch }
        }
        // A destination scrolled out of view is still the right element — the
        // caller scrolls to it. Returning it beats the app-wide fallback, which
        // matches the Go menu's item of the same name: a zero-size element at
        // y=982, outside the window, that `click()` rejects as not hittable.
        return offscreen ?? DemoLaunch.elements(labelled: title, in: app).firstMatch
    }

    private func openSidebarItem(_ title: String, in app: XCUIApplication) {
        var item = sidebarItem(title, in: app)
        XCTAssertTrue(DemoLaunch.wait(for: item), "No sidebar destination labelled \(title).")

        // Thirty-four destinations do not fit 820pt, and reaching one low in
        // the list scrolls the ones above it away — so a later step asking for
        // Dashboards finds it present and unreachable.
        var scrolls = 0
        while !item.isHittable && scrolls < 12 {
            app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: 120)
            item = sidebarItem(title, in: app)
            scrolls += 1
        }

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
            XCTAssertNotNil(
                DemoLaunch.waitForContent(containing: screen.fixtureText, in: app),
                "\(screen.tab) never showed “\(screen.fixtureText)” from its fixture."
            )
        }
    }

    func testDashboardTearsOffIntoItsOwnWindow() {
        let app = DemoLaunch.launch()

        openSidebarItem("Dashboards", in: app)
        guard let row = DemoLaunch.waitForContent(containing: firstDashboardTitle, in: app) else {
            return XCTFail("The list never offered \(firstDashboardTitle).")
        }
        row.click()

        // The detail fetches on open; its first tile is the proof it loaded.
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: DemoLaunch.firstTileTitle, in: app),
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
                DemoLaunch.macContentTypes.contains { type in
                    app.windows.descendants(matching: type)
                        .matching(NSPredicate(
                            format: "label CONTAINS %@ OR value CONTAINS %@",
                            DemoLaunch.firstTileTitle, DemoLaunch.firstTileTitle
                        ))
                        .count >= 2
                }
            }),
            "The second window never rendered the dashboard it was opened for."
        )
    }

    /// The tear-off from the row, not from the detail's toolbar.
    ///
    /// `testDashboardTearsOffIntoItsOwnWindow` proves the window opens; this
    /// proves it can be opened without first navigating into the dashboard,
    /// which is the route a Mac user reaches for and the one the row did not
    /// offer until now.
    func testDashboardRowTearsOffFromItsContextMenu() {
        let app = DemoLaunch.launch()

        openSidebarItem("Dashboards", in: app)
        guard let row = DemoLaunch.waitForContent(containing: firstDashboardTitle, in: app) else {
            return XCTFail("The list never offered \(firstDashboardTitle).")
        }

        let windowsBefore = app.windows.count
        row.rightClick()

        let tearOff = app.menuItems["Open in new window"]
        XCTAssertTrue(
            DemoLaunch.wait(for: tearOff, timeout: 5),
            "The dashboard row's context menu offered no tear-off."
        )
        tearOff.click()

        XCTAssertTrue(
            DemoLaunch.wait(until: { app.windows.count > windowsBefore }),
            "Open in new window from the row produced no second window."
        )
    }

    /// Copy link on a recording row, read back off the real pasteboard.
    ///
    /// The runner shares the login session's pasteboard, so what the menu item
    /// wrote is readable here — which makes this an assertion about the link
    /// the user gets, not about a menu item existing. Recording rows carried no
    /// context menu at all before this.
    func testRecordingRowCopiesItsReplayLink() {
        let app = DemoLaunch.launch()

        NSPasteboard.general.clearContents()

        openSidebarItem("Sessions", in: app)
        guard let row = DemoLaunch.waitForContent(containing: Self.firstRecordingPerson, in: app) else {
            return XCTFail("The list never offered a recording for \(Self.firstRecordingPerson).")
        }
        row.rightClick()

        let copyLink = app.menuItems["Copy link"]
        XCTAssertTrue(
            DemoLaunch.wait(for: copyLink, timeout: 5),
            "The recording row's context menu offered no Copy link."
        )
        copyLink.click()

        XCTAssertTrue(
            DemoLaunch.wait(until: {
                NSPasteboard.general.string(forType: .string)?
                    .contains("replay/\(Self.firstRecordingID)") == true
            }),
            """
            Copy link never put the replay URL on the pasteboard \
            (saw: \(NSPasteboard.general.string(forType: .string) ?? "nothing")).
            """
        )
    }

    /// The pinned first row of `session_recordings.json`, and the id its replay
    /// link has to carry.
    private static let firstRecordingPerson = "Alex Example"
    private static let firstRecordingID = "018f1000-0000-7000-8000-000000000001"

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
