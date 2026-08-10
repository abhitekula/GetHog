import XCTest

/// A dashboard tile opens an insight, so it has to be a button.
///
/// It used to open on `.onTapGesture`, which moves pixels and tells the
/// accessibility tree nothing. Measured on the demo dashboard in that shape: the
/// grid contained **no tile buttons at all**, and each tile left **two loose
/// `StaticText`s** behind — an 18pt title and a 13.3pt freshness stamp.
/// A control experiment on the same card wrapped in `Button { } label: { }`
/// collapsed it into **one ~402×140pt Button** carrying a combined label, which
/// is the shape every `List` row elsewhere in this app already has.
///
/// The two halves are asserted together on purpose. "A button exists" passes on a
/// card whose title is still a stop of its own beside it; "the title is not
/// loose" passes on a card that is not activatable at all. Only both at once
/// describe the fix.
final class DashboardTileAccessibilityTests: XCTestCase {

    /// Every glyph `TileStyle.symbol(for:)` can return, kept in step by hand
    /// because the UI-test target does not link the app module.
    private static let tileSymbols = [
        "chart.xyaxis.line",
        "chart.line.uptrend.xyaxis",
        "chart.bar",
        "chart.bar.doc.horizontal",
        "number",
        "line.3.horizontal.decrease",
        "arrow.triangle.2.circlepath",
        "square.grid.3x3",
        "calendar.badge.clock",
        "point.topleft.down.to.point.bottomright.curvepath",
        "questionmark.square.dashed",
    ]

