import XCTest

/// Apple's own audit, run over the app's main screens.
///
/// **Only two of the seven audit types are asserted, and the exclusions are the
/// point of this comment.** A sweep of `performAccessibilityAudit(for: .all)`
/// across 22 screens of the demo build measured:
///
/// | audit type                     | hits |
/// | ------------------------------ | ---- |
/// | `sufficientElementDescription` |    0 |
/// | `trait`                        |    0 |
/// | `contrast`                     |   79 |
/// | `dynamicType`                  |   30 |
/// | `textClipped`                  |   37 |
/// | `elementDetection`             |    7 |
///
/// The first two are genuinely clean, so they are asserted **strictly** — no
/// issue handler, no allowlist — and any hit is a real regression: an unlabelled
/// control, or one whose traits contradict what it does.
///
/// The other four are heuristics with a false-positive rate this app cannot
/// usefully drive to zero. `textClipped` is dominated by search-field
/// placeholders, which the system draws and truncates itself; `contrast` samples
/// composited pixels and fires on the app's own deliberate secondary/tertiary ink
/// ramp; `dynamicType` and `elementDetection` fire on system-drawn chrome.
/// Including them would mean a permanently red test, and the cure for a
/// permanently red test is always to loosen it.
///
/// So: if this test starts failing, the fix is the app, not the filter. Adding an
/// audit type here without re-measuring, or adding an issue handler that returns
/// `true`, converts a working regression detector back into decoration.
///
/// **Twenty-nine screens now, and eight of them are recent.** `events` was
/// excluded because it could not quiesce rather than because it failed;
/// `insights` shipped unaudited; `dashboardDetail` is the first screen here that
/// is not a list; `onboarding` is the first that demo mode cannot reach at all;
/// `experimentResults` is the first sheet, reached by a tap because nothing
/// opens it from the launch environment; and `notebooks`, `warehouse` and
/// `notebookDocument` are the three whose demo routes only landed after their
/// fixtures did, so nothing had ever drawn them with data. Each carries its own
/// note below. The `.all` table above is the original sweep and has *not* been
/// re-measured across the eight additions — what was measured is the assertion
/// this file actually makes, which is still zero across all twenty-nine.
///
/// **The audit is a floor, not a description.** Measured while adding
/// `dashboardDetail`: a tile carrying two elements labelled `chart.xyaxis.line` —
/// a raw SF Symbol name, exactly the "label not human-readable" shape
/// `sufficientElementDescription` exists to catch — passed this audit clean, both
/// before and after the fix. Apple's audit does not descend into the container a
/// published `AXChartDescriptor` keeps. Onboarding was the same story: two of its
/// highlight rows spoke `rectangle.stack` and `lock.shield`, and the audit passed.
/// Where the shape of a screen matters, something has to read the rendered tree;
/// that is what the other three files in this target do.
///
/// **One test method per screen, deliberately.** A single method that launched
/// the app once per screen took the test runner down partway through with
/// "Restarting after unexpected exit, crash, or test timeout" — repeatably, on
/// different screens each time, so it is the length of the sequence rather than
/// any one screen. Measured: six consecutive launches of the same screen inside
/// one method are fine, twenty-one launches across screens are not. A method per
/// screen keeps each one to a single launch, and gives the failure a screen's
/// name instead of a loop index.
final class AccessibilityAuditTests: XCTestCase {

    /// The two types measured at zero across the sweep.
    private static let asserted: XCUIAccessibilityAuditType = [
        .sufficientElementDescription,
        .trait,
    ]

    // The second argument is the screen's own navigation title, and it is load
    // bearing — see `audit(_:titled:)`.
    func testDashboards() { audit("dashboards", titled: "Dashboards") }
    func testSessions() { audit("sessions", titled: "Sessions") }
    func testFlags() { audit("flags", titled: "Flags") }
    func testSearch() { audit("search", titled: "Search") }
    func testErrorTracking() { audit("errorTracking", titled: "Errors") }
    func testSessionSummaries() { audit("sessionSummaries", titled: "Summaries") }
    func testTracing() { audit("tracing", titled: "Tracing") }
    func testLogs() { audit("logs", titled: "Logs") }
    func testIngestion() { audit("ingestion", titled: "Ingestion") }
    func testHealth() { audit("health", titled: "Health") }
    func testInbox() { audit("inbox", titled: "Inbox") }
    func testSignals() { audit("signals", titled: "Signals") }
    func testSupport() { audit("support", titled: "Support") }
    func testPeople() { audit("people", titled: "People") }

