import XCTest

/// What the shell does at a size nobody has photographed it at.
///
/// Phase B left this owed: the sweep's alternate-size loop ran and produced no
/// images at all, because `reach` gave up on a screen whose sidebar row did not
/// exist rather than falling through to the Go menu — and at 800×600 the split
/// view collapses its sidebar, so *no* row exists. That is fixed in
/// `MacSurfaceSweepTests`; this suite is the narrow/wide evidence itself, small
/// enough to run on its own.
final class MacWindowSizeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Catches a Dashboard landing change that restores separate signal and
    /// collection scroll containers instead of one default-size dashboard hub.
    func testDashboardLandingUsesOneHub() {
        let app = DemoLaunch.launch(tab: "dashboards")

        let hubs = app.scrollViews.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-hub")
        )
        let hub = hubs.firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The default dashboard landing did not expose gethog.dashboard-hub.")
        }
        XCTAssertEqual(hubs.count, 1, "The dashboard landing must expose exactly one hub.")
        guard hubs.count == 1 else { return }

        let projectSignal = hub.staticTexts["Project signal"].firstMatch
        let projectSummary = hub.descendants(matching: .any)[
            "gethog.dashboard-project-summary"
        ].firstMatch
        let pinnedPreview = hub.descendants(matching: .any)[
            "gethog.dashboard-pinned-preview"
        ].firstMatch
        let firstCard = hub.descendants(matching: .any)[
            "gethog.dashboard-pinned-tile.77021"
        ].firstMatch
        let secondCard = hub.descendants(matching: .any)[
            "gethog.dashboard-pinned-tile.700009"
        ].firstMatch
        guard DemoLaunch.wait(for: projectSummary) else {
            return XCTFail("The dashboard hub did not expose its project-summary geometry.")
        }
        guard DemoLaunch.wait(for: pinnedPreview) else {
            return XCTFail("The dashboard hub did not expose its pinned-preview geometry.")
        }
        guard DemoLaunch.wait(for: firstCard) else {
            return XCTFail("The dashboard hub did not expose its first pinned card frame.")
        }
        guard DemoLaunch.wait(for: secondCard) else {
            return XCTFail("The dashboard hub did not expose its second pinned card frame.")
        }

        print(
            "Mac dashboard geometry: hub=\(hub.frame), summary=\(projectSummary.frame), "
                + "preview=\(pinnedPreview.frame), first=\(firstCard.frame), second=\(secondCard.frame)"
        )
        capture("Mac Dashboard \(Int(hub.frame.width))pt")

        XCTAssertGreaterThan(projectSummary.frame.width, hub.frame.width * 0.75)
        XCTAssertGreaterThanOrEqual(pinnedPreview.frame.minY, projectSummary.frame.maxY - 12)
        XCTAssertLessThanOrEqual(pinnedPreview.frame.minY, projectSummary.frame.maxY + 28)
        XCTAssertGreaterThan(pinnedPreview.frame.width, hub.frame.width * 0.75)
        XCTAssertEqual(firstCard.frame.minX, pinnedPreview.frame.minX, accuracy: 12)
        XCTAssertEqual(secondCard.frame.maxX, pinnedPreview.frame.maxX, accuracy: 12)
        XCTAssertEqual(firstCard.frame.width, secondCard.frame.width, accuracy: 12)
        XCTAssertGreaterThanOrEqual(firstCard.frame.width, 230)
        XCTAssertGreaterThanOrEqual(secondCard.frame.width, 230)
        XCTAssertGreaterThan(firstCard.frame.height, 200)
        XCTAssertGreaterThan(secondCard.frame.height, 200)
        XCTAssertEqual(firstCard.frame.minY, secondCard.frame.minY, accuracy: 12)
        XCTAssertGreaterThan(secondCard.frame.minX, firstCard.frame.maxX)
        XCTAssertEqual(
            secondCard.frame.maxX - firstCard.frame.minX,
            pinnedPreview.frame.width,
            accuracy: 12
        )
        let collections = hub.otherElements.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-collection")
        )
        let collection = collections.firstMatch
        guard DemoLaunch.wait(for: collection) else {
            return XCTFail("The dashboard hub did not contain gethog.dashboard-collection.")
        }
        XCTAssertEqual(collections.count, 1, "The dashboard hub must contain exactly one collection.")
        guard collections.count == 1 else { return }
        let collectionWidth = collection.frame.width

        let cards = hub.buttons.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-card.725101")
        )
        let card = cards.firstMatch
        // The project signal and pinned preview intentionally occupy the first
        // viewport. `LazyVGrid` creates the dashboard cards as they approach
        // it, so use a bounded scroll on the one hub surface before requiring
        // the descendant card.
        for _ in 0..<6 where !card.exists {
            hub.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        guard DemoLaunch.wait(for: card) else {
            return XCTFail("The dashboard hub did not contain gethog.dashboard-card.725101.")
        }
        XCTAssertEqual(cards.count, 1, "The dashboard hub must contain exactly one first dashboard card.")
        guard cards.count == 1 else { return }

        guard DemoLaunch.wait(for: projectSignal) else {
            return XCTFail("The dashboard hub did not contain the Project signal.")
        }
        XCTAssertGreaterThan(collectionWidth, hub.frame.width * 0.5)
        XCTAssertGreaterThanOrEqual(card.frame.width, 280)
        XCTAssertGreaterThanOrEqual(card.frame.minX, hub.frame.minX)
        XCTAssertLessThanOrEqual(card.frame.maxX, hub.frame.maxX)
    }

    /// The hub is only the loaded surface. An honest empty or failed list must
    /// replace it, rather than leaving old cards or an overlapping scroll view
    /// in the accessibility tree.
    func testDashboardLoadedEmptyAndFailureStatesAreExclusive() {
        var app = DemoLaunch.launch(tab: "dashboards")
        defer { app.terminate() }

        guard let loadedHub = assertSingleLoadedDashboardHub(in: app, named: "loaded") else { return }
        guard firstDashboardCard(in: loadedHub, at: "loaded") != nil else { return }
        app.terminate()

        app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_DEMO_EMPTY_COLLECTION": "dashboards"]
        )
        let empty = DemoLaunch.elements(labelled: "No dashboards", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: empty), "The empty dashboard list did not name its empty state.")
        XCTAssertFalse(
            app.scrollViews["gethog.dashboard-hub"].firstMatch.exists,
            "A successful empty dashboard list retained the loaded hub."
        )
        XCTAssertFalse(
            app.buttons["gethog.dashboard-card.725101"].firstMatch.exists,
            "A successful empty dashboard list retained a deterministic dashboard card."
        )
        app.terminate()

        app = DemoLaunch.launch(
            tab: "dashboards",
            environment: [
                "GETHOG_DEMO_DASHBOARD_LIST_DELAY_MS": "800",
                "GETHOG_DEMO_DASHBOARD_LIST_FAILURE": "1",
            ]
        )
        let failure = DemoLaunch.elements(labelled: "Couldn't load dashboards", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: failure), "The failed dashboard list did not explain the failure.")
        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Try again"].firstMatch),
            "The failed dashboard list did not offer retry."
        )
        XCTAssertFalse(
            app.scrollViews["gethog.dashboard-hub"].firstMatch.exists,
            "A failed dashboard list retained the loaded hub."
        )
        XCTAssertFalse(
            app.buttons["gethog.dashboard-card.725101"].firstMatch.exists,
            "A failed dashboard list retained a deterministic dashboard card."
        )
        XCTAssertFalse(
            DemoLaunch.elements(labelled: "No dashboards", in: app).firstMatch.exists,
            "A failed dashboard list was presented as a successful empty list."
        )
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Puts the window's top-left near the screen's, so a resize has room to
    /// grow into and a corner that is not sitting on the screen edge.
    ///
    /// This is half the reason the first size pass produced nothing: the shell
    /// opens flush against the right edge of a 1512pt screen, so the bottom-
    /// right corner is at x=1512 — one point past the last addressable column.
    /// The press landed on the desktop and the drag resized nothing.
    private func moveToOrigin(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.exists else { return }
        let frame = window.frame
        // The title bar, a third of the way across — clear of the traffic
        // lights on the left and of any trailing toolbar control.
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width / 3, dy: 12))
            .press(
                forDuration: 0.3,
                thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.width / 3 - frame.minX, dy: 12))
            )
        DemoLaunch.pause(1)
    }

    /// Drags the main window's bottom-right corner to a size.
    ///
    /// The grab point is inset two points from the corner: the resize region
    /// straddles the frame edge, and a press exactly on `maxX`/`maxY` is as
    /// likely to land outside the window as in it.
    private func resize(_ app: XCUIApplication, to size: CGSize) {
        moveToOrigin(app)
        let window = app.windows.firstMatch
        guard window.exists else { return }

        // Two edge drags rather than one corner drag. The corner is a few
        // points square and a press that misses it lands on the desktop, which
        // is silent — the first size pass's whole failure mode. An edge is the
        // length of the window.
        func drag(from: CGVector, to: CGVector) {
            window.coordinate(withNormalizedOffset: .zero).withOffset(from)
                .press(
                    forDuration: 0.4,
                    thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(to)
                )
            DemoLaunch.pause(1)
        }

        let start = window.frame
        drag(
            from: CGVector(dx: start.width - 3, dy: start.height / 2),
            to: CGVector(dx: size.width, dy: start.height / 2)
        )
        let mid = window.frame
        drag(
            from: CGVector(dx: mid.width / 2, dy: mid.height - 3),
            to: CGVector(dx: mid.width / 2, dy: size.height)
        )
        DemoLaunch.settle(app)
        DemoLaunch.pause(1)
    }

    /// Routes through the Go menu, which needs no sidebar — the only navigation
    /// that survives a collapsed one.
    @discardableResult
    private func go(_ title: String, in app: XCUIApplication) -> Bool {
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
        DemoLaunch.pause(0.5)
        return true
    }

    /// Whether the sidebar is on screen and reachable at this size — the fact
    /// the failed size pass needed and never recorded.
    private func sidebarState(_ app: XCUIApplication) -> String {
        let outlines = app.windows.outlines.allElementsBoundByIndex
        let row = app.windows.descendants(matching: .any)
            .matching(DemoLaunch.macTextPredicate("Dashboards")).firstMatch
        return "outlines=\(outlines.count) frames=\(outlines.map { $0.frame }) "
            + "dashboardsRow exists=\(row.exists) hittable=\(row.exists && row.isHittable)"
    }

    /// Full screen survives a relaunch, and a resize *inside* it is nonsense —
    /// measured: a narrow drag against a full-screen window produced a 3171pt
    /// frame. The tell is the window's top: outside full screen it sits below
    /// the menu bar, inside it the menu bar is hidden and the window starts at
    /// the very top of the display.
    private func leaveFullScreen(_ app: XCUIApplication) {
        guard app.windows.firstMatch.frame.minY < 50 else { return }
        app.typeKey("f", modifierFlags: [.command, .control])
        DemoLaunch.pause(5)
        print("PHASEB-SIZE left-full-screen frame=\(app.windows.firstMatch.frame)")
    }

    /// Opt-in, exactly like `MacSurfaceSweepTests`' own alternate-size pass and
    /// for a sharper version of the same reason.
    ///
    /// This test **mutates state that outlives the process**: a window frame is
    /// autosaved, full screen is restored across launches, and neither can be
    /// set back reliably from a UI test — there is no resize API, only a drag,
    /// and a drag against a full-screen window produced a 3171pt frame here.
    /// Left in the default suite it hands the next run a window wider than the
    /// display, whose trailing toolbar search field is then off screen, and
    /// two unrelated suites fail for a reason neither can see. It is evidence
    /// for a human reading images, which is what the environment gate says.
    ///
    ///     GETHOG_SWEEP_SIZES=all xcodebuild test … \
    ///       -only-testing:GetHogMacUITests/MacWindowSizeTests
    ///
    /// Seed a sane frame first, and expect to seed one after:
    ///
    ///     defaults write ~/Library/Containers/app.gethog.GetHog/Data/Library/\
    ///       Preferences/app.gethog.GetHog.plist \
    ///       "NSWindow Frame main-AppWindow-1" "0 129 1280 820 0 0 1512 949 "
    func testNarrowAndWideSweep() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["GETHOG_SWEEP_SIZES"] == "all",
            "Set GETHOG_SWEEP_SIZES=all to run the size passes; they leave a resized window."
        )
        let app = DemoLaunch.launch()
        DemoLaunch.settle(app)
        leaveFullScreen(app)
        print("PHASEB-SIZE default window=\(app.windows.firstMatch.frame) \(sidebarState(app))")
        capture("g0-default-dashboards")

        // **Wide first, narrow last, and the order is load-bearing.** A window
        // frame outlives the process, so whatever this suite ends at is what
        // the next run of every other suite starts at — and the wide pass ends
        // wider than the display, which puts the toolbar's *trailing* search
        // field off the right edge. Measured: a 1806pt window on a 1512pt
        // screen took `MacSearchSheetTests` and the replay search-field check
        // down in a later run, for a reason neither of them could see. Ending
        // narrow leaves a window that fits.
        for (label, size) in [("wide", CGSize.zero),
                              ("narrow", CGSize(width: 800, height: 600))] {
            if label == "wide" {
                // **Not a drag.** Dragging this window from ~877pt wide up to
                // 1400 crashed the app twice out of two: `EXC_BREAKPOINT` from
                // an uncaught AppKit exception thrown inside
                // `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`
                // during the live resize (crash reports
                // `GetHog-2026-08-06-024547` and `-024829`). The green button's
                // full-screen transition is AppKit resizing the same window to
                // the largest size there is, without a stream of intermediate
                // frames, and it is the wide evidence this pass can get.
                app.typeKey("f", modifierFlags: [.command, .control])
                DemoLaunch.pause(5)
            } else {
                resize(app, to: size)
            }
            let reached = app.windows.firstMatch.frame
            print("PHASEB-SIZE \(label) asked=\(size) got=\(reached) \(sidebarState(app))")

            for (title, anchor) in [("Dashboards", "Example App metric 33"),
                                    ("Events", "meteor_report_opened"),
                                    ("Sessions", "Alex Example")] {
                let routed = go(title, in: app)
                let rendered = DemoLaunch.waitForContent(containing: anchor, in: app) != nil
                print("PHASEB-SIZE \(label) \(title) routed=\(routed) rendered=\(rendered)")
                capture("g-\(label)-\(title.lowercased())")
                XCTAssertTrue(routed, "The Go menu could not reach \(title) at \(label).")
                if title == "Dashboards" {
                    assertUsableDashboardHub(in: app, at: label)
                }
            }

            // …and a replay, which is the widest thing in the app.
            if let row = DemoLaunch.waitForContent(containing: "Alex Example", in: app) {
                row.click()
                DemoLaunch.settle(app)
                DemoLaunch.pause(2.5)
                capture("g-\(label)-replay-detail")
                print("PHASEB-SIZE \(label) replay stage="
                    + "\(app.windows.buttons["Session replay"].frame)")
            }
            XCTAssertEqual(app.state, .runningForeground, "The \(label) pass took the app down.")
            if label == "wide" { leaveFullScreen(app) }
        }

        // Settings at the narrow size the loop ends on.
        let before = app.windows.count
        app.typeKey(",", modifierFlags: .command)
        _ = DemoLaunch.wait(until: { app.windows.count > before })
        DemoLaunch.settle(app)
        DemoLaunch.pause(1)
        capture("g-settings-default")
        XCTAssertGreaterThan(app.windows.count, before, "⌘, opened no Settings window.")
    }

    @discardableResult
    private func assertSingleLoadedDashboardHub(
        in app: XCUIApplication,
        named state: String
    ) -> XCUIElement? {
        let hubs = app.scrollViews.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-hub")
        )
        let hub = hubs.firstMatch
        guard DemoLaunch.wait(for: hub) else {
            XCTFail("The \(state) dashboard landing did not expose its hub.")
            return nil
        }
        guard hubs.count == 1 else {
            XCTFail("The \(state) dashboard landing exposed more than one hub.")
            return nil
        }

        let collections = hub.otherElements.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-collection")
        )
        guard DemoLaunch.wait(for: collections.firstMatch) else {
            XCTFail("The \(state) dashboard hub did not expose its collection.")
            return nil
        }
        guard collections.count == 1 else {
            XCTFail("The \(state) dashboard hub exposed more than one collection.")
            return nil
        }
        return hub
    }

    private func assertUsableDashboardHub(in app: XCUIApplication, at size: String) {
        guard let hub = assertSingleLoadedDashboardHub(in: app, named: size) else { return }
        let collection = hub.otherElements.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-collection")
        ).firstMatch
        guard let card = firstDashboardCard(in: hub, at: size) else { return }

        XCTAssertGreaterThan(collection.frame.width, hub.frame.width * 0.5)
        XCTAssertGreaterThanOrEqual(card.frame.width, 280)
        XCTAssertGreaterThanOrEqual(card.frame.minX, hub.frame.minX)
        XCTAssertLessThanOrEqual(card.frame.maxX, hub.frame.maxX)
    }

    @discardableResult
    private func firstDashboardCard(in hub: XCUIElement, at size: String) -> XCUIElement? {
        let card = hub.buttons["gethog.dashboard-card.725101"].firstMatch
        for _ in 0..<6 where !card.exists {
            hub.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        guard DemoLaunch.wait(for: card) else {
            XCTFail("The \(size) dashboard hub did not render its first card.")
            return nil
        }
        return card
    }

}
