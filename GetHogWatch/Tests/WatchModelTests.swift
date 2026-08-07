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

        let paths = await transport.requestedPaths()
        let bodies = await transport.requestBodies()
        #expect(paths.count == 5)
        #expect(paths.contains { $0.contains("/dashboards/?") && $0.contains("limit=20") })
        #expect(paths.contains { $0.contains("/dashboards/9001/") && $0.contains("refresh=force_cache") })
        #expect(paths.contains { $0.contains("/feature_flags/?") && $0.contains("limit=50") })

        let pulse = try #require(bodies.first { $0.contains("ErrorTrackingQuery") })
        #expect(pulse.contains("-24h"))
        #expect(pulse.contains("occurrences"))

        let feed = try #require(bodies.first { $0.contains("HogQLQuery") })
        #expect(feed.contains("LIMIT 25"))
        // The whole point of the trimmed feed: no per-row JSON extraction.
        #expect(!feed.contains("properties"))
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

    @Test("a fresh snapshot throttles the refresh away entirely")
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
}
