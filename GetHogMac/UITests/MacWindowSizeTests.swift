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

    /// The selected lens is the reason someone opens Clickmap, but it must not
    /// become an unbounded wall in front of saved-render navigation. The
    /// populated Elements fixture is deliberately longer than three compact
    /// viewports: an uninterrupted list cannot satisfy the bounded open below.
    func testCompactClickmapPrioritizesOutcomeAndKeepsSavedRenderReachable() {
        let app = DemoLaunch.launch(
            tab: "clickmap",
            environment: ["GETHOG_DEMO_POPULATED_CLICKMAP_ELEMENTS": "1"],
            extraArguments: ["-ApplePersistenceIgnoreState", "YES"]
        )
        DemoLaunch.settle(app)
        leaveFullScreen(app)
        defer { resize(app, to: CGSize(width: 800, height: 600)) }

        let compactSize = CGSize(width: 640, height: 480)
        resize(app, to: compactSize)

        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.width, compactSize.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, compactSize.height, accuracy: 1)
        XCTAssertTrue(
            DemoLaunch.wait(
                timeout: 10,
                until: {
                    DemoLaunch.elements(labelled: "Pages with a render", in: app)
                        .firstMatch.exists
                        && DemoLaunch.elements(labelled: "No scroll-depth data", in: app)
                            .firstMatch.exists
                }
            ),
            "Clickmap did not settle into its deterministic render-navigation and depth-empty state."
        )

        let outcomeTitle = DemoLaunch.elements(
            labelled: "No scroll-depth data",
            in: app
        ).firstMatch
        let outcomeExplanation = DemoLaunch.elements(
            labelled: "No clicks were recorded in this period.",
            in: app
        ).firstMatch

        XCTAssertTrue(
            window.frame.contains(outcomeTitle.frame),
            "The compact initial viewport clipped the selected depth outcome title: "
                + "window=\(window.frame), title=\(outcomeTitle.frame)."
        )
        XCTAssertTrue(
            window.frame.contains(outcomeExplanation.frame),
            "The compact initial viewport clipped the selected depth outcome explanation: "
                + "window=\(window.frame), explanation=\(outcomeExplanation.frame)."
        )

        let elementsLens = DemoLaunch.elements(labelled: "Elements", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: elementsLens), "The Clickmap did not expose its Elements lens.")
        elementsLens.click()

        let populatedOutcome = DemoLaunch.waitForContent(
            containing: "Example interaction target 01",
            in: app
        )
        XCTAssertNotNil(populatedOutcome, "The populated Elements outcome never rendered.")

        let report = app.scrollViews["gethog.clickmap-report"].firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: report), "The Clickmap did not expose its report scroll view.")
        let savedRender = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Example App metric 1831")
        ).firstMatch

        var scrollCount = 0
        while !savedRender.isHittable && scrollCount < 3 {
            report.swipeUp(velocity: .slow)
            scrollCount += 1
        }

        XCTAssertTrue(
            savedRender.isHittable && window.frame.intersects(savedRender.frame),
            "Saved-render navigation stayed behind the populated Elements list after "
                + "\(scrollCount) compact report scrolls: window=\(window.frame), "
                + "render=\(savedRender.frame)."
        )
        guard savedRender.isHittable else { return }
        savedRender.click()

        XCTAssertTrue(
            DemoLaunch.wait(for: DemoLaunch.elements(labelled: "Viewports", in: app).firstMatch),
            "Activating the reachable saved-render row did not open its page overlay."
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

    private func outerSidebarIsVisible(_ app: XCUIApplication) -> Bool {
        let sidebar = app.windows.descendants(matching: .any)["gethog.mac-sidebar"]
            .firstMatch
        return sidebar.exists && sidebar.frame.width > 100
    }

    private func setOuterSidebarVisible(_ visible: Bool, in app: XCUIApplication) {
        guard outerSidebarIsVisible(app) != visible else { return }
        app.menuBars.menuBarItems["View"].click()
        let title = visible ? "Show Sidebar" : "Hide Sidebar"
        let command = app.menuItems[title]
        XCTAssertTrue(DemoLaunch.wait(for: command, timeout: 5), "View exposed no \(title).")
        command.click()
        XCTAssertTrue(
            DemoLaunch.wait(until: { self.outerSidebarIsVisible(app) == visible }),
            "View ▸ \(title) did not make rendered sidebar state match its title."
        )
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

    /// At all three compact Mac sizes the source list stays a source list,
    /// while each shared list/detail root drills into exactly one detail pane.
    func testExactCompactWindowSizesDrillIntoOnePane() {
        let app = DemoLaunch.launch()
        DemoLaunch.settle(app)
        leaveFullScreen(app)
        defer { resize(app, to: CGSize(width: 800, height: 600)) }

        for size in [
            CGSize(width: 800, height: 600),
            CGSize(width: 640, height: 480),
            CGSize(width: 560, height: 420),
        ] {
            resize(app, to: size)
            let reached = app.windows.firstMatch.frame
            print("ADAPTIVE-SIZE asked=\(size) got=\(reached) \(sidebarState(app))")
            XCTAssertEqual(reached.width, size.width, "The window missed the requested width.")
            XCTAssertEqual(reached.height, size.height, "The window missed the requested height.")

            let destinations: [(title: String, row: String, otherRow: String, detail: String)] = [
                ("Events", "meteor_report_opened", "meteor_filter_applied", "Copy as JSON"),
                ("People", "Sable Okafor", "visitor:amber-comet-73", "Distinct IDs ("),
                ("Sessions", "Alex Example", "Casey Example", "gethog.session-detail-primary"),
            ]
            for destination in destinations {
                assertCompactDrillIn(destination, at: size, in: app)
            }
            XCTAssertEqual(app.state, .runningForeground, "The \(Int(size.width))pt pass took the app down.")
        }
    }

    /// A regular-width root may own a nested `NavigationSplitView`, but that
    /// inner container must not consume the title before the scene can compose
    /// the selected destination and project identity into its native title.
    func testRegularNestedRootsKeepDestinationWindowTitle() {
        let app = DemoLaunch.launch()
        DemoLaunch.settle(app)
        leaveFullScreen(app)
        defer { resize(app, to: CGSize(width: 800, height: 600)) }

        let size = CGSize(width: 1000, height: 700)
        resize(app, to: size)
        let reached = app.windows.firstMatch.frame
        XCTAssertEqual(reached.width, size.width, "The window missed the requested width.")
        XCTAssertEqual(reached.height, size.height, "The window missed the requested height.")

        let projectIdentity = "Northstar Sandbox · Starling Metrics Lab"
        for destination in [
            "Dashboards", "Events", "Sessions", "Insights", "People", "Errors", "Flags",
        ] {
            XCTAssertTrue(
                go(destination, in: app),
                "The Go menu could not reach \(destination) at 1000pt."
            )
            let selectedRoot = app.windows.descendants(matching: .any)[
                "gethog.root.\(destination == "Errors" ? "errorTracking" : destination.lowercased())"
            ].firstMatch
            XCTAssertTrue(
                DemoLaunch.wait(for: selectedRoot),
                "The shell never selected the \(destination) root."
            )
            XCTAssertEqual(
                app.windows.firstMatch.title,
                "\(destination) – \(projectIdentity)",
                "The nested \(destination) root erased the scene's native title ownership."
            )
        }
    }

    /// A regular-width nested split must start its overview at the inner list's
    /// trailing edge, not inherit the outer source list's safe-area inset a
    /// second time. The Dashboard control is the non-nested witness: both
    /// topologies keep the same ordinary physical page inset at an exact
    /// window size and in native full screen.
    func testRegularShellUsesActualDetailWidthWithSidebarShownAndHidden() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            extraArguments: ["-ApplePersistenceIgnoreState", "YES"]
        )
        defer { app.terminate() }
        DemoLaunch.settle(app)
        leaveFullScreen(app)
        setOuterSidebarVisible(true, in: app)
        defer { setOuterSidebarVisible(true, in: app) }

        let ordinarySize = CGSize(width: 1280, height: 820)
        resize(app, to: ordinarySize)
        XCTAssertEqual(
            app.windows.firstMatch.frame.width,
            ordinarySize.width,
            "The window missed the required regular-width geometry oracle."
        )
        XCTAssertEqual(
            app.windows.firstMatch.frame.height,
            ordinarySize.height,
            "The window missed the required regular-height geometry oracle."
        )

        let destinations: [(
            title: String,
            root: String,
            anchor: String,
            minimumInnerListWidth: CGFloat?
        )] = [
            ("Dashboards", "dashboards", "gethog.dashboard-project-summary", nil),
            ("Events", "events", "gethog.signal-summary.events", 300),
            ("Sessions", "sessions", "gethog.signal-summary.sessions", 300),
            ("Insights", "insights", "gethog.signal-summary.insights", 300),
            ("People", "people", "gethog.people-overview-summary", 300),
            ("Errors", "errorTracking", "gethog.errors-overview-summary", 320),
            ("Flags", "flags", "gethog.signal-summary.flags", 280),
        ]

        for layout in ["1280x820", "full-screen"] {
            if layout == "full-screen" { enterFullScreen(app) }

            for sidebarVisible in [true, false] {
                setOuterSidebarVisible(sidebarVisible, in: app)
                if !sidebarVisible {
                    assertHiddenShellConsumesNoHorizontalChrome(in: app, at: layout)
                }

                for destination in destinations {
                    XCTAssertTrue(
                        go(destination.title, in: app),
                        "The Go menu could not reach \(destination.title) at \(layout), "
                            + "sidebar \(sidebarVisible ? "shown" : "hidden")."
                    )
                    let root = app.windows.descendants(matching: .any)[
                        "gethog.root.\(destination.root)"
                    ].firstMatch
                    guard DemoLaunch.wait(for: root) else {
                        XCTFail("The shell never selected the \(destination.title) root.")
                        continue
                    }

                    let anchor = app.windows.descendants(matching: .any)[destination.anchor]
                        .firstMatch
                    guard DemoLaunch.wait(for: anchor) else {
                        XCTFail(
                            "\(destination.title) exposed no full-width overview anchor "
                                + "\(destination.anchor) at \(layout)."
                        )
                        continue
                    }

                    let window = app.windows.firstMatch
                    let leadingColumns = window.outlines.allElementsBoundByIndex.filter {
                        $0.frame.width > 0 && $0.frame.maxX <= anchor.frame.minX + 1
                    }
                    let list = leadingColumns.max(by: { $0.frame.maxX < $1.frame.maxX })
                    if destination.title != "Dashboards" && list == nil {
                        XCTFail(
                            "\(destination.title) exposed no inner outline before its overview: "
                                + "anchor=\(anchor.frame), outlines="
                                + "\(window.outlines.allElementsBoundByIndex.map { $0.frame })."
                        )
                        continue
                    }

                    if let minimumInnerListWidth = destination.minimumInnerListWidth,
                       let list
                    {
                        XCTAssertGreaterThanOrEqual(
                            list.frame.width,
                            minimumInnerListWidth - 1,
                            "\(destination.title) compressed its inner outline below its "
                                + "declared \(minimumInnerListWidth)-point minimum at \(layout), "
                                + "sidebar \(sidebarVisible ? "shown" : "hidden"): "
                                + "\(list.frame)."
                        )
                    }

                    let leadingBoundary = list?.frame.maxX ?? window.frame.minX
                    let leadingInset = anchor.frame.minX - leadingBoundary
                    let trailingInset = window.frame.maxX - anchor.frame.maxX
                    print(
                        "SAFE-AREA-DETAIL layout=\(layout) destination=\(destination.title) "
                            + "sidebar=\(sidebarVisible) window=\(window.frame) "
                            + "list=\(String(describing: list?.frame)) anchor=\(anchor.frame) "
                            + "leading=\(leadingInset) trailing=\(trailingInset)"
                    )
                    XCTAssertLessThan(
                        leadingInset,
                        48,
                        "\(destination.title) counted the outer sidebar safe area twice at \(layout)."
                    )
                    XCTAssertEqual(
                        leadingInset,
                        trailingInset,
                        accuracy: 12,
                        "\(destination.title) did not keep equal physical overview insets at \(layout)."
                    )

                    if destination.title == "People" {
                        let viewLabel = window.staticTexts.matching(
                            DemoLaunch.macTextPredicate("View")
                        ).firstMatch
                        XCTAssertTrue(
                            DemoLaunch.wait(for: viewLabel),
                            "People exposed no View label at \(layout)."
                        )
                        XCTAssertLessThanOrEqual(
                            viewLabel.frame.height,
                            24,
                            "People wrapped View vertically at \(layout), sidebar "
                                + "\(sidebarVisible ? "shown" : "hidden"): \(viewLabel.frame)."
                        )
                    }
                }
            }
        }
    }

    private func enterFullScreen(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.frame.minY >= 50 else { return }
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10, until: {
                app.windows.firstMatch.frame.minY < 50
            }),
            "The window never entered native full screen."
        )
        DemoLaunch.settle(app)
    }

    private func assertHiddenShellConsumesNoHorizontalChrome(
        in app: XCUIApplication,
        at layout: String
    ) {
        let window = app.windows.firstMatch
        let detail = window.descendants(matching: .any)["gethog.mac-detail-column"]
            .firstMatch
        guard DemoLaunch.wait(for: detail) else {
            return XCTFail("The shell exposed no measurable detail column at \(layout).")
        }
        let divider = window.descendants(matching: .any)["gethog.mac-sidebar-divider"]
            .firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 5, until: {
                abs(detail.frame.minX - window.frame.minX) <= 1
                    && abs(detail.frame.maxX - window.frame.maxX) <= 1
                    && !divider.exists
            }),
            "The hidden shell did not finish collapsing its horizontal chrome at \(layout)."
        )

        XCTAssertEqual(
            detail.frame.minX,
            window.frame.minX,
            accuracy: 1,
            "The hidden source list or divider retained leading structural width at \(layout)."
        )
        XCTAssertEqual(
            detail.frame.maxX,
            window.frame.maxX,
            accuracy: 1,
            "The hidden shell did not propose the whole window width at \(layout)."
        )
        XCTAssertFalse(
            divider.exists,
            "The hidden shell left its divider in the accessibility or hit-test surface at \(layout)."
        )
    }

    private func assertCompactDrillIn(
        _ destination: (title: String, row: String, otherRow: String, detail: String),
        at size: CGSize,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(
            go(destination.title, in: app),
            "The Go menu could not reach \(destination.title) at \(Int(size.width))pt."
        )
        guard let row = DemoLaunch.waitForContent(containing: destination.row, in: app) else {
            return XCTFail("\(destination.title) never rendered its first row.")
        }
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: destination.otherRow, in: app),
            "\(destination.title) did not start on its list pane."
        )

        row.click()
        DemoLaunch.settle(app)

        let detailMatches: XCUIElementQuery
        if destination.detail.hasPrefix("gethog.") {
            detailMatches = app.windows.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", destination.detail))
        } else {
            detailMatches = app.windows.descendants(matching: .any)
                .matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    destination.detail,
                    destination.detail
                ))
        }
        let detail = detailMatches.firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: detail), "\(destination.title) opened no detail pane.")
        XCTAssertEqual(
            detailMatches.count,
            1,
            "\(destination.title) mounted more than one identified detail pane."
        )
        XCTAssertNil(
            DemoLaunch.waitForContent(containing: destination.otherRow, in: app, timeout: 1),
            "\(destination.title) retained its list beside the compact detail."
        )

        let back = app.windows.buttons["Back"].firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: back), "\(destination.title) detail offered no Back control.")
        XCTAssertTrue(back.isHittable, "\(destination.title)'s Back control was not hittable.")
        capture("adaptive-\(Int(size.width))-\(destination.title.lowercased())-detail")
        back.click()
        XCTAssertNotNil(
            DemoLaunch.waitForContent(containing: destination.otherRow, in: app),
            "Back did not restore the \(destination.title) list."
        )
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
