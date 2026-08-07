import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch model")
@MainActor
struct WatchModelTests {

    @Test("a refresh reduces the pinned dashboard's tiles to metrics")
    func refreshReducesDashboardTiles() async {
        let store = WatchFixtures.tempStore()
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: store
        )

        await model.refresh()

        #expect(model.phase == .ready)
        #expect(model.snapshot?.metrics.count == 2)
        let first = try? #require(model.snapshot?.metrics.first)
        #expect(first?.id == "501")
        #expect(first?.value == 3)
        #expect(first?.previous == 2)
        #expect(first?.sparkline == [1, 2, 3])
        // Only a trends tile has a time axis, so only it gets a render model.
        #expect(model.headlineRender != nil)
        #expect(model.snapshot?.metric(id: "502")?.value == 393)
    }

    @Test("a refresh writes the snapshot the widgets read")
    func refreshWritesSnapshotToStore() async throws {
        let store = WatchFixtures.tempStore()
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: store
        )

        await model.refresh()

        let written = try #require(store.loadOrNil())
        #expect(written.projectID == 1001)
        #expect(written.projectName == "Synthetic Analytics")
        #expect(written.capturedAt == WatchFixtures.now)
        #expect(written.metrics.count == 2)
    }

    @Test("the headline honours the chosen metric id")
    func headlineHonorsChosenID() async {
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: WatchFixtures.tempStore(),
            headline: "502"
        )

        await model.refresh()

        #expect(model.headlineMetric?.id == "502")
        #expect(model.headlineMetric?.value == 393)
        // A bold-number tile has no dated series, so there is no chart to draw.
        #expect(model.headlineRender == nil)
    }

    @Test("a headline id the board no longer holds falls back to the first metric")
    func headlineFallsBackToFirstMetric() async {
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: WatchFixtures.tempStore(),
            headline: "does-not-exist"
        )

        await model.refresh()

        #expect(model.headlineMetric?.id == "501")
    }

    @Test("an offline refresh keeps the snapshot it already had")
    func offlineRefreshPreservesPreviousSnapshot() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(capturedAt: WatchFixtures.now.addingTimeInterval(-7200))
        try store.write(seeded)
        let model = WatchFixtures.model(transport: OfflineTransport(), store: store)

        await model.refresh(force: true)

        // Stale numbers with an honest age beat a blank wrist.
        #expect(model.phase == .ready)
        #expect(store.loadOrNil() == seeded)
        #expect(model.snapshot == seeded)
    }

    @Test("an offline refresh with nothing to fall back on says so")
    func offlineRefreshWithNoSnapshotFails() async {
        let model = WatchFixtures.model(
            transport: OfflineTransport(), store: WatchFixtures.tempStore()
        )

        await model.refresh()

        #expect(model.phase == .failed("PostHog couldn't be reached."))
    }

    @Test("a refresh spends exactly five requests, each within its budget")
    func refreshSpendsExactlyFiveRequests() async throws {
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchFixtures.model(transport: transport, store: WatchFixtures.tempStore())

        await model.refresh()

        let budget = QueryBudget.wrist
        let paths = await transport.requestedPaths()
        let bodies = await transport.requestBodies()
        #expect(paths.count == 5)
        // Every size and every range is the wrist budget's, not a literal
        // beside it: these assertions are written against `QueryBudget.wrist`
        // on purpose, so a page size that drifts away from the kit's value
        // fails here rather than quietly costing five times the rows.
        #expect(paths.contains {
            $0.contains("/dashboards/?") && $0.contains("limit=\(budget.pageSize)")
        })
        #expect(paths.contains {
            $0.contains("/dashboards/9001/") && $0.contains("refresh=force_cache")
        })
        #expect(paths.contains {
            $0.contains("/feature_flags/?") && $0.contains("limit=\(budget.pageSize)")
        })

        let pulse = try #require(bodies.first { $0.contains("ErrorTrackingQuery") })
        #expect(pulse.contains(budget.dateFrom))
        #expect(pulse.contains("occurrences"))

        let feed = try #require(bodies.first { $0.contains("HogQLQuery") })
        #expect(feed.contains("LIMIT \(budget.pageSize)"))
        // The whole point of the trimmed feed: no per-row JSON extraction.
        #expect(!feed.contains("properties"))
        // The flags page fetches exactly what the shortlist draws.
        #expect(WatchModel.flagShortlistCap == budget.pageSize)
        #expect(WatchActivity.maxLines == budget.pageSize)
    }

    @Test("the budgeted requests are the kit's own, not a second spelling")
    func budgetedEndpointsMatchTheKit() {
        let budget = WatchModel.budget
        #expect(budget == QueryBudget.wrist)
        #expect(
            PostHogAPI.dashboards(projectID: 1001, budget: budget).query
                == PostHogAPI.dashboards(projectID: 1001, limit: budget.pageSize).query
        )
        #expect(
            PostHogAPI.featureFlags(projectID: 1001, budget: budget).query
                == PostHogAPI.featureFlags(projectID: 1001, limit: budget.pageSize).query
        )
        // One day, spelled once: the pulse's string range and the feed's Date
        // floor both come off the same budget.
        #expect(budget.dateFrom == "-\(budget.hours)h")
        #expect(
            budget.since(now: WatchFixtures.now)
                == WatchFixtures.now.addingTimeInterval(-Double(budget.hours) * 3600)
        )
    }

    @Test("flags drop tombstones and never claim a quick toggle")
    func flagsFilterTombstonesAndNeverAllowQuickToggle() async {
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: WatchFixtures.tempStore()
        )

        await model.refresh()

        #expect(model.snapshot?.flags.count == 2)
        #expect(model.snapshot?.flags.allSatisfy { !$0.quickToggleAllowed } == true)
        #expect(model.snapshot?.quickToggleFlags.isEmpty == true)
    }

    @Test("a successful flag write rewrites the model and the stored snapshot")
    func setFlagRewritesSnapshotOnSuccess() async throws {
        let store = WatchFixtures.tempStore()
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
            extra: [
                .init(
                    pathContains: "/feature_flags/2/",
                    body: #"{"id":2,"key":"example-b","active":true}"#
                ),
            ]
        ))
        let model = WatchFixtures.model(transport: transport, store: store)
        await model.refresh()

        let failure = await model.setFlag(id: 2, active: true)

        #expect(failure == nil)
        #expect(model.snapshot?.flag(id: 2)?.active == true)
        #expect(store.loadOrNil()?.flag(id: 2)?.active == true)
        // The untouched flag is untouched.
        #expect(store.loadOrNil()?.flag(id: 1)?.active == true)
    }

    @Test("a fresh snapshot throttles the refresh away, and still has a trend to draw")
    func freshSnapshotThrottlesRefresh() async throws {
        let store = WatchFixtures.tempStore()
        try store.write(
            WatchFixtures.snapshot(capturedAt: WatchFixtures.now.addingTimeInterval(-300))
        )
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchFixtures.model(transport: transport, store: store)

        await model.refresh()

        #expect(await transport.requests.isEmpty)
        #expect(model.phase == .ready)
        // The throttled relaunch is the *common* glance-again path, so what it
        // can draw is what the Metrics page usually looks like. There is no
        // in-memory render — nothing was fetched — and the trend therefore has
        // to come off the persisted snapshot.
        #expect(model.headlineRender == nil)
        let sparkline = try #require(model.headlineMetric?.sparkline)
        #expect(sparkline.count > 1)
        #expect(WatchSparklineMath.fractions(sparkline).count == sparkline.count)
    }

    @Test("a throttled relaunch carries the feed forward instead of claiming no events")
    func throttledRelaunchCarriesTheFeed() async {
        let store = WatchFixtures.tempStore()
        let first = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: store
        )
        await first.refresh()
        #expect(first.activity.count == 3)
        #expect(first.activityCapturedAt == WatchFixtures.now)

        // A second launch inside the throttle window spends no requests. The
        // Activity page must still show what the first launch read.
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let second = WatchFixtures.model(transport: transport, store: store)
        await second.refresh()

        #expect(await transport.requests.isEmpty)
        #expect(second.activity.count == 3)
        #expect(second.activityCapturedAt == WatchFixtures.now)
    }

    @Test("an events query that failed leaves the feed and its age alone")
    func failedEventsQueryKeepsTheCarriedFeed() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = ActivityFeed(
            lines: [ActivityLine(id: "example-row-0001", event: "carried_event", timestamp: nil)],
            capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        try WatchActivity.write(seeded, to: store)
        // Every route but the events query answers.
        let routes = WatchFixtures.fullRefreshRoutes().filter { $0.bodyContains != "HogQLQuery" }
        let model = WatchFixtures.model(transport: RouteTransport(routes: routes), store: store)

        await model.refresh(force: true)

        #expect(model.snapshot?.capturedAt == WatchFixtures.now)
        #expect(model.activity == seeded.lines)
        #expect(model.activityCapturedAt == seeded.capturedAt)
        #expect(WatchActivity.read(from: store) == seeded)
    }

    /// The promise the empty state makes: "Open GetHog on your iPhone to hand
    /// this watch its key." Before `adopt`, doing exactly that changed nothing
    /// until the app was force-quit and relaunched — the credential reached the
    /// keychain and the running model went on saying the same sentence.
    @Test("a hand-off that lands while the app is running resolves the empty state")
    func adoptingAHandoffResolvesNeedsKey() async throws {
        let store = WatchFixtures.tempStore()
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: nil,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            authenticate: { _ in true },
            now: { WatchFixtures.now }
        )
        await model.refresh()
        #expect(model.phase == .needsKey)
        #expect(await transport.requests.isEmpty)

        // The phone's transfer lands: keychain, watch list, defaults.
        let credentials = InMemoryTokenStore()
        let defaults = try #require(UserDefaults(suiteName: "GetHogWatchTests-\(UUID().uuidString)"))
        WatchSessionListener.apply(
            WatchKeyTransfer(
                key: "test-key-0001", region: .usCloud, projectID: 1001,
                projectName: "Synthetic Analytics", headlineMetricID: "502",
                watches: [
                    MetricWatch(
                        id: "example-watch-1", metricID: "502",
                        title: "Example total", condition: .above(40)
                    ),
                ]
            ),
            credentials: credentials, snapshots: store, defaults: defaults, notify: {}
        )

        await model.adopt(
            WatchHandoff.current(
                credentials: credentials, defaults: defaults, snapshots: store
            )
        )

        #expect(model.phase == .ready)
        #expect(model.headlineMetricID == "502")
        #expect(model.headlineMetric?.value == 393)
        #expect(model.snapshot?.projectName == "Synthetic Analytics")
        // Forced, so the hand-off is not swallowed by a snapshot that happens
        // to be fresh — this is a different project's numbers.
        #expect(await transport.requests.count == 5)
        // The new thresholds were evaluated, not the ones the model was born
        // with: 393 is above 40.
        #expect(model.health.rows.count == 1)
        #expect(model.health.firingCount == 1)
    }

    @Test("a hand-off that cleared the credential returns to the empty state")
    func adoptingAnEmptyHandoffReturnsToNeedsKey() async {
        let store = WatchFixtures.tempStore()
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchFixtures.model(transport: transport, store: store)
        await model.refresh()
        #expect(model.phase == .ready)

        await model.adopt(
            WatchHandoff(
                credential: nil, projectName: nil, headlineMetricID: nil,
                watches: [], watchesDegraded: false
            )
        )

        #expect(model.phase == .needsKey)
        // Nothing further was asked for on a credential that no longer exists.
        #expect(await transport.requests.count == 5)
        #expect(model.health == .empty)
    }

    @Test("no credential means no requests and a phase that says why")
    func noCredentialNeedsKey() async {
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: nil,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: WatchFixtures.tempStore(),
            authenticate: { _ in true },
            now: { WatchFixtures.now }
        )

        await model.refresh()

        #expect(model.phase == .needsKey)
        #expect(await transport.requests.isEmpty)
    }

    @Test("a rejected credential keeps the replacement form available")
    func failedPhaseOffersCredentialReplacement() {
        let message = "The synthetic key was rejected."

        #expect(WatchCredentialEntryState(phase: .needsKey) == .missing)
        #expect(WatchCredentialEntryState(phase: .failed(message)) == .replacement(message))
        #expect(WatchCredentialEntryState(phase: .loading) == nil)
        #expect(WatchCredentialEntryState(phase: .ready) == nil)
    }
}