    /// Both copies of the regular-width person row must speak the identity facts
    /// that distinguish one person from another, not only name and status.
    @MainActor
    func testPeopleRowsSpeakDistinctIdentityAndFirstSeen() throws {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            deviceName.localizedCaseInsensitiveContains("iPad"),
            "The list-and-overview row parity contract is measured at regular width."
        )

        let app = DemoLaunch.launch(tab: "people")
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["People"]))

        let rows = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sable Okafor")
        )
        XCTAssertTrue(
            DemoLaunch.wait(until: { rows.count >= 2 }),
            "Regular width did not render both the directory and overview copies of the first person."
        )
        for row in rows.allElementsBoundByIndex {
            XCTAssertTrue(row.label.contains("person:sable:primary"), row.label)
            XCTAssertTrue(row.label.contains("3 distinct IDs"), row.label)
            XCTAssertTrue(row.label.contains("First seen Jan 8, 2026"), row.label)
        }
    }
    func testGroups() { audit("groups", titled: "Groups") }
    func testWebAnalytics() { audit("webAnalytics", titled: "Web") }
    func testSQL() { audit("sql", titled: "SQL") }
    func testTaxonomy() { audit("taxonomy", titled: "Taxonomy") }
    /// Audits the populated authored-demo list. An empty fixture would exercise
    /// only `EmptyStateView`, leaving the product rows outside this audit. See
    /// `testExperimentResults`.
    func testExperiments() { audit("experiments", titled: "Experiments") }
    func testSurveys() { audit("surveys", titled: "Surveys") }
    func testSettings() { audit("settings", titled: "Settings") }

    /// Excluded from this sweep until the feed learned to stop.
    ///
    /// The screen audited clean; what it could not do was quiesce. Its
    /// infinite-scroll footer drew a `ProgressView` whenever `reachedEnd` was
    /// false, and in demo mode that never flipped — the HogQL fixture answers
    /// every request with the same five rows and carries no `uuid` column, so
    /// `EventFeedPager` had no resume point to move, widened its window to the
    /// last rung, and never exhausted. The footer's `.task` fires once, so the
    /// spinner outlived the only request that justified it and animated forever.
    /// XCUITest waits for quiescence on every launch and every query: measured,
    /// the third consecutive launch on this tab ended the run rather than
    /// failing an assertion.
    ///
    /// Two changes let it back in. `EventFeedPager` now treats a page that hands
    /// back rows without moving its cursor as the end of the feed rather than a
    /// thin window, and the footer shows a spinner only while a request is
    /// actually in flight.
    func testEvents() { audit("events", titled: "Events") }

    /// The saved-insight library shipped without an on-screen audit, because the
    /// author who wrote it could not drive the running app.
    func testInsights() { audit("insights", titled: "Insights") }

    /// The two screens whose demo fixtures shipped before their routes did, so
    /// until now neither had ever been drawn with data by anything.
    ///
    /// Both were `EmptyStateView` or a load failure in demo mode — Notebooks
    /// because `/notebooks/` was unrouted entirely, Warehouse because its views
    /// section was. Auditing them before the routes existed would have measured
    /// an empty state and reported clean about a screen that had never rendered
    /// a row, which is exactly what `testExperiments` above records having done.
    ///
    /// Both wait for named rows before auditing, the way `testExperimentResults`
    /// does and for the same reason: this audit passes clean on an empty state,
    /// so a method that only waited for the navigation bar would keep passing if
    /// the route were dropped again and report it as a screen with no findings.
    /// Warehouse waits on one row from each of its three independent collections;
    /// a source, table or saved-view route can therefore no longer disappear
    /// while this audit reports a complete screen.
    func testNotebooks() {
        auditList(
            "notebooks",
            titled: "Notebooks",
            rows: [(
                "Orbit field log",
                "The notebooks list drew no row for the rich demo notebook. Check that "
                    + "DemoTransport still routes /notebooks/ to notebooks_list."
            )]
        )
    }

    func testWarehouse() {
        auditList(
            "warehouse",
            titled: "Warehouse",
            rows: [
                (
                    "S3, Completed",
                    "The warehouse drew no source row. Check that DemoTransport still routes "
                        + "/external_data_sources/."
                ),
                (
                    "demo_accounts, imported table",
                    "The warehouse drew no S3 table row. Check that DemoTransport still routes "
                        + "/warehouse_tables/."
                ),
                (
                    "example_pull_requests, imported table",
                    "The warehouse drew no Github table row. Check that DemoTransport still routes "
                        + "/warehouse_tables/."
                ),
                (
                    "example_meteor_delivery_failures",
                    "The warehouse drew no failing saved-query row. Check that DemoTransport "
                        + "still routes /warehouse_saved_queries/."
                ),
            ],
            forbiddenPrefixes: ["Couldn't load sources.", "Couldn't load tables."]
        )
    }

    /// The one screen in this file that demo mode cannot reach.
    ///
    /// Every other case launches with `-GetHogDemo`, and demo mode hands
    /// `AppModel` an `InMemoryTokenStore` already holding a credential — so
    /// `bootstrap()` finds one, `phase` goes straight to `.ready`, and the app is
    /// past onboarding before the first frame. That is why the screen every user
    /// sees first had never been audited at all: its hero was an unlabelled
    /// `Image(systemName: "chart.xyaxis.line")` and two of its three highlight
    /// rows published their glyph's name, so a raw SF Symbol name was the first
    /// thing VoiceOver said on first launch.
    ///
    /// This case did not catch that either — it passed before the fix, the same
    /// way `dashboardDetail` did. What it catches is everything else, and what
    /// pins the symbols is `OnboardingAccessibilityTests`.
    ///
    /// So this one launches plain: no demo argument, no `GETHOG_API_KEY`, and
    /// therefore a real `KeychainTokenStore` with nothing in it. No request is
    /// made — the welcome step asks for nothing until a key is typed — so this
    /// still spends nothing from the organisation's rate-limit budget.
    ///
    /// It waits on "Get started" rather than a navigation title, and that wait is
    /// the guard as much as the sync: if this simulator *does* hold a credential
    /// from some earlier session, the app comes up on Dashboards and the wait
    /// fails, rather than the audit quietly measuring a screen that is not the
    /// one under test.
    func testOnboarding() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Get started"]),
            "Onboarding's welcome step never appeared. If this simulator holds a "
                + "stored credential, the app launched past it and there is nothing to audit."
        )
        assertAuditPasses(on: app, named: "onboarding")
    }

    /// The only screen here that is not a list, and the reason it is here.
    ///
    /// Every other case audits a collection; a dashboard's *tiles* were reachable
    /// by no test at all, and that gap is where a defect sat. `CardHeader` marked
    /// its symbol `.accessibilityHidden(true)` and the tile published it anyway,
    /// so two elements in this grid were labelled `chart.xyaxis.line`.
    ///
    /// The audit alone did not catch that one, and the honest record of this
    /// case is that it passed before the fix as well as after: a tile's chart
    /// publishes an `AXChartDescriptor`, which keeps the button's label subtree
    /// a container, and Apple's audit does not descend into it. So the symbol
    /// leak is pinned next door in `DashboardTileAccessibilityTests`, which
    /// reads the rendered tree directly. This case is the floor under everything
    /// else the grid may grow — which is more than it had, which was nothing.
    func testDashboardDetail() {
        let app = DemoLaunch.launch(openURL: "gethog://dashboard/\(DemoLaunch.dashboardID)")
        // The tile, not just the bar. A dashboard draws its navigation title
        // before it has any tiles under it, and an audit of the empty grid would
        // pass without measuring the thing this test is here for.
        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", DemoLaunch.firstTileTitle)
            ).firstMatch),
            "The dashboard never drew a tile, so there was nothing of it to audit."
        )
        assertAuditPasses(on: app, named: "dashboardDetail")
    }

    /// The experiment results sheet, which had never been on screen in a test.
    ///
    /// It is the second-largest readout in the app — verdict card, exposure
    /// split, a section per metric, running-time progress, variants — and every
    /// one of those was unauditable when demo mode had no route and the list had
    /// no deterministic row to open.
    /// A sheet that cannot be reached is a sheet no audit descends into, and
    /// this one shipped that way.
    ///
    /// Reached by tapping rather than by `GETHOG_TAB`, because there is no
    /// launch variable for it — the sheet is presented by `RootView` from
    /// `OpenDetails`, and nothing sets that from the environment. The wait is on
    /// the sheet's own Done button, which exists only once the presentation has
    /// happened, so a tap that missed fails here rather than silently auditing
    /// the list a second time.
    ///
    /// The running experiment specifically: it is the one whose fixtures carry
    /// metrics, so it is the only row that draws the whole sheet rather than the
    /// draft's single "Not started" card.
    func testExperimentResults() {
        let app = DemoLaunch.launch(tab: "experiments")
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars["Experiments"]),
            "Experiments never showed its own navigation bar."
        )
        // Matched on the row's own accessibility label, which leads with the
        // experiment's name and then states its status and flag.
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Example cache strategy trial")
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: row),
            "The experiments list drew no row for the running experiment, so there was "
                + "nothing to open. Check that DemoTransport still routes /experiments/."
        )
        row.tap()
        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Done"]),
            "The experiment detail sheet never appeared, so the audit would have "
                + "measured the list again rather than the sheet."
        )
        assertAuditPasses(on: app, named: "experimentResults")
    }

    /// Launches one screen and audits exactly what it renders.
    ///
    /// Reached by `GETHOG_TAB` rather than by tapping, so no screen depends on
    /// another having been visited first and a failure names one screen only.
    ///
    /// Waiting for the screen's *own* navigation title, rather than for any
    /// navigation bar, is what makes the result belong to the screen under test.
    /// `GETHOG_TAB` is applied in `RootView.onAppear`, so the app draws the
    /// restored tab first and switches a beat later — and an audit run inside
    /// that beat sees the previous tab. Measured twice before this wait existed:
    /// Taxonomy and Events each failed `sufficientElementDescription` on a
    /// `chart.xyaxis.line` image, which is a *dashboard tile's* glyph and belongs
    /// to neither screen. Intermittent, and it would have been read as a defect
    /// on whichever screen happened to be named.
    private func audit(
        _ screen: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = DemoLaunch.launch(tab: screen, file: file, line: line)
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars[title]),
            "'\(screen)' never showed its own navigation bar, so there was nothing of it to audit.",
            file: file,
            line: line
        )
        assertAuditPasses(on: app, named: screen, file: file, line: line)
    }

    /// The notebook document itself, which is the largest thing this app renders
    /// from a payload rather than from a model — a ProseMirror tree walked into
    /// headings, lists, task items, quotes, code, and nine kinds of embedded
    /// block — and which had never been on screen in a test.
    ///
    /// Same reason as `testExperimentResults`: the authored demo route must
    /// provide rows so a notebook can be opened and every renderer in
    /// `NotebookEmbedViews` is included in the audit.
    ///
    /// The wait is on a heading from the **body**, not on the navigation bar.
    /// The bar carries the title the *list row* already had, so it appears
    /// whether or not the detail request ever answered — waiting on it would
    /// audit a screen showing "Couldn't load this notebook" and report clean.
    func testNotebookDocument() {
        let app = DemoLaunch.launch(tab: "notebooks")
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Orbit field log")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: row), "The notebooks list drew no row to open.")
        row.tap()

        let paragraph = "Observatory Lab reviewed a fictional orbit signal and recorded the follow-up."
            + "Observatory Lab reviewed a fictional orbit signal and recorded the follow-up."
            + "-fixture-7031"
        let paragraphText = app.staticTexts.matching(
            NSPredicate(format: "label == %@", paragraph)
        ).firstMatch
        XCTAssertTrue(
            DemoLaunch.wait(for: paragraphText),
            "The notebook body never drew its first combined paragraph, so either "
                + "/notebooks/synthetic-id-0050/ did not route or its content tree did not walk."
        )

        // The embedded chart, matched on the funnel's exact summary rather than on
        // the block's title. The title is drawn by `CardHeader` whatever the
        // fetch returned, so it is equally true of a block showing "Run it" or
        // an error; this string only exists once the fictional four-step Harbor
        // funnel in `insights_list.json` has been built.
        //
        // That is the assertion behind the `short_id` filter. The block names
        // `example-constellation-journey`; serving any other synthetic insight would
        // produce a different chart summary even though the block title renders.
        //
        // Read off the rendered tree rather than guessed: the individual step
        // rows are inside the container the chart's accessibility publishes, and
        // this is the label that container carries.
        let funnelSummary = "Funnel with 4 steps, 0% overall conversion"
        let funnel = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", funnelSummary)
        ).firstMatch
        // This embed is the penultimate authored block. Lists build rows lazily,
        // so an exact rendered assertion also has to bring that row into the tree.
        for _ in 0..<30 {
            if funnel.exists { break }
            app.swipeUp(velocity: .slow)
            DemoLaunch.pause(0.25)
        }
        XCTAssertTrue(
            DemoLaunch.wait(for: funnel, timeout: 5),
            "The embedded insight drew no four-step Harbor funnel. Either "
                + "/insights/?short_id=example-constellation-journey "
                + "stopped being filtered to that insight, or the row it answers with "
                + "lost its stored result."
        )
        assertAuditPasses(on: app, named: "notebookDocument")
    }

    /// `audit(_:titled:)` plus one named row, for a screen whose whole point is
    /// that its list has rows in it.
    ///
    /// The distinction matters because of what this audit does **not** do: it
    /// passes on an `EmptyStateView`, which is how `testExperiments` spent its
    /// early life reporting clean about a product surface it had never drawn a
    /// row of. Waiting for a row the demo fixtures are known to contain turns a
    /// dropped route into a named failure instead of a silent pass.
    private func auditList(
        _ screen: String,
        titled title: String,
        rows: [(prefix: String, missing: String)],
        forbiddenPrefixes: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = DemoLaunch.launch(tab: screen, file: file, line: line)
        XCTAssertTrue(
            DemoLaunch.wait(for: app.navigationBars[title]),
            "'\(screen)' never showed its own navigation bar, so there was nothing of it to audit.",
            file: file,
            line: line
        )
        // Rows combine their children, so each label opens with the object's
        // own name. Query every element type because read-only source rows are
        // not buttons while table and saved-view rows navigate.
        for expected in rows {
            let row = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", expected.prefix)
            ).firstMatch
            // `List` builds rows lazily. Bring a later collection into the tree
            // before treating its absence as a dropped route.
            for _ in 0..<30 {
                if row.exists { break }
                app.swipeUp(velocity: .slow)
                DemoLaunch.pause(0.25)
            }
            XCTAssertTrue(
                DemoLaunch.wait(for: row, timeout: 5),
                expected.missing,
                file: file,
                line: line
            )
        }
        for prefix in forbiddenPrefixes {
            let failure = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", prefix)
            ).firstMatch
            XCTAssertFalse(
                failure.exists,
                "'\(screen)' rendered its demo fixture as a partial load: \(prefix)",
                file: file,
                line: line
            )
        }
        assertAuditPasses(on: app, named: screen, file: file, line: line)
    }

    /// The audit itself, split from `audit(_:titled:)` so a screen reached by
    /// deep link rather than by tab can wait for its own thing and still be
    /// measured identically.
    private func assertAuditPasses(
        on app: XCUIApplication,
        named screen: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        DemoLaunch.settle(app)
        do {
            // Each issue is recorded as its own failure with the offending
            // element attached, so one screen can report several at once.
            try app.performAccessibilityAudit(for: Self.asserted)
        } catch {
            XCTFail("Audit could not run on \(screen): \(error)", file: file, line: line)
        }
    }
}
