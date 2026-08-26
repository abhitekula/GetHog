import Foundation
import GetHogKit
import GetHogUI
@testable import GetHogWatch
import Testing
import WidgetKit

/// The complications' derivation, run without a watch face.
@Suite("Watch complication core")
struct WatchComplicationCoreTests {

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
                    previous: 40, sparkline: [40, 48, 55], dashboardID: 9001
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

    @Test("the configured metric leads, and the rest keep their order behind it")
    func configuredMetricLeads() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: Self.snapshot(), chosenMetricID: "700018", date: WatchFixtures.now
        )
        #expect(entry.metrics.map(\.id) == ["700018", "700010"])
        #expect(entry.primary?.id == "700018")
    }

    @Test("a configuration naming a lost metric falls back to the first")
    func unknownConfigurationFallsBackToFirst() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: Self.snapshot(), chosenMetricID: "no-such-metric", date: WatchFixtures.now
        )
        #expect(entry.primary?.id == "700010")
    }

    @Test("no snapshot is unsynced, not an empty project")
    func absentSnapshotIsUnsynced() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: nil, chosenMetricID: nil, date: WatchFixtures.now
        )
        #expect(!entry.hasData)
        #expect(!entry.isEmptyProject)
        #expect(entry.freshness.shortLabel == "never")
        #expect(entry.freshness.spokenLabel == "not synced yet")
    }

    @Test("a synced project with no metrics is its own state")
    func emptyProjectIsItsOwnState() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: Self.snapshot(metrics: []), chosenMetricID: nil, date: WatchFixtures.now
        )
        #expect(!entry.hasData)
        #expect(entry.isEmptyProject)
    }

    @Test("the age label shrinks to the unit that fits")
    func freshnessLabels() {
        let now = WatchFixtures.now
        func label(secondsAgo: TimeInterval) -> String {
            WidgetFreshness(capturedAt: now.addingTimeInterval(-secondsAgo), now: now).shortLabel
        }
        #expect(label(secondsAgo: 5) == "now")
        #expect(label(secondsAgo: 12 * 60) == "12m")
        #expect(label(secondsAgo: 3 * 3_600) == "3h")
        #expect(label(secondsAgo: 2 * 86_400) == "2d")
        #expect(WidgetFreshness(capturedAt: nil, now: now).shortLabel == "never")
    }

    @Test("staleness flips at the shared snapshot tolerance")
    func stalenessPinsToTheKit() {
        let now = WatchFixtures.now
        let tolerance = SharedSnapshot.defaultStaleTolerance
        let justInside = WidgetFreshness(capturedAt: now.addingTimeInterval(-tolerance), now: now)
        let justOutside = WidgetFreshness(
            capturedAt: now.addingTimeInterval(-tolerance - 1), now: now
        )
        #expect(!justInside.isStale)
        #expect(justOutside.isStale)
        #expect(WidgetFreshness(capturedAt: nil, now: now).isStale)
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(600), now: now).age == 0)
    }

    @Test("metric movement determines relevance")
    func relevanceUsesMetricMovement() {
        #expect(WatchComplicationCore.score(
            snapshot: Self.snapshot(), now: WatchFixtures.now
        ) > 0)
        #expect(WatchComplicationCore.score(snapshot: nil, now: WatchFixtures.now) == 0)
    }

    @Test("relevance decays to nothing at the kit horizon")
    func relevanceDecaysWithAge() {
        let now = WatchFixtures.now
        let horizon = SnapshotRelevance.decayHorizon
        let old = Self.snapshot(capturedAt: now.addingTimeInterval(-horizon))
        #expect(WatchComplicationCore.score(snapshot: old, now: now) == 0)

        let halfway = Self.snapshot(capturedAt: now.addingTimeInterval(-horizon / 2))
        let partial = WatchComplicationCore.score(snapshot: halfway, now: now)
        #expect(partial > 0)
    }

    @Test("an entry's relevance expires with one timeline step")
    func entryRelevanceCarriesAStepDuration() {
        let entry = WatchComplicationCore.metricEntry(
            snapshot: Self.snapshot(), chosenMetricID: nil, date: WatchFixtures.now
        )
        #expect(entry.relevance?.duration == WatchWidgetRefresh.step)
        #expect(entry.relevance?.score == entry.relevanceScore)
    }

    @Test("the stack is a glance with the headline and newest event")
    func stackIsAGlance() {
        let feed = ActivityFeed(
            lines: [ActivityLine(id: "example-row-0001", event: "example_event_0", timestamp: nil)],
            capturedAt: WatchFixtures.now
        )
        let entry = WatchComplicationCore.stackEntry(
            snapshot: Self.snapshot(), activity: feed, date: WatchFixtures.now
        )
        #expect(entry.mode == .quiet(
            metricTitle: "Example daily engagement",
            valueText: "55",
            latestEvent: "example_event_0",
            eventCapturedAt: WatchFixtures.now
        ))
    }

    @Test("no snapshot says unsynced")
    func stackSaysUnsynced() {
        let entry = WatchComplicationCore.stackEntry(
            snapshot: nil, activity: nil, date: WatchFixtures.now
        )
        #expect(entry.mode == .unsynced)
        #expect(entry.relevanceScore == 0)
    }

    @Test("the event line ages by the feed's own stamp")
    func eventLineAgesByTheFeed() {
        let now = WatchFixtures.now
        let feed = ActivityFeed(
            lines: [ActivityLine(id: "example-row-0001", event: "example_event_0", timestamp: nil)],
            capturedAt: now.addingTimeInterval(-3 * 3_600)
        )
        let entry = WatchComplicationCore.stackEntry(
            snapshot: Self.snapshot(capturedAt: now.addingTimeInterval(-120)),
            activity: feed,
            date: now
        )
        #expect(entry.freshness.shortLabel == "2m")
        #expect(entry.eventFreshness?.shortLabel == "3h")
    }

    @Test("a card with no feed draws no event freshness")
    func noFeedMeansNoEventFreshness() {
        let entry = WatchComplicationCore.stackEntry(
            snapshot: Self.snapshot(), activity: nil, date: WatchFixtures.now
        )
        #expect(entry.eventFreshness == nil)
    }

    @Test("one timeline is an hour of quarter-hourly entries")
    func timelineShape() {
        let now = WatchFixtures.now
        let timeline = WatchWidgetRefresh.timeline(from: now) { date in
            WatchComplicationCore.metricEntry(
                snapshot: Self.snapshot(), chosenMetricID: nil, date: date
            )
        }
        #expect(timeline.entries.count == 4)
        #expect(timeline.entries.map(\.date) == [0, 900, 1_800, 2_700].map(now.addingTimeInterval))
        #expect(timeline.policy == .after(now.addingTimeInterval(3_600)))
    }

    @Test("a complication-sized number keeps its unit")
    func numberFormatting() {
        #expect(WidgetNumber.compact(12_480) == "12.5K")
        #expect(WidgetNumber.compact(41.2, unit: "%") == "41.2%")
        #expect(WidgetNumber.compact(8_640, unit: "$") == "$8.6K")
        #expect(WidgetNumber.compact(27, unit: "errors") == "27 errors")
    }

    @Test("the cache reads snapshot and activity independently")
    func cacheReadsTheContainer() throws {
        let store = WatchFixtures.tempStore()
        let cache = WatchWidgetCache(store: store)
        #expect(cache.snapshot() == nil)
        #expect(cache.activity() == nil)

        try store.write(Self.snapshot())
        try WatchActivity.write(WatchWidgetSample.activity, to: store)

        #expect(cache.snapshot()?.projectName == "Synthetic Analytics")
        #expect(cache.activity()?.lines.count == 3)
    }

    @Test("the gallery sample is synthetic and claims no urgency")
    func sampleIsSyntheticAndSilent() {
        #expect(WatchWidgetSample.snapshot.projectID == 0)
        #expect(WatchWidgetSample.snapshot.projectName == "Your project")
        #expect(WatchWidgetSample.metricEntry().relevanceScore == 0)
        #expect(WatchWidgetSample.stackEntry().relevanceScore == 0)
        #expect(WatchWidgetSample.snapshot.flags.isEmpty)
    }

    @Test("sample identifiers are obviously invented")
    func sampleIdentifiersAreObviouslyInvented() {
        #expect(WatchWidgetSample.activity.lines.map(\.id) == ["sample-1", "sample-2", "sample-3"])
        for id in WatchWidgetSample.snapshot.metrics.map(\.id) {
            #expect(id.count < 5)
        }
    }
}
