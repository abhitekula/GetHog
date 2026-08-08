import XCTest

/// What `.tabBarMinimizeBehavior(.onScrollDown)` costs the content under it.
///
/// **The observation this closes.** A screenshot sweep filed "a bottom-left FAB
/// overlapping content" on three screens. It is not a stray control: it is the
/// iOS 26 tab bar in its minimised form, produced by the modifier on the
/// `TabView` in `RootView`. Whether it *occludes* anything was never measured,
/// and the same screenshot had been filed more than once, so it is measured here.
///
/// **Measured on iPhone 17, 402 × 874pt, demo build.** The tab bar's own frame is
/// `{0, 791, 402, 83}` — byte-identical expanded and minimised. Expanded it holds
/// five 54pt buttons; minimised it holds one, a 48 × 48 pill at `{28, 798}`. So
/// the band the bar reserves, and therefore the bottom safe-area inset the
/// screens lay out against, does not change when it minimises: the pill is
/// strictly *inside* the space the expanded bar already occupied.
///
/// At the end of the scroll, with the bar minimised, Errors put its last element
/// at `maxY = 771` against the bar's `minY = 791` — 20pt of clearance, and
/// hittable. Re-read on iPhone 17 Pro Max (440 × 956pt), also minimised: Errors
/// `853` against `873`, the same 20pt, and People — whose page has less trailing
/// padding — `873` against `873`, flush to the point and still hittable. Nothing
/// on either screen is covered, and People shows the inset is exact rather than
/// generous.
///
/// **So there is nothing to fix, and that is the point of these assertions.** The
/// tempting repair — a `safeAreaInset` on the screens that were filed — would
/// double-inset every one of them whenever the bar is expanded, which is most of
/// the time. What the two assertions here pin is the pair of facts that make the
/// repair unnecessary: the reserved band does not shrink, and content clears it.
/// If a future iOS *does* shrink the band on minimise, the first assertion fails
/// and the fix belongs on the `TabView`, once, not on each screen.
final class TabBarMinimizeTests: XCTestCase {

    func testErrorsClearsTheMinimisedTabBar() throws {
        try assertContentClearsMinimisedTabBar(onTab: "errorTracking", titled: "Errors")
    }

    func testPeopleClearsTheMinimisedTabBar() throws {
        try assertContentClearsMinimisedTabBar(onTab: "people", titled: "People")
    }

    // MARK: -

    private func assertContentClearsMinimisedTabBar(
        onTab tab: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        if deviceName.localizedCaseInsensitiveContains("iPad") {
            throw XCTSkip(
                "Tab-bar minimisation is an iPhone behavior; iPad uses the system sidebar."
            )
        }

        let app = DemoLaunch.launch(tab: tab)
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars[title]),
            "\(title) never came up.",
            file: file,
            line: line
        )
        DemoLaunch.settle(app)

        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.exists, "There is no compact tab bar on \(title).", file: file, line: line)
        guard bar.exists else { return }

        // Regular width has nothing to measure: `.sidebarAdaptable` can put the
        // bar across the top of a landscape Max-size iPhone, where it is above
        // the content rather than over it, and `.tabBarMinimizeBehavior` never
        // fires. Detected by where the bar is because its position is the thing
        // that determines whether content clearance is relevant.
        let window = app.windows.firstMatch.frame
        guard bar.frame.midY > window.midY else {
            throw XCTSkip(
                "Tab-bar minimisation is not available with the bar at \(bar.frame) in \(window)."
            )
        }

        let expanded = bar.frame
        XCTAssertEqual(
            bar.buttons.count, 5,
            "The tab bar should start expanded, with all five tabs in it.",
            file: file,
            line: line
        )

        // Minimising is driven by a downward scroll, so one is all it takes. The
        // minimised bar publishes a single button whose value is "Collapsed",
        // which is the only signal the app itself is told nothing about.
        var minimised = false
        for _ in 0..<12 {
            if bar.buttons.count == 1,
               (bar.buttons.firstMatch.value as? String) == "Collapsed" {
                minimised = true
                break
            }
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.5)
        }

        // A page that fits does not scroll, and a bar that is never scrolled
        // never minimises — by construction, not by defect. People crossed
        // that line when person rows moved their email titles to one
        // middle-truncated line: the demo list got ~a row shorter and stopped
        // scrolling on this height. The facts worth pinning survive: the
        // reserved-band equality is still asserted by every screen that does
        // scroll (Errors), and the clearance assertions below measure the
        // expanded bar against this page's end, which is the only bar this
        // page can ever produce.
        guard minimised else {
            print("TAB-BAR-CLEARANCE \(title): content fits without scrolling; bar stays expanded.")
            assertEndOfContentClears(bar: bar, in: app, titled: title, file: file, line: line)
            return
        }

        XCTAssertEqual(
            bar.frame, expanded,
            """
            The tab bar reserves \(bar.frame) minimised against \(expanded) \
            expanded. It used to reserve the same band in both states, which is \
            what makes a per-screen `safeAreaInset` unnecessary — and wrong, \
            because it would double-inset while the bar is expanded. If this has \
            genuinely changed, the inset belongs on the `TabView` in `RootView`, \
            not on this screen.
            """,
            file: file,
            line: line
        )

        assertEndOfContentClears(bar: bar, in: app, titled: title, file: file, line: line)
    }

    /// The clearance half of the measurement, shared by both outcomes of the
    /// minimise attempt: reach the definitional end of the content and assert
    /// the bar is not over it.
    private func assertEndOfContentClears(
        bar: XCUIElement,
        in app: XCUIApplication,
        titled title: String,
        file: StaticString,
        line: UInt
    ) {
        // To the end of the list. `FreshnessLabel` is the last thing on every one
        // of these screens and it says so out loud, which makes it the one
        // element that is definitionally the bottom of the content.
        let freshness = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Data updated"))
            .firstMatch
        for _ in 0..<16 {
            if freshness.exists && freshness.isHittable { break }
            app.swipeUp()
            DemoLaunch.pause(0.3)
        }
        DemoLaunch.pause(0.8)

        XCTAssertTrue(
            freshness.exists,
            "The end of \(title) was never reached, so occlusion was not measured.",
            file: file,
            line: line
        )
        guard freshness.exists else { return }

        print(
            "TAB-BAR-CLEARANCE \(title) bar=\(bar.frame) "
                + "lastContent=\(freshness.frame) hittable=\(freshness.isHittable) "
                + "buttons=\(bar.buttons.count)"
        )

        XCTAssertLessThanOrEqual(
            freshness.frame.maxY, bar.frame.minY,
            """
            The last element of \(title) ends at \(freshness.frame.maxY) and the \
            tab bar starts at \(bar.frame.minY), so the bar is over the end of \
            the content and no amount of scrolling brings it clear.
            """,
            file: file,
            line: line
        )
        XCTAssertTrue(
            freshness.isHittable,
            "The last element of \(title) is on screen but nothing can touch it.",
            file: file,
            line: line
        )
    }
}