    /// Regular-width dashboard detail is still a push on the Dashboards
    /// `NavigationStack`, so it must retain the system Back affordance. A
    /// bespoke button in the scroll content is not equivalent: it drops the
    /// edge-pop contract and is no longer present once the user scrolls it away.
    ///
    /// `XCUIElement.swipeRight()` begins near the centre of the window rather
    /// than at its leading edge, so XCUI cannot reliably synthesize the system
    /// interactive-pop gesture. The native control has the stable system
    /// identifier `BackButton`; requiring and tapping that control measures the
    /// same navigation contract without mistaking the in-content "All
    /// dashboards" button for Back.
    func testIPadRegularDashboardDetailUsesNativeBackAndRestoresHubPath() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The regular dashboard Back contract is measured on iPad."
        )

        let app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        try XCTSkipUnless(
            app.windows.firstMatch.frame.width > 700,
            "The app window is compact; this contract measures regular-width navigation."
        )

        let dashboardTitle = "Example App metric 33"
        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The regular dashboard landing did not expose its hub.")
        }

        let search = app.searchFields.firstMatch
        if !search.exists {
            let searchButton = app.navigationBars["Dashboards"].buttons["Search"].firstMatch
            guard DemoLaunch.wait(for: searchButton) else {
                return XCTFail("The dashboard landing did not expose dashboard search.")
            }
            searchButton.tap()
        }
        guard DemoLaunch.wait(for: search) else {
            return XCTFail("The dashboard search field never appeared.")
        }
        search.tap()
        search.typeText(dashboardTitle)

        let cards = hub.buttons.matching(
            NSPredicate(
                format: "identifier == %@",
                "gethog.dashboard-card.\(DemoLaunch.dashboardID)"
            )
        )
        let card = cards.firstMatch
        // The project signal and its pinned chart preview intentionally own the
        // first viewport. The filtered dashboard card is below that preview,
        // and `LazyVGrid` does not publish it to XCUI until the one hub scroll
        // brings the collection close enough to render.
        for _ in 0..<6 where !(card.exists && card.frame.intersects(hub.frame)) {
            hub.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        guard DemoLaunch.wait(until: { card.exists && card.frame.intersects(hub.frame) }) else {
            return XCTFail("The searched synthetic dashboard card did not become visible.")
        }
        XCTAssertEqual(cards.count, 1, "The filtered hub exposed an ambiguous dashboard card.")
        card.tap()

        let detail = app.navigationBars[dashboardTitle]
        guard DemoLaunch.wait(for: detail) else {
            return XCTFail("Selecting the regular dashboard card did not open its detail.")
        }

        let nativeBack = app.buttons["BackButton"].firstMatch
        guard DemoLaunch.wait(for: nativeBack, timeout: 5) else {
            return XCTFail(
                "The regular dashboard detail has no native Back control; "
                    + "an in-content All dashboards button is not a system navigation affordance."
            )
        }
        XCTAssertTrue(nativeBack.isHittable, "The native dashboard Back control is not tappable.")
        nativeBack.tap()

        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("Native Back did not restore the regular dashboard hub.")
        }
        XCTAssertFalse(
            detail.exists,
            "Native Back left the dashboard detail selected instead of clearing the navigation path."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: search),
            "Returning through the navigation path did not restore dashboard search."
        )
        XCTAssertEqual(
            search.value as? String,
            dashboardTitle,
            "Returning through the navigation path rebuilt the dashboard hub instead of restoring its state."
        )
    }

    func testTilesAreButtonsWithOneCombinedLabel() {
        let app = DemoLaunch.launch(openURL: "gethog://dashboard/\(DemoLaunch.dashboardID)")
        DemoLaunch.settle(app)

        let title = DemoLaunch.firstTileTitle
        // A fresh predicate per query, not one shared: `matching(_:)` takes its
        // argument as `sending`, so reusing one instance is a Swift 6 error.
        let named = { NSPredicate(format: "label == %@", title) }
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))

        XCTAssertTrue(
            DemoLaunch.wait(for: tile.firstMatch),
            "No button on the dashboard is labelled with the tile's title — the tile is not activatable."
        )
        XCTAssertEqual(tile.count, 1, "A tile must be one button, not several.")

        let button = tile.firstMatch

        // The title used to be a *sibling* of the card — a stop of its own, at
        // 18pt, that `performAccessibilityAudit` flagged as too small to interact
        // with four times over across the grid. It survives inside the button as
        // the drawn heading, and that is fine: what matters is that nothing
        // carrying this label sits outside the control that owns it.
        //
        // Deliberately not `== 0` app-wide. Measured on the fixed screen, the
        // button still contains one `StaticText` with the bare title and one with
        // the freshness stamp, because the chart in the middle publishes an
        // `AXChartDescriptor` and that keeps the whole subtree a container. An
        // assertion of zero would be failing on a shape that is already correct.
        XCTAssertEqual(
            app.descendants(matching: .any).matching(named()).count,
            button.descendants(matching: .any).matching(named()).count,
            "The tile's title appears outside the tile's button — it is still a loose element."
        )

        // `TileCard.spokenLabel` is title + chart summary + freshness. The three
        // fragments in one label are what says the card was combined rather than
        // merely wrapped in a button that names only its heading.
        XCTAssertTrue(
            button.label.hasPrefix(title),
            "Tile label '\(button.label)' does not lead with the insight's name."
        )
        XCTAssertTrue(
            button.label.contains("Data updated") || button.label.contains("Data not yet loaded"),
            "Tile label '\(button.label)' dropped the freshness stamp the card prints."
        )
        XCTAssertGreaterThan(
            button.label.count, title.count,
            "The tile's label is just its heading; the chart summary and freshness stamp were dropped."
        )

        // ~402×140pt when it was measured; 370×288.3 on an iPhone 17, because the
        // width is the column and the height is the tile's own chart. Neither
        // number is device-independent, so this pins the shape rather than the
        // pixels: a full-width card, not the 18pt line of text the loose title
        // used to be.
        let frame = button.frame
        XCTAssertGreaterThanOrEqual(frame.height, 44, "Tile is \(frame.height)pt tall.")
        XCTAssertGreaterThan(
            frame.width, 300,
            "Tile is \(frame.width)pt wide; the measured card was ~402pt, a text line ~150."
        )
    }

    /// A tile's symbol is chrome, and it was being spoken as its own name.
    ///
    /// `CardHeader` draws an SF Symbol beside the insight's title and marked it
    /// `.accessibilityHidden(true)`. Inside a tile that modifier does nothing:
    /// measured here, this grid published **two** elements whose label was the
    /// literal string `chart.xyaxis.line`, and a build with the modifier deleted
    /// published the same two. Hiding was not being lost, it was not being
    /// consulted — the tile's chart publishes an `AXChartDescriptor`, which keeps
    /// the button's label subtree a container that enumerates rendered rows
    /// rather than SwiftUI's accessibility nodes.
    ///
    /// Four shapes were measured on this screen, counting those elements:
    /// `.accessibilityHidden(true)` → 2, no modifier → 2,
    /// `.accessibilityElement(children: .ignore)` → 2,
    /// `.accessibilityElement(children: .combine)` → 2 *and* a second stop
    /// carrying the title, `.accessibilityRepresentation` → **0**. The same
    /// result, and the same reason, as the replay stage's WebKit leak next door:
    /// a subtree you do not own cannot be suppressed, only replaced.
    ///
    /// Asserting the count rather than "the header has a label" is the whole
    /// point — three of those four shapes label the header perfectly well and
    /// change nothing.
    func testTilesSpeakNoSymbolNames() {
        let app = DemoLaunch.launch(openURL: "gethog://dashboard/\(DemoLaunch.dashboardID)")
        let tile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", DemoLaunch.firstTileTitle)
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: tile.firstMatch),
            "The dashboard never drew a tile, so there was nothing to measure."
        )
        DemoLaunch.settle(app)

        // Was 2, one per line-chart tile in this fixture.
        XCTAssertEqual(
            DemoLaunch.elements(labelled: "chart.xyaxis.line", in: app).count, 0,
            "A tile is publishing its SF Symbol's name as a spoken label."
        )

        // The same fact for every glyph a tile can draw, not just the one this
        // fixture happens to lead with — the leak is `CardHeader`'s and it is
        // not specific to a symbol.
        //
        // Spelled out rather than pattern-matched. A first attempt asserted that
        // no label *looks like* a symbol name — lowercase words joined by dots,
        // no spaces — and it failed on this very screen against `www.google.com`
        // four times over, because a referrer is that shape too. A list from
        // `TileStyle.symbol(for:)` says what it means and matches no hostname.
        for symbol in Self.tileSymbols {
            XCTAssertEqual(
                DemoLaunch.elements(labelled: symbol, in: app).count, 0,
                "A tile is publishing '\(symbol)' — an SF Symbol name — as a spoken label."
            )
        }

        // The title must survive the replacement: it is the only thing in the
        // header that says what the card is.
        XCTAssertEqual(
            DemoLaunch.elements(labelled: DemoLaunch.firstTileTitle, in: app).count, 1,
            "Replacing the header's accessibility took its title with it."
        )
    }
}
