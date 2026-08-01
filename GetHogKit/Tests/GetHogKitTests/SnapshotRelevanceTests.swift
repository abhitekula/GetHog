import Foundation
import Testing

@testable import GetHogKit

/// Smart Stack ranking is opaque from a simulator — there is no way to observe
/// which card iOS rotated up, or why. What *is* observable is the number the
/// widget hands it, so that is what these pin: that it moves with real signal in
/// the App Group file, that it is zero when there is nothing to say, and that the
/// two bands a reader would act on differently cannot be confused for each other.
@Suite("Smart Stack relevance")
struct SnapshotRelevanceTests {

    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        metrics: [SharedSnapshot.Metric] = [],
        ingestion: SharedSnapshot.IngestionDigest? = nil,
        quota: SharedSnapshot.QuotaDigest? = nil
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1_001,
            projectName: "Default project",
            metrics: metrics,
            flags: [],
            ingestion: ingestion,
            quota: quota,
            capturedAt: capturedAt
        )
    }

    private func ingestion(
        errors: Int = 0,
        warnings: Int = 0,
        unrated: Int = 0
    ) -> SharedSnapshot.IngestionDigest {
        .init(
            typeCount: errors + warnings + unrated,
            errorCount: errors,
            warningCount: warnings,
            unratedCount: unrated,
            windowTitle: "7 days",
            capturedAt: capturedAt
        )
    }

    private func quota(
        blocked: Int = 0,
        state: SharedSnapshot.QuotaState? = nil
    ) -> SharedSnapshot.QuotaDigest {
        .init(
            blockedCount: blocked,
            resourceCount: 18,
            topTitle: "Signals credits",
            topState: state,
            capturedAt: capturedAt
        )
    }

    private func metric(
        id: String = "42",
        value: Double,
        previous: Double? = nil
    ) -> SharedSnapshot.Metric {
        .init(id: id, title: "Weekly active users", value: value, unit: nil,
              previous: previous, sparkline: [], dashboardID: nil)
    }

    // MARK: - Health: silence is the default

    @Test("a project with nothing wrong never asks for the top of the stack")
    func healthyScoresZero() {
        let clean = snapshot(ingestion: ingestion(), quota: quota())
        #expect(clean.healthVerdict == .clear)
        #expect(SnapshotRelevance.health(clean, now: capturedAt) == 0)
    }

    @Test("a project nothing has been checked on asks for nothing either")
    func uncheckedScoresZero() {
        let bare = snapshot()
        #expect(bare.healthVerdict == .unchecked)
        #expect(SnapshotRelevance.health(bare, now: capturedAt) == 0)
    }

    @Test("no snapshot at all scores zero rather than defaulting to a middle")
    func missingSnapshotScoresZero() {
        #expect(SnapshotRelevance.health(nil, now: capturedAt) == 0)
    }

    // MARK: - Health: the bands

    @Test("a blocked quota outranks every warning-only state")
    func criticalOutranksAttention() {
        let blocked = snapshot(ingestion: ingestion(), quota: quota(blocked: 1))
        // The loudest attention state this app can produce: five concerning
        // ingestion types and a quota past its watch line.
        let loudestAttention = snapshot(
            ingestion: ingestion(warnings: 40, unrated: 40), quota: quota(state: .critical)
        )

        #expect(blocked.healthVerdict == .critical)
        #expect(loudestAttention.healthVerdict == .attention)
        #expect(
            SnapshotRelevance.health(blocked, now: capturedAt)
                > SnapshotRelevance.health(loudestAttention, now: capturedAt)
        )
    }

    @Test("more of the same problem ranks above less of it")
    func severityMovesTheScoreWithinABand() {
        let one = snapshot(ingestion: ingestion(errors: 1))
        let two = snapshot(ingestion: ingestion(errors: 2))

        #expect(one.healthVerdict == .critical)
        #expect(two.healthVerdict == .critical)
        #expect(
            SnapshotRelevance.health(two, now: capturedAt)
                > SnapshotRelevance.health(one, now: capturedAt)
        )
    }

    @Test("the score is a range, not two values")
    func healthIsNotABinary() {
        let scores = [
            snapshot(ingestion: ingestion(warnings: 1)),
            snapshot(ingestion: ingestion(warnings: 3)),
            snapshot(ingestion: ingestion(errors: 1)),
            snapshot(ingestion: ingestion(errors: 2), quota: quota(blocked: 2)),
        ].map { SnapshotRelevance.health($0, now: capturedAt) }

        #expect(scores == scores.sorted())
        #expect(Set(scores).count == scores.count, "Distinct findings collapsed onto one score.")
    }

    @Test("nothing can exceed the ceiling")
    func healthStaysInsideTheCeiling() {
        let worst = snapshot(
            ingestion: ingestion(errors: 99, warnings: 99, unrated: 99),
            quota: quota(blocked: 99, state: .blocked)
        )
        let score = SnapshotRelevance.health(worst, now: capturedAt)
        #expect(score <= SnapshotRelevance.ceiling)
        #expect(score == SnapshotRelevance.ceiling)
    }

    // MARK: - Age

    @Test("a claim keeps its full weight while the snapshot is still called fresh")
    func freshClaimsKeepFullWeight() {
        let critical = snapshot(quota: quota(blocked: 1))
        let atCapture = SnapshotRelevance.health(critical, now: capturedAt)
        let justInsideStale = SnapshotRelevance.health(
            critical, now: capturedAt.addingTimeInterval(SnapshotRelevance.fullWeightWindow - 1)
        )
        #expect(atCapture == justInsideStale)
    }

    @Test("an aging claim decays, and stops claiming anything at the horizon")
    func staleClaimsDecayToNothing() {
        let critical = snapshot(quota: quota(blocked: 1))
        let fresh = SnapshotRelevance.health(critical, now: capturedAt)
        let middling = SnapshotRelevance.health(
            critical, now: capturedAt.addingTimeInterval(2 * 60 * 60)
        )
        let expired = SnapshotRelevance.health(
            critical, now: capturedAt.addingTimeInterval(SnapshotRelevance.decayHorizon)
        )

        #expect(middling < fresh)
        #expect(middling > 0)
        #expect(expired == 0)
    }

    @Test("a capture stamped in the future reads as fresh, never as more than fresh")
    func clockDriftDoesNotInflate() {
        let critical = snapshot(quota: quota(blocked: 1))
        let drifted = SnapshotRelevance.health(
            critical, now: capturedAt.addingTimeInterval(-3_600)
        )
        #expect(drifted == SnapshotRelevance.health(critical, now: capturedAt))
    }

    // MARK: - Metric: the user's own watches

    @Test("a watched metric in breach outranks any unwatched move")
    func breachOutranksMovement() {
        let watched = metric(value: 5_000, previous: 4_900)
        let snap = snapshot(metrics: [watched, metric(id: "99", value: 200, previous: 10)])
        let watches = [
            MetricWatch(id: "w1", metricID: "42", title: "Weekly active users",
                        condition: .above(1_000))
        ]

        let breaching = SnapshotRelevance.metric(watched, in: snap, watches: watches, now: capturedAt)
        // A twentyfold rise, which is as much movement as the scale can register.
        let moved = SnapshotRelevance.metric(
            snap.metric(id: "99"), in: snap, watches: watches, now: capturedAt
        )

        #expect(breaching > moved)
        #expect(moved > 0)
    }

    @Test("a watch that is not in breach earns nothing on its own")
    func watchWithinThresholdScoresNothing() {
        let quiet = metric(value: 500)
        let snap = snapshot(metrics: [quiet])
        let watches = [
            MetricWatch(id: "w1", metricID: "42", title: "Weekly active users",
                        condition: .above(1_000))
        ]
        #expect(SnapshotRelevance.metric(quiet, in: snap, watches: watches, now: capturedAt) == 0)
    }

    @Test("a paused watch cannot promote the widget")
    func disabledWatchIsIgnored() {
        let breaching = metric(value: 5_000)
        let snap = snapshot(metrics: [breaching])
        let watches = [
            MetricWatch(id: "w1", metricID: "42", title: "Weekly active users",
                        condition: .above(1_000), isEnabled: false)
        ]
        #expect(SnapshotRelevance.metric(breaching, in: snap, watches: watches, now: capturedAt) == 0)
    }

    @Test("a watch on some other metric does not promote this one")
    func watchOnAnotherMetricIsIgnored() {
        let subject = metric(value: 5_000)
        let snap = snapshot(metrics: [subject])
        let watches = [
            MetricWatch(id: "w1", metricID: "999", title: "Something else",
                        condition: .above(1))
        ]
        #expect(SnapshotRelevance.metric(subject, in: snap, watches: watches, now: capturedAt) == 0)
    }

    // MARK: - Metric: movement

    @Test("an ordinary wobble is not news")
    func smallMovesScoreNothing() {
        let barelyMoved = metric(value: 1_040, previous: 1_000)
        let snap = snapshot(metrics: [barelyMoved])
        #expect(SnapshotRelevance.metric(barelyMoved, in: snap, watches: [], now: capturedAt) == 0)
    }

    @Test("bigger moves rank above smaller ones")
    func biggerMovesRankHigher() {
        let scores = [1_200.0, 1_400, 1_800].map { value -> Float in
            let m = metric(value: value, previous: 1_000)
            return SnapshotRelevance.metric(m, in: snapshot(metrics: [m]), watches: [], now: capturedAt)
        }
        #expect(scores == scores.sorted())
        #expect(Set(scores).count == 3)
    }

    @Test("a fall counts as much as a rise")
    func directionIsNotPolarity() {
        // The snapshot records how a number moved, not whether moving that way is
        // desirable — a rise in errors and a rise in signups are the same field.
        let up = metric(value: 1_500, previous: 1_000)
        let down = metric(value: 500, previous: 1_000)
        #expect(
            SnapshotRelevance.metric(up, in: snapshot(metrics: [up]), watches: [], now: capturedAt)
                == SnapshotRelevance.metric(down, in: snapshot(metrics: [down]), watches: [], now: capturedAt)
        )
    }

    @Test("a metric with no comparison value claims nothing")
    func noBaselineScoresNothing() {
        let lonely = metric(value: 9_999_999)
        let snap = snapshot(metrics: [lonely])
        #expect(SnapshotRelevance.metric(lonely, in: snap, watches: [], now: capturedAt) == 0)
    }

    @Test("a zero baseline does not become an infinite percentage")
    func zeroBaselineScoresNothing() {
        let fromNothing = metric(value: 500, previous: 0)
        let snap = snapshot(metrics: [fromNothing])
        let score = SnapshotRelevance.metric(fromNothing, in: snap, watches: [], now: capturedAt)
        #expect(score == 0)
    }

    @Test("a non-finite value scores zero rather than ranking unpredictably")
    func nonFiniteValuesAreTotal() {
        for value in [Double.infinity, -.infinity, .nan] {
            let broken = metric(value: value, previous: 1_000)
            let snap = snapshot(metrics: [broken])
            let score = SnapshotRelevance.metric(broken, in: snap, watches: [], now: capturedAt)
            #expect(score.isFinite)
            #expect(score >= 0)
            #expect(score <= SnapshotRelevance.ceiling)
        }
    }

    @Test("a metric the snapshot does not contain scores zero")
    func missingMetricScoresZero() {
        #expect(SnapshotRelevance.metric(nil, in: snapshot(), watches: [], now: capturedAt) == 0)
    }

    @Test("a breach on a stale snapshot decays like every other claim")
    func breachDecaysWithAge() {
        let breaching = metric(value: 5_000)
        let snap = snapshot(metrics: [breaching])
        let watches = [
            MetricWatch(id: "w1", metricID: "42", title: "Weekly active users",
                        condition: .above(1_000))
        ]

        let fresh = SnapshotRelevance.metric(breaching, in: snap, watches: watches, now: capturedAt)
        let old = SnapshotRelevance.metric(
            breaching, in: snap, watches: watches,
            now: capturedAt.addingTimeInterval(SnapshotRelevance.decayHorizon)
        )
        #expect(fresh > 0)
        #expect(old == 0)
    }

    @Test("a watched breach on a metric that also moved reaches the ceiling")
    func metricStaysInsideTheCeiling() {
        let both = metric(value: 5_000, previous: 100)
        let snap = snapshot(metrics: [both])
        let watches = [
            MetricWatch(id: "w1", metricID: "42", title: "Weekly active users",
                        condition: .above(1_000))
        ]
        let score = SnapshotRelevance.metric(both, in: snap, watches: watches, now: capturedAt)
        #expect(score == SnapshotRelevance.ceiling)
    }

    // MARK: - Purity

    @Test("scoring a breach posts nothing and latches nothing")
    func scoringHasNoSideEffects() {
        // The breach question is answered by running the notification evaluator
        // with an empty prior set. That evaluator returns alerts to post; nothing
        // here may act on them, and a second identical call must give the same
        // answer rather than latching itself quiet.
        let breaching = metric(value: 5_000)
        let snap = snapshot(metrics: [breaching])
        let watches = [
            MetricWatch(id: "w1", metricID: "42", title: "Weekly active users",
                        condition: .above(1_000))
        ]

        let first = SnapshotRelevance.metric(breaching, in: snap, watches: watches, now: capturedAt)
        let second = SnapshotRelevance.metric(breaching, in: snap, watches: watches, now: capturedAt)
        #expect(first == second)
        #expect(first > 0)
    }
}
