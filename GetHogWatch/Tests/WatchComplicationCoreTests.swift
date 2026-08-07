import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing
import WidgetKit

/// The complications' derivation, run without a watch face.
///
/// This is the whole reason `WatchWidgetCore.swift` sits in the app target: the
/// widget extension is a separate binary this test bundle does not compile, so
/// a rule that lived there would be a rule nobody could check. Nothing here
/// names a SwiftUI type — see `WatchSparklineMath`'s comment for what happens
/// on this platform when a test does.
@Suite("Watch complication core")
struct WatchComplicationCoreTests {

    // MARK: Fixtures

    /// The demo's shape, restated as a snapshot: one tile whose latest value is
    /// 55 and one that aggregates to 393, so `above(40)` fires and `above(1000)`
    /// stays quiet — deterministically, with no clock in it.
    private static func snapshot(
        capturedAt: Date = WatchFixtures.now,
        metrics: [SharedSnapshot.Metric]? = nil
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001,
            projectName: "Synthetic Analytics",
            metrics: metrics ?? [
                .init(
                    id: "700010", title: "Example daily engagement", value: 55, unit: nil,
                    previous: 50, sparkline: [40, 48, 55], dashboardID: 9001
                ),
                .init(
                    id: "700018", title: "Example App metric 79", value: 393, unit: nil,
                    previous: 390, sparkline: [380, 388, 393], dashboardID: 9001
                ),
            ],
            flags: [],
            capturedAt: capturedAt
        )
    }

    private static let watches: [MetricWatch] = [
        MetricWatch(
            id: "demo-watch-engagement",
            metricID: "700010",
            title: "Example daily engagement",
            condition: .above(40)
        ),
        MetricWatch(
            id: "demo-watch-reach",
            metricID: "700018",
            title: "Example App metric 79",
            condition: .above(1000)
        ),
    ]

    // MARK: Ordering

    @Test("the configured metric leads, and the rest keep their order behind it")
    func configuredMetricLeads() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: Self.snapshot(), chosenMetricID: "700018", watches: [],
            date: WatchFixtures.now
        )
        #expect(entry.metrics.map(\.id) == ["700018", "700010"])
        #expect(entry.primary?.id == "700018")
    }

    @Test("a configuration naming a metric the snapshot lost falls back to the first")
    func unknownConfigurationFallsBackToFirst() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: Self.snapshot(), chosenMetricID: "no-such-metric", watches: [],
            date: WatchFixtures.now
        )
        // The same fallback `WatchModel.headlineMetric` makes, so the
        // complication and the app's first page lead with the same number.
        #expect(entry.primary?.id == "700010")
    }

    @Test("no snapshot is not-synced, not an empty project")
    func absentSnapshotIsUnsynced() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: nil, chosenMetricID: nil, watches: [], date: WatchFixtures.now
        )
        #expect(!entry.hasData)
        #expect(!entry.isEmptyProject)
        #expect(entry.capturedAt == nil)
        #expect(entry.freshness.shortLabel == "never")
        #expect(entry.freshness.spokenLabel == "not synced yet")
    }

    @Test("a synced project with no metrics is a different claim from a synced-never one")
    func emptyProjectIsItsOwnState() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: Self.snapshot(metrics: []), chosenMetricID: nil, watches: [],
            date: WatchFixtures.now
        )
        #expect(!entry.hasData)
        #expect(entry.isEmptyProject)
    }

    // MARK: Freshness

    @Test("the age label shrinks to the unit that fits: now, m, h, d")
    func freshnessLabels() {
        let now = WatchFixtures.now
        func label(secondsAgo: TimeInterval) -> String {
            WatchFreshness(capturedAt: now.addingTimeInterval(-secondsAgo), now: now).shortLabel
        }
        #expect(label(secondsAgo: 5) == "now")
        #expect(label(secondsAgo: 12 * 60) == "12m")
        #expect(label(secondsAgo: 3 * 3_600) == "3h")
        #expect(label(secondsAgo: 2 * 86_400) == "2d")
        #expect(WatchFreshness(capturedAt: nil, now: now).shortLabel == "never")
        #expect(
            WatchFreshness(capturedAt: now.addingTimeInterval(-3 * 3_600), now: now).spokenLabel
                == "updated 3 hours ago"
        )
    }

    @Test("staleness flips at the kit's tolerance, not at a number of this file's own")
    func stalenessPinsToTheKit() {
        let now = WatchFixtures.now
        let tolerance = SharedSnapshot.defaultStaleTolerance
        #expect(tolerance == 30 * 60)
        let justInside = WatchFreshness(capturedAt: now.addingTimeInterval(-tolerance), now: now)
        let justOutside = WatchFreshness(
            capturedAt: now.addingTimeInterval(-tolerance - 1), now: now
        )
        #expect(!justInside.isStale)
        #expect(justOutside.isStale)
        // Never synced is stale, never "fresh by default".
        #expect(WatchFreshness(capturedAt: nil, now: now).isStale)
        // A snapshot from the future is clock drift, not extra freshness.
        #expect(WatchFreshness(capturedAt: now.addingTimeInterval(600), now: now).age == 0)
    }

    // MARK: Firing

    @Test("only the watch actually over its line is reported firing")
    func firingDerivationAgreesWithTheEvaluator() {
        let rows = WatchComplicationCore.firingRows(
            snapshot: Self.snapshot(), watches: Self.watches
        )
        #expect(rows.map(\.id) == ["demo-watch-engagement"])
        #expect(rows.first?.title == "Example daily engagement")
    }

    @Test("a disabled watch is neither firing nor counted")
    func disabledWatchesAreIgnored() {
        var disabled = Self.watches
        disabled[0].isEnabled = false
        let entry = WatchComplicationCore.healthEntry(
            snapshot: Self.snapshot(), watches: disabled, date: WatchFixtures.now
        )
        #expect(entry.firingRows.isEmpty)
        #expect(entry.watchCount == 1)
    }

    @Test("a firing watch whose metric has gone keeps the title it was saved with")
    func firingTitleFallsBackToTheSavedTitle() {
        // The metric id the watch names is absent, so nothing fires — that is
        // the evaluator's rule and it is the right one. Renaming the *present*
        // metric is what exercises the title fallback in the other direction.
        let renamed = Self.snapshot(metrics: [
            .init(
                id: "700010", title: "Example engagement, renamed", value: 55, unit: nil,
                previous: 50, sparkline: [], dashboardID: nil
            ),
        ])
        let rows = WatchComplicationCore.firingRows(snapshot: renamed, watches: Self.watches)
        #expect(rows.map(\.title) == ["Example engagement, renamed"])

        // And with no metric at all in the snapshot, the row is not invented.
        let empty = WatchComplicationCore.firingRows(
            snapshot: Self.snapshot(metrics: []), watches: Self.watches
        )
        #expect(empty.isEmpty)
    }

    // MARK: Relevance score

    @Test("a firing watch scores at least the kit's breach band; a quiet one scores nothing")
    func relevanceUsesTheKitsBands() {
        let firing = WatchComplicationCore.score(
            snapshot: Self.snapshot(), watches: Self.watches, now: WatchFixtures.now
        )
        #expect(firing >= 80)

        // No watches: nothing is an explicit request to be told, and neither
        // metric moved more than the kit's 10% floor.
        let quiet = WatchComplicationCore.score(
            snapshot: Self.snapshot(), watches: [], now: WatchFixtures.now
        )
        #expect(quiet == 0)

        #expect(WatchComplicationCore.score(snapshot: nil, watches: Self.watches, now: WatchFixtures.now) == 0)
    }

    @Test("a claim decays to nothing at the kit's horizon rather than ringing forever")
    func relevanceDecaysWithAge() {
        let now = WatchFixtures.now
        let horizon = SnapshotRelevance.decayHorizon
        #expect(horizon == 6 * 60 * 60)
        let old = Self.snapshot(capturedAt: now.addingTimeInterval(-horizon))
        #expect(WatchComplicationCore.score(snapshot: old, watches: Self.watches, now: now) == 0)

        let halfway = Self.snapshot(capturedAt: now.addingTimeInterval(-horizon / 2))
        let partial = WatchComplicationCore.score(
            snapshot: halfway, watches: Self.watches, now: now
        )
        #expect(partial > 0)
        #expect(partial < 80)
    }

    @Test("an entry's relevance expires with a step, so a late provider call cannot keep an alarm")
    func entryRelevanceCarriesAStepDuration() {
        let entry = WatchComplicationCore.healthEntry(
            snapshot: Self.snapshot(), watches: Self.watches, date: WatchFixtures.now
        )
        #expect(entry.relevance?.duration == WatchWidgetRefresh.step)
        #expect(entry.relevance?.score == entry.relevanceScore)
    }

    // MARK: Stack modes

    @Test("a firing watch turns the stack card into an alert naming it")
    func stackAlertsWhenAWatchFires() {
        let entry = WatchComplicationCore.stackEntry(
            snapshot: Self.snapshot(), watches: Self.watches, activity: nil,
            date: WatchFixtures.now
        )
        #expect(entry.mode == .alert(title: "Example daily engagement", count: 1))
    }

    @Test("nothing firing is a glance: the headline number and the newest event")
    func stackIsQuietWithoutABreach() {
        let feed = ActivityFeed(
            lines: [ActivityLine(id: "example-row-0001", event: "example_event_0", timestamp: nil)],
            capturedAt: WatchFixtures.now
        )
        let entry = WatchComplicationCore.stackEntry(
            snapshot: Self.snapshot(), watches: [], activity: feed, date: WatchFixtures.now
        )
        #expect(entry.mode == .quiet(
            metricTitle: "Example daily engagement",
            valueText: "55",
            latestEvent: "example_event_0",
            eventCapturedAt: WatchFixtures.now
        ))
    }

    @Test("no snapshot at all says so rather than drawing an empty glance")
    func stackSaysUnsynced() {
        let entry = WatchComplicationCore.stackEntry(
            snapshot: nil, watches: Self.watches, activity: nil, date: WatchFixtures.now
        )
        #expect(entry.mode == .unsynced)
        #expect(entry.relevanceScore == 0)
    }

    @Test("the event line ages by the feed's own stamp, never the snapshot's")
    func eventLineAgesByTheFeed() {
        let now = WatchFixtures.now
        // A wake whose events query alone failed: the snapshot is minutes old,
        // the feed it kept is hours old. Ageing the line by the snapshot would
        // claim the event had just been re-read.
        let feed = ActivityFeed(
            lines: [ActivityLine(id: "example-row-0001", event: "example_event_0", timestamp: nil)],
            capturedAt: now.addingTimeInterval(-3 * 3_600)
        )
        let entry = WatchComplicationCore.stackEntry(
            snapshot: Self.snapshot(capturedAt: now.addingTimeInterval(-120)),
            watches: [], activity: feed, date: now
        )
        #expect(entry.freshness.shortLabel == "2m")
        #expect(entry.eventFreshness?.shortLabel == "3h")
    }

    @Test("a quiet card with no feed draws no event line to age")
    func noFeedMeansNoEventFreshness() {
        let entry = WatchComplicationCore.stackEntry(
            snapshot: Self.snapshot(), watches: [], activity: nil, date: WatchFixtures.now
        )
        #expect(entry.eventFreshness == nil)
    }

    // MARK: Relevance window

    @Test("the relevance window opens only while something is firing")
    func relevanceWindowNeedsABreach() throws {
        let now = WatchFixtures.now
        #expect(
            WatchComplicationCore.stackRelevanceWindow(
                snapshot: Self.snapshot(), watches: [], now: now
            ) == nil
        )
        #expect(
            WatchComplicationCore.stackRelevanceWindow(
                snapshot: nil, watches: Self.watches, now: now
            ) == nil
        )

        let window = try #require(
            WatchComplicationCore.stackRelevanceWindow(
                snapshot: Self.snapshot(), watches: Self.watches, now: now
            )
        )
        #expect(window.start == now)
        // Expires exactly where the per-entry score would have decayed to zero,
        // so the two relevance APIs cannot disagree.
        #expect(window.end == now.addingTimeInterval(SnapshotRelevance.decayHorizon))
    }

    @Test("a window that would already be over is not offered at all")
    func expiredRelevanceWindowIsNil() {
        let now = WatchFixtures.now
        let stale = Self.snapshot(
            capturedAt: now.addingTimeInterval(-SnapshotRelevance.decayHorizon)
        )
        #expect(
            WatchComplicationCore.stackRelevanceWindow(
                snapshot: stale, watches: Self.watches, now: now
            ) == nil
        )
    }

    // MARK: Timeline

    @Test("one timeline is an hour of quarter-hourly entries, reloading after it")
    func timelineShape() {
        let now = WatchFixtures.now
        let timeline = WatchWidgetRefresh.timeline(from: now) { date in
            WatchComplicationCore.metricEntry(
                snapshot: Self.snapshot(), chosenMetricID: nil, watches: [], date: date
            )
        }
        #expect(timeline.entries.count == 4)
        #expect(timeline.entries.map(\.date) == [0, 900, 1_800, 2_700].map(now.addingTimeInterval))
        // `.after`, never `.atEnd`: `.atEnd` over entries already in the past is
        // a reload loop that spends the day's budget in minutes.
        #expect(timeline.policy == .after(now.addingTimeInterval(3_600)))
        #expect(WatchWidgetRefresh.step == 15 * 60)
        #expect(WatchWidgetRefresh.horizon == 60 * 60)
    }

    // MARK: Numbers

    @Test("a complication-sized number keeps its unit where the unit belongs")
    func numberFormatting() {
        #expect(WatchWidgetNumber.compact(12_480) == "12.5K")
        #expect(WatchWidgetNumber.compact(318) == "318")
        #expect(WatchWidgetNumber.compact(41.2, unit: "%") == "41.2%")
        #expect(WatchWidgetNumber.compact(8_640, unit: "$") == "$8.6K")
        #expect(WatchWidgetNumber.compact(27, unit: "errors") == "27 errors")
    }

    // MARK: Cache

    @Test("the cache reads all three files, and reads nothing when they are absent")
    func cacheReadsTheContainer() throws {
        let store = WatchFixtures.tempStore()
        let cache = WatchWidgetCache(store: store)
        #expect(cache.snapshot() == nil)
        #expect(cache.activity() == nil)
        #expect(cache.watches().isEmpty)

        try store.write(Self.snapshot())
        try WatchActivity.write(WatchWidgetSample.activity, to: store)
        try store.writeMetricWatches(Self.watches)

        #expect(cache.snapshot()?.projectName == "Synthetic Analytics")
        #expect(cache.activity()?.lines.count == 3)
        #expect(cache.watches().map(\.id) == Self.watches.map(\.id))
    }

    // MARK: Sample

    @Test("the gallery sample is synthetic and claims no urgency")
    func sampleIsSyntheticAndSilent() {
        #expect(WatchWidgetSample.snapshot.projectID == 0)
        #expect(WatchWidgetSample.snapshot.projectName == "Your project")
        #expect(WatchWidgetSample.metricEntry().relevanceScore == 0)
        #expect(WatchWidgetSample.healthEntry().relevanceScore == 0)
        #expect(WatchWidgetSample.stackEntry().relevanceScore == 0)
        // The gallery must never show an alarm: a firing sample would teach the
        // user that a red card on this widget means nothing.
        #expect(WatchWidgetSample.healthEntry().firingRows.isEmpty)
        // No flag sample, because no watch complication draws a flag — every
        // flag the wrist writes carries `quickToggleAllowed: false`.
        #expect(WatchWidgetSample.snapshot.flags.isEmpty)
        #expect(WatchWidgetSample.snapshot.quickToggleFlags.isEmpty)
    }

    @Test("no sample identifier could be mistaken for one belonging to somebody")
    func sampleIdentifiersAreObviouslyInvented() {
        #expect(WatchWidgetSample.activity.lines.map(\.id) == ["sample-1", "sample-2", "sample-3"])
        #expect(WatchWidgetSample.activity.lines.map(\.event) == [
            "example signup completed", "example checkout submitted", "example feature used",
        ])
        #expect(WatchWidgetSample.watches.map(\.id) == ["sample-watch-1"])
        // Nothing digits-only and long enough to read as a real tenant id.
        for id in WatchWidgetSample.snapshot.metrics.map(\.id) {
            #expect(id.count < 5)
        }
    }
}
