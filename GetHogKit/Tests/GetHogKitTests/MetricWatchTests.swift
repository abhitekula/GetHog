import Foundation
import Testing

@testable import GetHogKit

/// The evaluator is a pure function of a snapshot, the user's watches and the
/// breach set carried over from the previous wake, so none of this involves
/// `UNUserNotificationCenter`, `BGTaskScheduler`, a network, or a clock.
@Suite("Metric watches")
struct MetricWatchTests {

    private func snapshot(_ metrics: [SharedSnapshot.Metric]) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1_001,
            projectName: "Default project",
            metrics: metrics,
            flags: [],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func metric(
        id: String = "42",
        title: String = "Weekly active users",
        value: Double,
        previous: Double? = nil
    ) -> SharedSnapshot.Metric {
        // A watch fires on the value; where the metric is drawn is not its business.
        .init(id: id, title: title, value: value, unit: nil, previous: previous, sparkline: [],
              dashboardID: nil)
    }

    private func watch(
        id: String = "w1",
        metricID: String = "42",
        title: String = "Weekly active users",
        condition: MetricWatch.Condition,
        isEnabled: Bool = true
    ) -> MetricWatch {
        MetricWatch(id: id, metricID: metricID, title: title, condition: condition, isEnabled: isEnabled)
    }

    // MARK: - Crossing

