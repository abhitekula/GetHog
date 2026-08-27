import XCTest

final class QuickPreviewInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDashboardPreviewKeepsItsActionsAndNavigationInsideGetHog() {
        let app = DemoLaunch.launch(tab: "dashboards")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Dashboards"]))

        let row = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.dashboard-card."
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo dashboard list offered no real row.")
        let detail = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.dashboard-detail."
        )

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.dashboard.",
            containing: "Example App metric 33",
            action: "Open Dashboard",
            destination: detail,
            in: app
        )
        assertFact("7 tiles", in: preview, surface: "Dashboard cached enrichment")
        assertFact(
            "Example weekly engagement pulse",
            in: preview,
            surface: "Dashboard cached enrichment"
        )
        dismissPreview(preview, returningTo: "Dashboards", row: row, in: app)

        _ = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.dashboard.",
            containing: "Example App metric 33",
            action: "Open Dashboard",
            destination: detail,
            in: app
        )
        activateOpenAction("Open Dashboard", destination: detail, in: app)

        DemoLaunch.relaunch(app)
        XCTAssertFalse(detail.exists, "Dashboard detail was already selected before activation.")
        XCTAssertTrue(DemoLaunch.wait(for: row), "Dashboard row did not reload for activation.")
        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: detail),
            "Ordinary dashboard activation did not open its in-app detail."
        )
    }

    @MainActor
    func testInsightPreviewKeepsItsActionsAndNavigationInsideGetHog() {
        let app = DemoLaunch.launch(tab: "insights")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Insights"]))

        let row = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.insight-card.710101"
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo Insights list offered no real row.")
        let detail = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.insight-detail.710101"
        )

        var preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.insight.",
            containing: "Example meteor report",
            action: "Open Insight",
            destination: detail,
            in: app
        )
        if !waitForFact("Cached line chart, 2 series", in: preview, timeout: 3) {
            // On regular-width iOS 26.5, the system Preview host can freeze the
            // first semantic snapshot while the store-owned cache request
            // completes. A remount reads that completed state immediately.
            dismissPreview(preview, returningTo: "Insights", row: row, in: app)
            preview = openPreview(
                row: row,
                identifierStartingWith: "gethog.quick-preview.insight.",
                containing: "Example meteor report",
                action: "Open Insight",
                destination: detail,
                in: app
            )
        }
        assertFact(
            "Cached line chart, 2 series",
            in: preview,
            surface: "Insight cached enrichment"
        )
        dismissPreview(preview, returningTo: "Insights", row: row, in: app)

        _ = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.insight.",
            containing: "Example meteor report",
            action: "Open Insight",
            destination: detail,
            in: app
        )
        activateOpenAction("Open Insight", destination: detail, in: app)

        DemoLaunch.relaunch(app)
        XCTAssertFalse(detail.exists, "Insight detail was already selected before activation.")
        XCTAssertTrue(DemoLaunch.wait(for: row), "Insight row did not reload for activation.")
        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: detail),
            "Ordinary insight activation did not open its in-app detail."
        )
    }

    @MainActor
    func testEventPreviewKeepsItsActionsAndNavigationInsideGetHog() {
        let app = DemoLaunch.launch(tab: "events")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Events"]))

        let row = DemoLaunch.element(in: app, labelContaining: "meteor_report_opened")
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo Events list offered no real row.")
        let detail = app.navigationBars["meteor_report_opened"]

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.event.",
            containing: "meteor_report_opened",
            action: "Open Event",
            destination: detail,
            in: app
        )
        assertFact("person-example-meteor-201", in: preview, surface: "Event")
        dismissPreview(preview, returningTo: "Events", row: row, in: app)

        _ = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.event.",
            containing: "meteor_report_opened",
            action: "Open Event",
            destination: detail,
            in: app
        )
        activateOpenAction("Open Event", destination: detail, in: app)

        DemoLaunch.relaunch(app)
        XCTAssertFalse(
            app.navigationBars["meteor_report_opened"].exists,
            "Event detail was already selected before activation."
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "Event row did not reload for activation.")
        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["meteor_report_opened"]),
            "Ordinary event activation did not open its in-app detail."
        )
    }

    @MainActor
    func testSessionPreviewsCoverLoadedDigestAndUnplayableRecording() {
        let app = DemoLaunch.launch(tab: "sessions")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Sessions"]))

        let loadedDigestRow = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.session-card.\(DemoLaunch.replaySessionID)"
        )
        let loadedDigestDetail = app.navigationBars["Alex Example"]
        reveal(loadedDigestRow, in: app, named: "Alex Example")
        let loadedDigestPreview = openPreview(
            row: loadedDigestRow,
            identifierStartingWith: "gethog.quick-preview.session.",
            containing: "Alex Example",
            action: "Open Session",
            destination: loadedDigestDetail,
            in: app
        )
        assertFact(
            "Reviewed the orbital dashboard",
            in: loadedDigestPreview,
            surface: "loaded-digest Session"
        )
        dismissPreview(
            loadedDigestPreview,
            returningTo: "Sessions",
            row: loadedDigestRow,
            in: app
        )

        _ = openPreview(
            row: loadedDigestRow,
            identifierStartingWith: "gethog.quick-preview.session.",
            containing: "Alex Example",
            action: "Open Session",
            destination: loadedDigestDetail,
            in: app
        )
        activateOpenAction("Open Session", destination: loadedDigestDetail, in: app)
        XCTAssertTrue(
            DemoLaunch.wait(
                for: app.descendants(matching: .any)["gethog.session-detail-primary"]
            ),
            "Open Session did not reach the selected recording detail."
        )

        DemoLaunch.relaunch(app)
        XCTAssertFalse(
            app.navigationBars["Alex Example"].exists,
            "Alex Example was already selected before ordinary activation."
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: loadedDigestRow),
            "Alex Example did not reload for ordinary activation."
        )
        loadedDigestRow.tap()
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                app.navigationBars["Alex Example"].exists
                    && app.descendants(matching: .any)["gethog.session-detail-primary"].exists
            }),
            "Ordinary loaded-digest session activation did not open its in-app detail."
        )

        DemoLaunch.relaunch(app)

        let unplayableID = "018f1000-0000-7000-8000-000000000004"
        let unplayableRow = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.session-card.\(unplayableID)"
        )
        let unplayableDetail = app.navigationBars["Riley Example"]
        reveal(unplayableRow, in: app, named: "Riley Example")
        let unplayablePreview = openPreview(
            row: unplayableRow,
            identifierStartingWith: "gethog.quick-preview.session.",
            containing: "Riley Example",
            action: "Open Session",
            destination: unplayableDetail,
            in: app
        )
        assertFact("Not playable", in: unplayablePreview, surface: "mobile Session")
        assertFact("Mobile", in: unplayablePreview, surface: "mobile Session")
        dismissPreview(
            unplayablePreview,
            returningTo: "Sessions",
            row: unplayableRow,
            in: app
        )

        DemoLaunch.relaunch(app)
        reveal(unplayableRow, in: app, named: "Riley Example")
        XCTAssertFalse(
            app.navigationBars["Riley Example"].exists,
            "Riley Example was already selected before ordinary activation."
        )
        unplayableRow.tap()
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                app.navigationBars["Riley Example"].exists
                    && app.descendants(matching: .any)["gethog.session-detail-primary"].exists
            }),
            "Ordinary unplayable session activation did not open its in-app detail."
        )
    }

    @MainActor
    func testFlagPreviewKeepsItsActionsAndNavigationInsideGetHog() {
        let app = DemoLaunch.launch(tab: "flags")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Flags"]))

        let row = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.flag-row.",
            labelContaining: "example-navigation"
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo Flags list offered no real row.")
        let detail = app.navigationBars["example-navigation"]

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.flag.",
            containing: "example-navigation",
            action: "Open Flag",
            destination: detail,
            in: app
        )
        assertFact("61% rollout", in: preview, surface: "Flag")
        dismissPreview(preview, returningTo: "Flags", row: row, in: app)

        _ = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.flag.",
            containing: "example-navigation",
            action: "Open Flag",
            destination: detail,
            in: app
        )
        activateOpenAction("Open Flag", destination: detail, in: app)

        DemoLaunch.relaunch(app)
        XCTAssertFalse(
            app.navigationBars["example-navigation"].exists,
            "Flag detail was already selected before activation."
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "Flag row did not reload for activation.")
        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["example-navigation"]),
            "Ordinary flag activation did not open its in-app detail."
        )
    }

    @MainActor
    func testErrorPreviewKeepsItsActionsAndNavigationInsideGetHog() {
        let app = DemoLaunch.launch(tab: "errorTracking")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Errors"]))

        let row = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.error-row.",
            labelContaining: "HarborRenderFault"
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo Errors list offered no real row.")
        let detail = app.navigationBars["HarborRenderFault"]

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.error.",
            containing: "HarborRenderFault",
            action: "Open Issue",
            destination: detail,
            in: app
        )
        assertFact("29 occurrences", in: preview, surface: "Error")
        dismissPreview(preview, returningTo: "Errors", row: row, in: app)

        _ = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.error.",
            containing: "HarborRenderFault",
            action: "Open Issue",
            destination: detail,
            in: app
        )
        activateOpenAction("Open Issue", destination: detail, in: app)

        DemoLaunch.relaunch(app)
        XCTAssertFalse(
            app.navigationBars["HarborRenderFault"].exists,
            "Error detail was already selected before activation."
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "Error row did not reload for activation.")
        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["HarborRenderFault"]),
            "Ordinary error activation did not open its in-app detail."
        )
    }

    @MainActor
    func testTracePreviewKeepsItsActionsAndNavigationInsideGetHog() {
        let app = DemoLaunch.launch(tab: "tracing")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Tracing"]))

        let operation = "GET /synthetic/orbital-map"
        let row = DemoLaunch.element(in: app, labelContaining: operation)
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo Tracing list offered no real row.")
        let detail = app.navigationBars[operation]
        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.trace.",
            containing: operation,
            action: "Open Trace",
            destination: detail,
            in: app
        )
        assertFact("3 spans", in: preview, surface: "Trace")
        assertFact("1 error", in: preview, surface: "Trace")
        dismissPreview(preview, returningTo: "Tracing", row: row, in: app)

        _ = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.trace.",
            containing: operation,
            action: "Open Trace",
            destination: detail,
            in: app
        )
        activateOpenAction("Open Trace", destination: detail, in: app)

        DemoLaunch.relaunch(app)
        XCTAssertFalse(
            app.navigationBars[operation].exists,
            "Trace detail was already selected before activation."
        )
        XCTAssertTrue(DemoLaunch.wait(for: row), "Trace row did not reload for activation.")
        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars[operation]),
            "Ordinary trace activation did not open its in-app detail."
        )
    }

    @MainActor
    private func openPreview(
        row: XCUIElement,
        identifierStartingWith prefix: String,
        containing content: String,
        action: String,
        destination: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        row.press(forDuration: 1.0)

        let authored = DemoLaunch.element(in: app, identifierStartingWith: prefix)
        let host = DemoLaunch.previewHost(in: app)
        XCTAssertTrue(
            DemoLaunch.wait(until: { authored.exists || host.exists }),
            "One long press showed neither the authored preview nor the system Preview host for \(content)."
        )
        XCTAssertFalse(
            destination.exists,
            "The first long press selected detail for \(content) before an explicit Open action."
        )

        let preview = DemoLaunch.quickPreview(
            in: app,
            identifierStartingWith: prefix,
            containing: content
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: preview),
            "The Quick Preview surface never appeared for \(content)."
        )
        assertFact(content, in: preview, surface: "semantic Quick Preview")
        assertInAppMenu(action: action, in: app)
        return preview
    }

    @MainActor
    private func activateOpenAction(
        _ action: String,
        destination: XCUIElement,
        in app: XCUIApplication
    ) {
        let menu = DemoLaunch.contextMenu(in: app, containingAction: action)
        XCTAssertTrue(DemoLaunch.wait(for: menu), "The menu omitted \(action).")
        let button = menu.buttons[action]
        XCTAssertTrue(button.exists, "The menu omitted \(action).")
        button.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: destination),
            "\(action) did not open its exact in-app destination."
        )
    }

    @MainActor
    private func assertFact(_ fact: String, in preview: XCUIElement, surface: String) {
        XCTAssertTrue(
            waitForFact(fact, in: preview),
            "The \(surface) preview omitted \(fact)."
        )
    }

    @MainActor
    private func waitForFact(
        _ fact: String,
        in preview: XCUIElement,
        timeout: TimeInterval = 30
    ) -> Bool {
        let descendant = preview.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", fact))
            .firstMatch
        return DemoLaunch.wait(timeout: timeout) {
            preview.label.contains(fact) || descendant.exists
        }
    }

    @MainActor
    private func dismissPreview(
        _ preview: XCUIElement,
        returningTo listTitle: String,
        row: XCUIElement,
        in app: XCUIApplication
    ) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)).tap()
        XCTAssertTrue(
            DemoLaunch.wait(until: {
                !preview.exists && app.navigationBars[listTitle].exists && row.exists
            }),
            "Dismissing Quick Preview did not return to the \(listTitle) list."
        )
    }

    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication, named name: String) {
        let firstSession = app.buttons[
            "gethog.session-card.\(DemoLaunch.replaySessionID)"
        ]
        let sessionsList = app.collectionViews
            .containing(.button, identifier: firstSession.identifier)
            .firstMatch
        for _ in 0..<6 where !row.isHittable {
            if sessionsList.exists {
                sessionsList.swipeUp()
            } else if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else {
                app.swipeUp()
            }
            _ = DemoLaunch.wait(timeout: 1) { row.isHittable }
        }
        XCTAssertTrue(row.exists && row.isHittable, "The Sessions list did not reveal \(name).")
    }

    @MainActor
    private func assertInAppMenu(action: String, in app: XCUIApplication) {
        let menu = DemoLaunch.contextMenu(in: app, containingAction: action)
        XCTAssertTrue(DemoLaunch.wait(for: menu), "The menu omitted \(action).")
        XCTAssertTrue(menu.buttons[action].exists, "The menu omitted \(action).")
        for forbidden in ["Open in PostHog", "Copy link"] {
            XCTAssertEqual(
                menu.buttons.matching(NSPredicate(format: "label == %@", forbidden)).count,
                0,
                "The Quick Preview menu exposed \(forbidden)."
            )
        }
    }
}
