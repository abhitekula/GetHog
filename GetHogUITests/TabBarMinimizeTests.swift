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
/// five 54pt buttons; minimised it holds one, a 48 × 48 pill at `{28, 798}`. The
/// container therefore includes seven transparent points above the control. It
/// is the button frame, not that transparent container, that can cover content.
///
/// Measured again on iOS 26.5, the first merely hittable Errors footer could end
/// at `810`, but one more bounded swipe put it at `776.33` against the pill's
/// `minY = 798`: 21.67pt of real clearance. Re-read on iPhone 17 Pro Max
/// (440 × 956pt), People — whose page has less trailing padding — was flush to
/// its rendered controls and still hittable. Nothing on either screen is covered.
///
/// **So there is nothing to fix, and that is the point of these assertions.** The
/// tempting repair — a `safeAreaInset` on the screens that were filed — would
/// double-inset every one of them whenever the bar is expanded, which is most of
/// the time. What the assertions pin is that the content can be scrolled clear
/// of the controls the bar actually draws. If a future iOS makes that impossible,
/// the fix belongs on the `TabView`, once, not on each screen.
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
        // element that is definitionally the bottom of the content. Hittability
        // alone is not the boundary: XCTest can hit a partially covered row.
        let freshness = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Data updated"))
            .firstMatch
        for _ in 0..<16 {
            let obstruction = tabBarObstruction(bar)
            if freshness.exists,
               freshness.isHittable,
               !freshness.frame.intersects(obstruction) {
                break
            }
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

        let obstruction = tabBarObstruction(bar)
        XCTAssertFalse(
            obstruction.isNull,
            "The tab bar has no rendered controls to measure on \(title).",
            file: file,
            line: line
        )

        print(
            "TAB-BAR-CLEARANCE \(title) bar=\(bar.frame) "
                + "obstruction=\(obstruction) "
                + "lastContent=\(freshness.frame) hittable=\(freshness.isHittable) "
                + "buttons=\(bar.buttons.count)"
        )

        XCTAssertFalse(
            freshness.frame.intersects(obstruction),
            """
            The last element of \(title) is at \(freshness.frame) and the tab \
            bar's rendered controls occupy \(obstruction), so a control is over \
            the end of the content after bounded scrolling.
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

    /// The tab bar's accessibility container includes transparent material
    /// above and around its controls. Unioning the buttons measures the pixels
    /// that can actually obstruct content in both expanded and collapsed states.
    private func tabBarObstruction(_ bar: XCUIElement) -> CGRect {
        bar.buttons.allElementsBoundByIndex.reduce(into: CGRect.null) { frame, button in
            frame = frame.union(button.frame)
        }
    }
}