    @Test("fires when a metric crosses into breach")
    func firesOnCrossing() throws {
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]),
            watches: [watch(condition: .above(1000))],
            breaching: []
        )

        #expect(result.alerts.count == 1)
        #expect(result.alerts.first?.watchID == "w1")
        #expect(result.breaching == ["w1"])
    }

    @Test("does not fire again while the metric stays in breach")
    func doesNotRepeatWhileBreaching() {
        // The single most important rule here. A `BGAppRefreshTask` wakes roughly
        // every two hours; a watch that fires on every wake it finds a bad number
        // would notify about one incident a dozen times a day until the user
        // deletes the watch or the app.
        let watches = [watch(condition: .above(1000))]

        let first = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]), watches: watches, breaching: []
        )
        let second = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1500)]), watches: watches, breaching: first.breaching
        )

        #expect(second.alerts.isEmpty)
        // Still in breach, so the state has to survive to the next wake.
        #expect(second.breaching == ["w1"])
    }

    @Test("re-arms once the metric recovers, and fires again on the next crossing")
    func reArmsAfterRecovery() {
        let watches = [watch(condition: .above(1000))]

        let breached = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]), watches: watches, breaching: []
        )
        let recovered = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 900)]), watches: watches, breaching: breached.breaching
        )
        let again = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1100)]), watches: watches, breaching: recovered.breaching
        )

        // Recovery is silent — the user asked to be told when it goes bad, not
        // when it comes back — but it must clear the latch.
        #expect(recovered.alerts.isEmpty)
        #expect(recovered.breaching.isEmpty)
        #expect(again.alerts.count == 1)
        #expect(again.breaching == ["w1"])
    }

    @Test("below latches and re-arms symmetrically")
    func belowIsSymmetric() {
        let watches = [watch(condition: .below(100))]

        let breached = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 42)]), watches: watches, breaching: []
        )
        let still = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 10)]), watches: watches, breaching: breached.breaching
        )
        let recovered = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 150)]), watches: watches, breaching: still.breaching
        )

        #expect(breached.alerts.count == 1)
        #expect(still.alerts.isEmpty)
        #expect(recovered.alerts.isEmpty)
        #expect(recovered.breaching.isEmpty)
    }

    @Test("a value exactly on the threshold is not a breach")
    func thresholdIsExclusive() {
        // "Above 1000" is what the user typed, and 1000 is not above 1000. An
        // inclusive comparison makes a round threshold fire on the round number
        // itself, which reads as a bug even when it is a documented choice.
        let above = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1000)]),
            watches: [watch(condition: .above(1000))],
            breaching: []
        )
        let below = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 100)]),
            watches: [watch(condition: .below(100))],
            breaching: []
        )

        #expect(above.alerts.isEmpty)
        #expect(below.alerts.isEmpty)
    }

    // MARK: - Percent change

    @Test("percent change is measured against the previous period, in either direction")
    func percentChangeUsesPrevious() {
        let watches = [watch(condition: .changesByPercent(10))]

        let quiet = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 105, previous: 100)]), watches: watches, breaching: []
        )
        let jumped = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 120, previous: 100)]), watches: watches, breaching: []
        )
        // The condition is a magnitude, so a collapse counts as much as a spike.
        let collapsed = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 80, previous: 100)]), watches: watches, breaching: []
        )

        #expect(quiet.alerts.isEmpty)
        #expect(quiet.breaching.isEmpty)
        #expect(jumped.alerts.count == 1)
        #expect(collapsed.alerts.count == 1)
    }

    @Test("a nil previous value evaluates to nothing at all, not to a 100% change")
    func nilPreviousIsNotZero() {
        // `SharedSnapshot.Metric.previous` documents nil as "not known", which is
        // not "unchanged" and certainly not zero. Half the tiles the app reduces
        // to metrics — big numbers, bar values — carry no comparison at all, so
        // treating nil as a baseline of zero would fire a +100% alert on every
        // one of them at the first wake after the watch was created.
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234, previous: nil)]),
            watches: [watch(condition: .changesByPercent(10))],
            breaching: []
        )

        #expect(result.alerts.isEmpty)
        #expect(result.breaching.isEmpty)
    }

    @Test("an unknown comparison preserves the latch rather than silently re-arming")
    func nilPreviousPreservesBreachState() {
        // A dashboard that stops returning a comparison for one wake must not
        // look like a recovery: re-arming here would double-notify about an
        // incident that never ended.
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234, previous: nil)]),
            watches: [watch(condition: .changesByPercent(10))],
            breaching: ["w1"]
        )

        #expect(result.alerts.isEmpty)
        #expect(result.breaching == ["w1"])
    }

    @Test("a previous value of zero produces no infinite or NaN percentage")
    func zeroBaselineIsNotInfinite() {
        // This codebase has been bitten twice by exactly this shape —
        // `Int(.infinity)` traps in `JSONValue.stringValue` and in
        // `MasonryLayout.columnCount`. Every percentage against zero is
        // infinite, so the percent path refuses to evaluate rather than
        // producing a number that cannot be rendered or compared.
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 5, previous: 0)]),
            watches: [watch(condition: .changesByPercent(10))],
            breaching: []
        )

        #expect(result.alerts.isEmpty)
        #expect(result.breaching.isEmpty)
    }

    @Test("non-finite values and thresholds never reach a notification")
    func nonFiniteValuesAreIgnored() {
        // A malformed tile result decodes to infinity or NaN without complaint.
        // Neither can be compared usefully or formatted into a sentence, so no
        // path may treat one as a breach.
        let infiniteValue = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: .infinity)]),
            watches: [watch(condition: .above(1000))],
            breaching: []
        )
        let notANumber = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: .nan, previous: 100)]),
            watches: [watch(condition: .changesByPercent(10))],
            breaching: []
        )
        let infiniteThreshold = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]),
            watches: [watch(condition: .below(.infinity))],
            breaching: []
        )
        let infinitePrevious = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 100, previous: .infinity)]),
            watches: [watch(condition: .changesByPercent(10))],
            breaching: []
        )

        #expect(infiniteValue.alerts.isEmpty)
        #expect(notANumber.alerts.isEmpty)
        #expect(infiniteThreshold.alerts.isEmpty)
        #expect(infinitePrevious.alerts.isEmpty)
        #expect(infiniteValue.breaching.isEmpty)
        #expect(notANumber.breaching.isEmpty)
        #expect(infiniteThreshold.breaching.isEmpty)
        #expect(infinitePrevious.breaching.isEmpty)
    }

    // MARK: - Watches that must not participate

    @Test("a disabled watch never fires and never touches its own breach state")
    func disabledWatchIsInert() {
        let disabled = watch(condition: .above(1000), isEnabled: false)

        let fresh = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]), watches: [disabled], breaching: []
        )
        // Paused mid-incident: the latch has to survive, or resuming the watch
        // would notify about a number the user already saw and chose to mute.
        let latched = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]), watches: [disabled], breaching: ["w1"]
        )

        #expect(fresh.alerts.isEmpty)
        #expect(fresh.breaching.isEmpty)
        #expect(latched.alerts.isEmpty)
        #expect(latched.breaching == ["w1"])
    }

    @Test("a watch whose metric left the snapshot is preserved, not re-armed")
    func absentMetricPreservesBreachState() {
        // Tiles get removed, dashboards get re-pinned, and a fetch can come back
        // with a partial result. Any of those makes a metric vanish for one wake
        // — and clearing the latch then would fire a second notification about
        // the same unresolved incident the moment it came back.
        let watches = [watch(metricID: "999", condition: .above(1000))]

        let latched = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]), watches: watches, breaching: ["w1"]
        )
        let neverSeen = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]), watches: watches, breaching: []
        )

        #expect(latched.alerts.isEmpty)
        #expect(latched.breaching == ["w1"])
        #expect(neverSeen.alerts.isEmpty)
        #expect(neverSeen.breaching.isEmpty)
    }

    @Test("breach state for a deleted watch is dropped rather than accumulating forever")
    func deletedWatchesAreForgotten() {
        // The set is persisted across launches, so anything not backed by a live
        // watch would sit in the file until the app is deleted.
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]),
            watches: [watch(condition: .above(1000))],
            breaching: ["w1", "deleted-watch"]
        )

        #expect(result.breaching == ["w1"])
    }

    // MARK: - What the notification says

    @Test("the alert names the metric and the value that tripped it")
    func alertBodyIsSpecific() throws {
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 1234)]),
            watches: [watch(condition: .above(1000))],
            breaching: []
        )
        let alert = try #require(result.alerts.first)

        // A notification that says only "a metric crossed its threshold" makes
        // the user open the app to learn what it was about, which is the whole
        // job the notification was supposed to do.
        #expect(alert.title.contains("Weekly active users"))
        #expect(alert.body.contains("Weekly active users"))
        #expect(alert.body.contains("1234"))
        #expect(alert.body.contains("1000"))
        #expect(alert.metricID == "42")
    }

    @Test("the alert uses the metric's current name, not the one saved with the watch")
    func alertFollowsRenamedTiles() throws {
        // The title on a watch is the tile name as it stood when the watch was
        // made. Notifying under a name that no longer appears on the dashboard
        // sends the user looking for something that isn't there.
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(title: "Weekly actives (v2)", value: 1234)]),
            watches: [watch(title: "Weekly active users", condition: .above(1000))],
            breaching: []
        )
        let alert = try #require(result.alerts.first)

        #expect(alert.title.contains("Weekly actives (v2)"))
    }

    @Test("a percent-change alert states the change and the baseline it was measured against")
    func percentAlertBodyExplainsItself() throws {
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([metric(value: 120, previous: 100)]),
            watches: [watch(condition: .changesByPercent(10))],
            breaching: []
        )
        let alert = try #require(result.alerts.first)

        #expect(alert.body.contains("120"))
        #expect(alert.body.contains("100"))
        #expect(alert.body.contains("20"))
    }

    @Test("values are written without a locale's separators or an exponent")
    func valuesFormatAsPlainNumbers() {
        // These strings go into a notification body that the tests compare
        // against, and into a summary line beside the metric on screen. A
        // grouping separator or a `1.234e+03` would make both unreadable.
        #expect(MetricWatch.format(1234) == "1234")
        #expect(MetricWatch.format(41.25) == "41.25")
        #expect(MetricWatch.format(41.2555) == "41.26")
        #expect(MetricWatch.format(-0.5) == "-0.5")
        // Beyond Int64's range the integer shortcut would trap, so it is not
        // taken; the point of the guard is that this returns at all.
        #expect(MetricWatch.format(1e18).isEmpty == false)
        #expect(MetricWatch.format(.infinity).isEmpty == false)
        #expect(MetricWatch.format(.nan).isEmpty == false)
    }

    // MARK: - Ordering and independence

    @Test("watches are evaluated independently and reported in the order they are held")
    func independentWatches() {
        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot([
                metric(id: "42", title: "Weekly active users", value: 1234),
                metric(id: "43", title: "Bounce rate", value: 12),
            ]),
            watches: [
                watch(id: "w1", metricID: "42", condition: .above(1000)),
                watch(id: "w2", metricID: "43", title: "Bounce rate", condition: .below(20)),
                watch(id: "w3", metricID: "43", title: "Bounce rate", condition: .above(90)),
            ],
            breaching: []
        )

        #expect(result.alerts.map(\.watchID) == ["w1", "w2"])
        #expect(result.breaching == ["w1", "w2"])
    }

    // MARK: - Persistence

    @Test("watches and their breach state round-trip through the App Group in separate files")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricWatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SharedSnapshotStore(directory: dir)

        // Nothing configured yet is the ordinary state, not an error.
        #expect(store.metricWatches().isEmpty)
        #expect(store.breachingWatchIDs().isEmpty)

        let watches = [
            watch(condition: .above(1000)),
            watch(id: "w2", metricID: "43", title: "Bounce rate", condition: .below(20), isEnabled: false),
            watch(id: "w3", metricID: "44", title: "Signups", condition: .changesByPercent(25)),
        ]
        try store.writeMetricWatches(watches)
        try store.writeBreachingWatchIDs(["w1"])

        #expect(store.metricWatches() == watches)
        #expect(store.breachingWatchIDs() == ["w1"])
        // Separate files, as with the two pending-write records: rewriting the
        // watch list on every edit must not discard the latch that stops the
        // next wake re-notifying.
        #expect(store.metricWatchesURL.lastPathComponent == "metric-watches.json")
        #expect(store.breachingWatchIDsURL.lastPathComponent == "metric-watch-breaches.json")

        try store.writeMetricWatches([])
        #expect(store.breachingWatchIDs() == ["w1"])
    }

    @Test("a corrupt watch file reads as empty rather than wedging a background wake")
    func corruptStoreDegrades() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricWatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SharedSnapshotStore(directory: dir)

        try Data("{ not json".utf8).write(to: store.metricWatchesURL)
        try Data("{ not json".utf8).write(to: store.breachingWatchIDsURL)

        // A background wake has nowhere to report a decoding failure, and one
        // must not be able to stop the snapshot itself being published.
        #expect(store.metricWatches().isEmpty)
        #expect(store.breachingWatchIDs().isEmpty)
    }
}
