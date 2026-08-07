import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

/// The gate that lets the demo fire a complication without leaking synthetic
/// thresholds into a real session.
///
/// Two claims are being pinned here and they pull against each other, which is
/// why both are tested rather than one: a **demo** launch must leave
/// `metric-watches.json` where the *widget process* can read it — nothing else
/// can make the firing glyph, the alert card or the Smart Stack promotion
/// visible outside a unit test — and a **live** launch must leave nothing of
/// the sort behind, because a synthetic threshold sitting in the user's own
/// watch list is indistinguishable from one they typed.
@Suite("Watch demo seed")
struct WatchDemoSeedTests {

    /// The demo's own numbers, as the container holds them after a demo
    /// launch: the daily-engagement tile's latest point is 55 and the reach
    /// tile aggregates to 393. Those two values are what make
    /// `seededWatches`'s `above(40)` fire and its `above(1000)` stay quiet.
    private static func demoSnapshot() -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001,
            projectName: WatchDemoMode.projectName,
            metrics: [
                .init(
                    id: "700010", title: "Example daily engagement", value: 55, unit: nil,
                    previous: 45, sparkline: [40, 48, 55], dashboardID: 9001
                ),
                .init(
                    id: "700018", title: "Example App metric 79", value: 393, unit: nil,
                    previous: nil, sparkline: [], dashboardID: 9001
                ),
            ],
            flags: [],
            capturedAt: WatchFixtures.now
        )
    }

    // MARK: The demo launch

    @Test("a demo launch leaves the thresholds where the widget process reads them")
    func demoLaunchSeedsTheContainer() {
        let store = WatchFixtures.tempStore()
        #expect(store.metricWatches().isEmpty)

        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: true)

        #expect(store.metricWatches().map(\.id) == WatchDemoMode.seededWatches.map(\.id))
        #expect(FileManager.default.fileExists(
            atPath: WatchDemoMode.seedMarkerURL(in: store).path
        ))
    }

    @Test("the seeded set actually fires against the demo's own numbers")
    func seededWatchesFireInDemo() {
        // The point of the whole gate. A seeded list that never breached would
        // leave the firing complication exactly as undemonstrable as it was
        // before — the widgets' reason to exist, provable by nothing.
        let store = WatchFixtures.tempStore()
        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: true)

        let rows = WatchComplicationCore.firingRows(
            snapshot: Self.demoSnapshot(), watches: store.metricWatches()
        )
        #expect(rows.map(\.id) == ["demo-watch-engagement"])
        #expect(rows.first?.title == "Example daily engagement")

        // And the surfaces built on it: a health face that says "1 firing"
        // over two watches, and a stack card in its alert mode.
        let health = WatchComplicationCore.healthEntry(
            snapshot: Self.demoSnapshot(), watches: store.metricWatches(),
            date: WatchFixtures.now
        )
        #expect(health.firingCount == 1)
        #expect(health.watchCount == 2)

        let stack = WatchComplicationCore.stackEntry(
            snapshot: Self.demoSnapshot(), watches: store.metricWatches(),
            activity: nil, date: WatchFixtures.now
        )
        #expect(stack.mode == .alert(title: "Example daily engagement", count: 1))

        // …and the coarse relevance the Smart Stack asks for, which is empty
        // whenever nothing fires.
        #expect(WatchComplicationCore.stackRelevanceWindow(
            snapshot: Self.demoSnapshot(), watches: store.metricWatches(),
            now: WatchFixtures.now
        ) != nil)
    }

    @Test("seeding twice is the same as seeding once")
    func seedingIsIdempotent() {
        let store = WatchFixtures.tempStore()
        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: true)
        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: true)
        #expect(store.metricWatches().count == WatchDemoMode.seededWatches.count)
    }

    // MARK: The live launch

    @Test("a live launch takes the demo's thresholds straight back out")
    func liveLaunchDropsWhatTheDemoSeeded() {
        let store = WatchFixtures.tempStore()
        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: true)

        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: false)

        // Not merely ignored — gone. A file left in place would be read by the
        // widget process, which has no idea which launch wrote it.
        #expect(store.metricWatches().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: WatchDemoMode.seedMarkerURL(in: store).path
        ))
        // And the complication then says the honest thing.
        let health = WatchComplicationCore.healthEntry(
            snapshot: Self.demoSnapshot(), watches: store.metricWatches(),
            date: WatchFixtures.now
        )
        #expect(health.watchCount == 0)
        #expect(health.firingRows.isEmpty)
    }

    @Test("a real hand-off's thresholds are never touched by the live clear")
    func handOffWatchesSurviveALiveLaunch() throws {
        // The failure this guards against is the expensive one: deleting the
        // user's own watch list because a demo ran on this watch once.
        let store = WatchFixtures.tempStore()
        let mine = [
            MetricWatch(
                id: "user-watch-1", metricID: "700010", title: "Example daily engagement",
                condition: .above(10)
            ),
        ]
        try store.writeMetricWatches(mine)

        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: false)

        #expect(store.metricWatches().map(\.id) == ["user-watch-1"])
    }

    @Test("a hand-off that landed after a demo wins, and only the stale marker goes")
    func handOffAfterADemoIsNotMistakenForSeed() throws {
        let store = WatchFixtures.tempStore()
        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: true)
        // The phone hands over while the marker is still there.
        let mine = [
            MetricWatch(
                id: "user-watch-1", metricID: "700010", title: "Example daily engagement",
                condition: .above(10)
            ),
        ]
        try store.writeMetricWatches(mine)

        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: false)

        #expect(store.metricWatches().map(\.id) == ["user-watch-1"])
        #expect(!FileManager.default.fileExists(
            atPath: WatchDemoMode.seedMarkerURL(in: store).path
        ))
    }

    @Test("a live launch with nothing seeded and nothing stored does nothing at all")
    func liveClearOnAnEmptyContainerIsANoOp() {
        let store = WatchFixtures.tempStore()
        WatchDemoMode.reconcileSeededWatches(in: store, demoEnabled: false)
        #expect(store.metricWatches().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: WatchDemoMode.seedMarkerURL(in: store).path
        ))
    }

    @Test("every seeded value is obviously invented")
    func seededValuesAreSynthetic() {
        // The repository's fixture-privacy gate scans this file and the one it
        // describes; this is the same claim asserted where a reader can see it.
        for watch in WatchDemoMode.seededWatches {
            #expect(watch.id.hasPrefix("demo-watch-"))
            #expect(watch.title.hasPrefix("Example "))
        }
    }
}
