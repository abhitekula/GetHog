import Foundation
import GetHogKit
import GetHogUI
import Testing
import WidgetKit

// Exercises GetHogWidgets/WidgetCache.swift, which project.yml compiles into
// this bundle (the extension is an appex, not a framework — there is nothing to
// import). Every suite here is pure arithmetic over injected dates and flags:
// no store construction, no App Group, no file I/O, so the answers are
// identical on a signed machine and on a teamless clone.

@Suite("Widget refresh cadence")
struct WidgetRefreshTests {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("a timeline carries an hour of entries fifteen minutes apart")
    func entrySpacing() {
        let dates = WidgetRefresh.entryDates(from: start)
        #expect(dates.count == 4)
        #expect(dates.first == start)
        let gaps = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }
        #expect(gaps.allSatisfy { $0 == WidgetRefresh.step })
    }

    @Test("the provider is asked back exactly at the horizon, never inside it")
    func reloadAtHorizon() {
        // `.after(horizon)`, not `.atEnd`: entries already in the past under
        // `.atEnd` become a reload loop that burns the day's budget. The date is
        // the testable half of that decision.
        #expect(WidgetRefresh.nextReload(from: start) == start.addingTimeInterval(WidgetRefresh.horizon))
        #expect(WidgetRefresh.horizon == 60 * 60)
        #expect(WidgetRefresh.step == 15 * 60)
    }

    @Test("timeline entries carry the moving dates, in order")
    func timelineDates() {
        struct Entry: TimelineEntry { let date: Date }
        let timeline = WidgetRefresh.timeline(from: start) { Entry(date: $0) }
        #expect(timeline.entries.map(\.date) == WidgetRefresh.entryDates(from: start))
    }
}

@Suite("Widget freshness")
struct WidgetFreshnessTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("never-synced is stale and says so in both registers")
    func neverSynced() {
        let freshness = WidgetFreshness(capturedAt: nil, now: now)
        #expect(freshness.isStale)
        #expect(freshness.shortLabel == "never")
        #expect(freshness.spokenLabel == "not synced yet")
    }

    @Test("staleness turns exactly past the snapshot's own tolerance")
    func staleBoundary() {
        let fresh = WidgetFreshness(
            capturedAt: now.addingTimeInterval(-SharedSnapshot.defaultStaleTolerance + 60), now: now
        )
        let stale = WidgetFreshness(
            capturedAt: now.addingTimeInterval(-SharedSnapshot.defaultStaleTolerance - 60), now: now
        )
        #expect(!fresh.isStale)
        #expect(stale.isStale)
    }

    @Test("clock drift cannot produce a future age")
    func clampedAge() {
        let freshness = WidgetFreshness(capturedAt: now.addingTimeInterval(300), now: now)
        #expect(freshness.age == 0)
        #expect(freshness.shortLabel == "now")
    }

    @Test("the short label buckets: now, minutes, hours, days")
    func shortLabels() {
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(-30), now: now).shortLabel == "now")
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(-20 * 60), now: now).shortLabel == "20m")
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(-3 * 3_600), now: now).shortLabel == "3h")
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(-2 * 86_400), now: now).shortLabel == "2d")
    }

    @Test("VoiceOver hears words, not abbreviations")
    func spokenLabels() {
        #expect(
            WidgetFreshness(capturedAt: now.addingTimeInterval(-20 * 60), now: now)
                .spokenLabel == "updated 20 minutes ago"
        )
        #expect(
            WidgetFreshness(capturedAt: now.addingTimeInterval(-3 * 3_600), now: now)
                .spokenLabel == "updated 3 hours ago"
        )
    }
}

@Suite("Widget empty-state words")
struct WidgetNoDataMessageTests {

    @Test("a shared container asks the app to sync")
    func sharedContainer() {
        #expect(WidgetCache.noDataMessage(sharedContainer: true) == "Open GetHog to sync")
    }

    @Test("an unshared container refuses to promise that syncing helps")
    func unsharedContainer() {
        // The macOS branch: a teamless Debug build has no App Group, the app's
        // writes land in a different private directory, and words that said
        // "sync" would send the user to do something that cannot fill the
        // widget. On iOS this function never takes the branch.
        let message = WidgetCache.noDataMessage(sharedContainer: false)
        #expect(message.contains("connect"))
        #expect(!message.contains("sync"))
    }
}
