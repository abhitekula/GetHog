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

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.dashboard.",
            containing: "Example App metric 33",
            action: "Open Dashboard",
            in: app
        )
        assertFact("Pinned", in: preview, surface: "Dashboard")
        dismissPreview(preview, returningTo: "Dashboards", row: row, in: app)

        row.tap()
        let detail = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.dashboard-detail."
        )
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

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.insight.",
            containing: "Example meteor report",
            action: "Open Insight",
            in: app
        )
        assertFact("On 2 dashboards", in: preview, surface: "Insight")
        dismissPreview(preview, returningTo: "Insights", row: row, in: app)

        row.tap()
        let detail = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.insight-detail.710101"
        )
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

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.event.",
            containing: "meteor_report_opened",
            action: "Open Event",
            in: app
        )
        assertFact("person-example-meteor-201", in: preview, surface: "Event")
        dismissPreview(preview, returningTo: "Events", row: row, in: app)

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
        reveal(loadedDigestRow, in: app, named: "Alex Example")
        let loadedDigestPreview = openPreview(
            row: loadedDigestRow,
            identifierStartingWith: "gethog.quick-preview.session.",
            containing: "Alex Example",
            action: "Open Session",
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

        loadedDigestRow.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.descendants(matching: .any)["gethog.session-detail-primary"]),
            "Ordinary loaded-digest session activation did not open its in-app detail."
        )
        returnToListIfNeeded(from: "Alex Example", titled: "Sessions", in: app)

        let unplayableID = "018f1000-0000-7000-8000-000000000004"
        let unplayableRow = DemoLaunch.element(
            in: app,
            identifierStartingWith: "gethog.session-card.\(unplayableID)"
        )
        reveal(unplayableRow, in: app, named: "Riley Example")
        let unplayablePreview = openPreview(
            row: unplayableRow,
            identifierStartingWith: "gethog.quick-preview.session.",
            containing: "Riley Example",
            action: "Open Session",
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

        unplayableRow.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.descendants(matching: .any)["gethog.session-detail-primary"]),
            "Ordinary unplayable session activation did not open its in-app detail."
        )
    }

    @MainActor
    func testFlagPreviewKeepsItsActionsAndNavigationInsideGetHog() {
        let app = DemoLaunch.launch(tab: "flags")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Flags"]))

        let row = DemoLaunch.element(in: app, labelContaining: "example-navigation")
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo Flags list offered no real row.")

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.flag.",
            containing: "example-navigation",
            action: "Open Flag",
            in: app
        )
        assertFact("61% rollout", in: preview, surface: "Flag")
        dismissPreview(preview, returningTo: "Flags", row: row, in: app)

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

        let row = DemoLaunch.element(in: app, labelContaining: "HarborRenderFault")
        XCTAssertTrue(DemoLaunch.wait(for: row), "The demo Errors list offered no real row.")

        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.error.",
            containing: "HarborRenderFault",
            action: "Open Issue",
            in: app
        )
        assertFact("29 occurrences", in: preview, surface: "Error")
        dismissPreview(preview, returningTo: "Errors", row: row, in: app)

        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["HarborRenderFault"]),
            "Ordinary error activation did not open its in-app detail."
        )
    }

    @MainActor
    func testTracePreviewKeepsItsActionsAndNavigationInsideGetHog() throws {
        let app = DemoLaunch.launch(tab: "tracing")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Tracing"]))

        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", " span"))
            .firstMatch
        let documentedEmptyState = app.staticTexts
            .matching(NSPredicate(
                format: "label BEGINSWITH %@",
                "No spans in the last 24 hours"
            ))
            .firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(until: { row.exists || documentedEmptyState.exists }),
            "Tracing reached neither a real trace row nor its documented empty state."
        )
        XCTAssertTrue(
            row.exists || documentedEmptyState.exists,
            "The demo Tracing screen did not expose a terminal result."
        )
        try XCTSkipIf(
            !row.exists,
            "DemoTransport intentionally returns no rows for TraceSpansQuery; a fixture owner must add a deterministic trace before this interaction journey can run."
        )

        let operation = row.label.split(separator: ",", maxSplits: 1)
            .first.map(String.init) ?? row.label
        let preview = openPreview(
            row: row,
            identifierStartingWith: "gethog.quick-preview.trace.",
            containing: operation,
            action: "Open Trace",
            in: app
        )
        assertFact("Status", in: preview, surface: "Trace")
        assertFact("span", in: preview, surface: "Trace")
        dismissPreview(preview, returningTo: "Tracing", row: row, in: app)

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
        in app: XCUIApplication
    ) -> XCUIElement {
        row.press(forDuration: 1.0)

        let host = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Preview"))
            .firstMatch
        // In a regular-width split view, a NavigationLink that has no current
        // selection can consume the first long press by selecting its detail.
        // The row remains visible in the list column; a second deliberate long
        // press then reaches the same authored context menu.
        if !DemoLaunch.wait(for: host, timeout: 3), row.exists && row.isHittable {
            row.press(forDuration: 1.0)
        }
        XCTAssertTrue(
            DemoLaunch.wait(for: host),
            "The system Preview host never appeared for \(content)."
        )

        let preview = DemoLaunch.quickPreview(
            in: app,
            identifierStartingWith: prefix,
            containing: content
        )
        XCTAssertTrue(
            DemoLaunch.wait(for: preview),
            "The semantic Quick Preview content never appeared for \(content)."
        )
        assertInAppMenu(action: action, in: app)
        return preview
    }

    @MainActor
    private func assertFact(_ fact: String, in preview: XCUIElement, surface: String) {
        XCTAssertTrue(
            DemoLaunch.wait(until: { preview.label.contains(fact) }),
            "The \(surface) preview omitted \(fact)."
        )
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
    private func returnToListIfNeeded(
        from detailTitle: String,
        titled listTitle: String,
        in app: XCUIApplication
    ) {
        if app.navigationBars[listTitle].exists { return }

        let detailBar = app.navigationBars[detailTitle]
        let back = detailBar.buttons.firstMatch
        if detailBar.exists && back.exists && back.isHittable {
            back.tap()
        }
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars[listTitle]),
            "Could not return from \(detailTitle) to \(listTitle)."
        )
    }

    @MainActor
    private func assertInAppMenu(action: String, in app: XCUIApplication) {
        XCTAssertTrue(DemoLaunch.wait(for: app.buttons[action]), "The menu omitted \(action).")
        for forbidden in ["Open in PostHog", "Copy link"] {
            let control = app.buttons[forbidden]
            XCTAssertFalse(
                control.exists && control.isHittable,
                "The Quick Preview menu exposed \(forbidden)."
            )
        }
    }
}
