import XCTest

@MainActor
final class VisionWindowTests: XCTestCase {
    /// Catches a Dashboard landing change that restores separate signal and
    /// collection scroll containers instead of one regular-width dashboard hub.
    func testDashboardLandingUsesOneRegularWidthHub() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: ["GETHOG_VISION_CONTENT_WIDTH": "1280"]
        )

        let hubs = app.scrollViews.matching(
            NSPredicate(format: "identifier == %@", "gethog.dashboard-hub")
        )
        let hub = hubs.firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The regular dashboard landing did not expose gethog.dashboard-hub.")
        }
        XCTAssertEqual(hubs.count, 1, "The dashboard landing must expose exactly one hub.")
        guard hubs.count == 1 else { return }

        let projectSignal = hub.staticTexts["Project signal"].firstMatch
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
        XCTAssertGreaterThanOrEqual(card.frame.minX, hub.frame.minX)
    }

    func testDashboardDetailNeverClaimsEmptyAcrossDelayedListFailure() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: [
                "GETHOG_DEMO_DASHBOARD_LIST_DELAY_MS": "2500",
                "GETHOG_DEMO_DASHBOARD_LIST_FAILURE": "1",
                "GETHOG_VISION_CONTENT_WIDTH": "1280",
            ]
        )

        let emptyTitles = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "No dashboards")
        )
        let loading = app.staticTexts["Loading dashboards…"].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 3, until: {
                loading.exists || emptyTitles.count > 0
            }),
            "The regular dashboard detail exposed neither loading nor its former false-empty state."
        )
        XCTAssertTrue(
            loading.exists,
            "The regular dashboard detail showed No dashboards while its list was still loading."
        )
        guard loading.exists else { return }
        XCTAssertEqual(
            emptyTitles.count,
            0,
            "The regular dashboard detail claimed the still-loading collection was empty."
        )
        XCTAssertGreaterThan(
            loading.frame.midX,
            app.windows.firstMatch.frame.midX,
            "The loading treatment rendered in the list rather than the detail pane."
        )

        let failures = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Couldn't load dashboards")
        )
        XCTAssertTrue(
            DemoLaunch.wait(timeout: 10, until: {
                failures.count == 1 && !loading.exists
            }),
            "The delayed list failure did not replace loading with one authoritative error."
        )
        XCTAssertEqual(
            emptyTitles.count,
            0,
            "The regular dashboard detail relabelled a failed collection as empty."
        )
        XCTAssertGreaterThan(
            failures.firstMatch.frame.midX,
            app.windows.firstMatch.frame.midX,
            "The failure treatment rendered in the list rather than the detail pane."
        )
    }

    func testEmptyDashboardCollectionShowsOneBrandedStateAtRegularWidth() {
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: [
                "GETHOG_DEMO_EMPTY_COLLECTION": "dashboards",
                "GETHOG_VISION_CONTENT_WIDTH": "1280",
            ]
        )

        let emptyTitles = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "No dashboards")
        )
        XCTAssertTrue(
            DemoLaunch.wait(until: { emptyTitles.count > 0 }),
            "The regular-width dashboard did not render its branded empty state."
        )
        DemoLaunch.settle(app)
        XCTAssertEqual(
            emptyTitles.count,
            1,
            "The regular split rendered the full dashboard empty state in more than one column."
        )
    }

    func testSectionSidebarAdaptsToANarrowWindow() {
        let contentWidth: CGFloat = 640
        let app = DemoLaunch.launch(
            tab: "dashboards",
            environment: [
                "GETHOG_VISION_CONTENT_WIDTH": String(Int(contentWidth)),
            ]
        )

        let dashboard = app.staticTexts[DemoLaunch.firstTileTitle].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: dashboard),
            "The narrow Vision window did not leave the dashboard content usable."
        )

        // At this width a native split may collapse the product sidebar. If it
        // keeps both columns visible, the sidebar must negotiate below the old
        // fixed 280pt width rather than consuming almost half of the window.
        let sidebar = app.collectionViews["gethog.vision.section-sidebar"].firstMatch
        if sidebar.exists && sidebar.isHittable {
            XCTAssertLessThan(
                sidebar.frame.width,
                contentWidth * 0.4,
                "The section sidebar retained its fixed width in a narrow Vision window."
            )
        }

        // Never trust the roster's `isHittable` result as proof that it is on
        // top: visionOS retains covered split columns in the hierarchy. The
        // route bar must remain genuinely interactive at the narrow proposal.
        let events = VisionSidebar.destinationControl("Events", in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                events.exists && events.isHittable
            }),
            "The narrow section did not leave a visible Events route control."
        )
        guard events.exists else { return }
        events.tap()
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                (events.value as? String) == "Selected"
            }),
            "The narrow route bar did not retain Events as its selection."
        )
        let eventFixture = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "meteor_report_opened",
                "meteor_report_opened"
            )
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: eventFixture),
            "The narrow route bar did not render the Events fixture."
        )
    }

    func testRestoredLateMonitorRouteIsFullyVisibleAtNarrowWidth() {
        let width = "640"
        let app = DemoLaunch.launch(
            tab: "ingestion",
            environment: ["GETHOG_VISION_CONTENT_WIDTH": width]
        )

        guard assertIngestionIsFullyVisible(in: app) != nil else { return }
        DemoLaunch.settle(app)
        app.terminate()

        let restored = DemoLaunch.launch(
            environment: ["GETHOG_VISION_CONTENT_WIDTH": width]
        )
        guard let ingestion = assertIngestionIsFullyVisible(in: restored) else { return }

        let strip = restored.scrollViews["gethog.vision.section-destination-strip"].firstMatch
        guard DemoLaunch.wait(for: strip) else {
            return XCTFail("The restored Monitor section did not expose its destination strip.")
        }

        // Move away from the restored late route before returning to it. This
        // proves that the overflow strip can both reveal an earlier route and
        // activate Ingestion again; an offscreen element that merely reports
        // `isHittable` cannot satisfy the selected-value transitions.
        let signals = VisionSidebar.destinationControl("Signals", in: restored)
        for _ in 0..<4 where !isFullyVisible(signals, in: restored) {
            strip.swipeRight(velocity: .slow)
        }
        guard DemoLaunch.wait(until: {
            isFullyVisible(signals, in: restored) && signals.isHittable
        }) else {
            return XCTFail("The Monitor strip could not reveal its earlier Signals route.")
        }
        signals.tap()
        guard DemoLaunch.wait(until: {
            (signals.value as? String) == "Selected"
        }) else {
            return XCTFail("The revealed Signals route did not accept activation.")
        }

        for _ in 0..<4 where !isFullyVisible(ingestion, in: restored) {
            strip.swipeLeft(velocity: .slow)
        }
        guard DemoLaunch.wait(until: {
            isFullyVisible(ingestion, in: restored) && ingestion.isHittable
        }) else {
            return XCTFail("The Monitor strip could not return to the Ingestion route.")
        }
        ingestion.tap()

        let loadedWarning = restored.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Cannot merge already identified",
                "Cannot merge already identified"
            )
        ).firstMatch
        let cleanState = restored.staticTexts["Ingestion looks clean"].firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                loadedWarning.exists || cleanState.exists
            }),
            "Activating Ingestion did not reach a loaded terminal state."
        )
        XCTAssertEqual(
            ingestion.value as? String,
            "Selected",
            "The Ingestion route did not retain selection after activation."
        )
    }

    @discardableResult
    private func assertIngestionIsFullyVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        guard DemoLaunch.wait(for: app.navigationBars["Ingestion"].firstMatch),
              let viewport = contentViewportFrame(in: app)
        else {
            XCTFail("The Vision app did not expose its content viewport.", file: file, line: line)
            return nil
        }

        let ingestion = VisionSidebar.destinationControl("Ingestion", in: app)
        guard DemoLaunch.wait(for: ingestion) else {
            XCTFail("The Monitor section did not expose Ingestion.", file: file, line: line)
            return nil
        }
        XCTAssertEqual(
            ingestion.value as? String,
            "Selected",
            "The restored Monitor route was not Ingestion.",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            ingestion.frame.width,
            0,
            "The selected Ingestion route had no rendered width.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            ingestion.frame.minX,
            viewport.minX - 1,
            "The selected Ingestion route was clipped beyond the viewport's leading edge.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            ingestion.frame.maxX,
            viewport.maxX + 1,
            "The selected Ingestion route was clipped beyond the viewport's trailing edge.",
            file: file,
            line: line
        )
        return ingestion
    }

    private func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, let viewport = contentViewportFrame(in: app) else {
            return false
        }
        let frame = element.frame
        return frame.width > 0
            && frame.minX >= viewport.minX - 1
            && frame.maxX <= viewport.maxX + 1
    }

    /// Vision's AX window list starts with the ornament and reports the main
    /// scene as a screen-sized proxy, so neither frame is the rendered product
    /// window. The widest visible navigation bar marks the product pane; union
    /// with the section roster gives the actual horizontal content envelope.
    private func contentViewportFrame(in app: XCUIApplication) -> CGRect? {
        let navigationBars = app.navigationBars.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.width > 0 && $0.frame.height > 0
        }
        guard let contentBar = navigationBars.max(by: {
            $0.frame.width < $1.frame.width
        }) else { return nil }

        let roster = app.collectionViews["gethog.vision.section-sidebar"].firstMatch
        guard roster.exists, roster.frame.width > 0, roster.frame.height > 0 else {
            return contentBar.frame
        }
        return contentBar.frame.union(roster.frame)
    }

    func testSiblingSplitRootsKeepTheSectionRosterInOneStableColumn() {
        let width = ["GETHOG_VISION_CONTENT_WIDTH": "1280"]
        let analyze = DemoLaunch.launch(tab: "webAnalytics", environment: width)
        guard contentElement(containing: "Overview", in: analyze) != nil,
              let analyzeRoster = visibleSectionRosterFrame(in: analyze)
        else { return }

        assertStableSectionRoster(
            afterActivating: "Events",
            contentWitness: "meteor_report_opened",
            baseline: analyzeRoster,
            in: analyze
        )
        assertStableSectionRoster(
            afterActivating: "Sessions",
            contentWitness: "Alex Example",
            baseline: analyzeRoster,
            in: analyze
        )
        analyze.terminate()

        let experiment = DemoLaunch.launch(tab: "experiments", environment: width)
        guard contentElement(containing: "Example cache strategy trial", in: experiment) != nil,
              let experimentRoster = visibleSectionRosterFrame(in: experiment)
        else { return }

        assertStableSectionRoster(
            afterActivating: "Flags",
            contentWitness: "Example navigation preview",
            baseline: experimentRoster,
            in: experiment
        )
    }

    private func assertStableSectionRoster(
        afterActivating destination: String,
        contentWitness: String,
        baseline: CGRect,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard VisionSidebar.tap(destination, in: app, file: file, line: line),
              let witness = contentElement(containing: contentWitness, in: app),
              let current = visibleSectionRosterFrame(in: app, file: file, line: line)
        else { return }

        XCTAssertEqual(current.minX, baseline.minX, accuracy: 2, file: file, line: line)
        XCTAssertEqual(current.minY, baseline.minY, accuracy: 2, file: file, line: line)
        XCTAssertEqual(current.width, baseline.width, accuracy: 2, file: file, line: line)
        XCTAssertEqual(current.height, baseline.height, accuracy: 2, file: file, line: line)

        let rosterInterior = current.insetBy(dx: 2, dy: 2)
        guard let viewportWidth = contentViewportFrame(in: app)?.width else {
            return XCTFail(
                "\(destination) exposed no measurable content viewport.",
                file: file,
                line: line
            )
        }
        // A host-owned root List is reported by Vision AX as spanning the full
        // viewport even though its rendered rows begin after the roster; the
        // witness-origin check below pins those rows. A nested split is the
        // distinct partial-width collection that previously covered the roster
        // (560pt in the valid RED), so reject that concrete extra column.
        let nestedSplitCollections = app.collectionViews.allElementsBoundByIndex.filter {
            $0.identifier != "gethog.vision.section-sidebar"
                && $0.exists
                && $0.isHittable
                && $0.frame.width > 0
                && $0.frame.height > 0
                && $0.frame.width < viewportWidth - 2
                && $0.frame.intersects(rosterInterior)
        }
        XCTAssertTrue(
            nestedSplitCollections.isEmpty,
            "\(destination) mounted a collection over the section roster: "
                + nestedSplitCollections.map {
                    "\($0.identifier.isEmpty ? "<unidentified>" : $0.identifier) \($0.frame)"
                }.joined(separator: ", "),
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            witness.frame.minX,
            current.maxX - 2,
            "\(destination)'s loaded content began inside the section roster.",
            file: file,
            line: line
        )
    }

    private func visibleSectionRosterFrame(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect? {
        let roster = app.collectionViews["gethog.vision.section-sidebar"].firstMatch
        guard DemoLaunch.wait(until: {
            roster.exists
                && roster.isHittable
                && roster.frame.width > 0
                && roster.frame.height > 0
        }) else {
            XCTFail("The Vision section roster was not visibly rendered.", file: file, line: line)
            return nil
        }
        return roster.frame
    }

    private func contentElement(
        containing text: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let predicate = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            text,
            text
        )
        let candidates = [
            app.staticTexts.matching(predicate).firstMatch,
            app.buttons.matching(predicate).firstMatch,
            app.cells.matching(predicate).firstMatch,
        ]
        guard DemoLaunch.wait(until: {
            candidates.contains(where: \.exists)
        }) else {
            XCTFail("The rendered screen never exposed \(text).", file: file, line: line)
            return nil
        }
        return candidates.first(where: \.exists)
    }

    func testDashboardTearsOffIntoItsOwnWindow() {
        let app = DemoLaunch.launch()
        let analyzeSection = VisionSidebar.section("Analyze", in: app)
        guard DemoLaunch.wait(until: {
            analyzeSection.exists && analyzeSection.isHittable
        }) else {
            return XCTFail("The Vision sidebar did not offer its Analyze section.")
        }
        analyzeSection.tap()
        guard VisionSidebar.tap("Dashboards", in: app) else { return }

        let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
        guard DemoLaunch.wait(for: hub) else {
            return XCTFail("The Vision Dashboards route did not expose its unified hub.")
        }
        // The hub's adaptive grid is lazy, so bring the stable card activation
        // boundary into the one shared scroll surface before opening it.
        let dashboard = hub.buttons["gethog.dashboard-card.725101"].firstMatch
        for _ in 0..<6 where !dashboard.exists {
            hub.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        guard DemoLaunch.wait(for: dashboard) else {
            return XCTFail("The unified dashboard hub did not expose its first card.")
        }
        dashboard.tap()
        XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts[DemoLaunch.firstTileTitle]))

        let startingWindows = app.windows.count
        app.buttons["Dashboard actions"].tap()
        // SwiftUI exposes popover actions as buttons on visionOS rather than
        // AppKit-style menu items. Match the user-facing action independent of
        // that platform implementation detail.
        let tearOff = DemoLaunch.elements(labelled: "Open in new window", in: app).firstMatch
        guard DemoLaunch.wait(for: tearOff) else {
            return XCTFail("Dashboard actions never offered Open in new window.")
        }
        tearOff.tap()

        XCTAssertTrue(
            DemoLaunch.wait(timeout: 30, until: {
                DemoLaunch.elements(labelled: DemoLaunch.firstTileTitle, in: app).count >= 2
            }),
            "The dashboard tile did not render in a second Vision window."
        )
        XCTAssertGreaterThanOrEqual(app.windows.count, startingWindows + 1)
    }
}
