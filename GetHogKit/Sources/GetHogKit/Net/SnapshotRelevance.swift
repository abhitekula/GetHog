import Foundation

/// How loudly the cached snapshot asks to be looked at, on the scale a widget
/// hands to WidgetKit as `TimelineEntryRelevance`.
///
/// **What the score is for.** A widget sitting in a Smart Stack is rotated to the
/// top when its next entry claims to matter more than the entry it is currently
/// showing. WidgetKit only ever compares a score against *the same widget's*
/// other scores — never across widgets and never across apps — so the range below
/// is ours to define, and only the ordering within it means anything.
///
/// **What it must not be.** A constant. A widget that reports 50 forever has told
/// the system precisely nothing, and every rotation it then wins was won on noise.
/// Every number here is read out of the App Group file the app already writes:
/// the health verdict and its two digests, the user's own metric watches, and how
/// old the file is. Nothing is fetched, guessed, or held constant.
///
/// **Why it lives in the kit.** The widget extension is not unit-tested — it is a
/// separate binary that the app's test target does not compile — and a scoring
/// rule nobody can run is a scoring rule nobody can check. Here it is a pure
/// function of values that already cross the process boundary, and
/// `SnapshotRelevanceTests` runs it without a Home Screen.
public enum SnapshotRelevance {

    /// Top of the scale.
    ///
    /// Arbitrary, and fixed on purpose: because WidgetKit compares only within one
    /// widget, the useful property is that both surfaces below can reach the same
    /// ceiling and neither can exceed it, so "as urgent as this widget ever gets"
    /// means one thing.
    public static let ceiling: Float = 100

    // MARK: - Age

    /// How long a snapshot's claim keeps its full weight.
    ///
    /// The same thirty minutes the freshness footer already calls stale, because
    /// that is this app's existing answer to "is this current", and a second
    /// threshold that disagreed with it would put the widget's ranking at odds
    /// with the widget's own caption.
    public static let fullWeightWindow: TimeInterval = SharedSnapshot.defaultStaleTolerance

    /// Where a claim reaches zero weight.
    ///
    /// Six hours, against a background wake that iOS runs roughly every two. One
    /// missed wake still leaves most of the weight; three means the app has not
    /// run all morning, and the error spike being reported may have ended before
    /// breakfast. Promoting a stale alarm to the top of a stack is worse than
    /// staying put, because the stack shows no timestamp — the user cannot tell
    /// from the rotation that the alarm is old, and the widget's own footer only
    /// says so once they are already looking at it.
    public static let decayHorizon: TimeInterval = 6 * 60 * 60

    /// Full weight while fresh, falling linearly to nothing at `decayHorizon`.
    ///
    /// A negative age is clock drift rather than extra urgency — snapshots outlive
    /// NTP corrections, which is why `SharedSnapshot.staleness` clamps at zero —
    /// and it reads here as "fresh", never as "more than fresh".
    public static func weight(age: TimeInterval) -> Float {
        guard age > fullWeightWindow else { return 1 }
        guard age < decayHorizon else { return 0 }
        return Float(1 - (age - fullWeightWindow) / (decayHorizon - fullWeightWindow))
    }

    // MARK: - Health

    /// The bands the health verdict lands in, before magnitude and age.
    ///
    /// `.clear` and `.unchecked` are both zero, and the two zeros mean different
    /// things that happen to have the same consequence. "Nothing to report" is the
    /// state this widget is in almost all the time, and a stack that promoted it
    /// would teach the user that a GetHog card at the top means nothing — which
    /// costs the one moment the card exists for. "Not checked" is a widget with no
    /// finding at all, and it has even less business interrupting.
    static let attentionBase: Float = 40
    static let criticalBase: Float = 70

    /// How much this snapshot's health deserves the top of a stack.
    ///
    /// The bands cannot overlap: `.critical` is only reachable with a blocked
    /// quota or an ingestion error, each of which carries at least a five-point
    /// bonus, so the quietest critical (75) still outranks the loudest attention
    /// (45). That matters because the two states are answered differently — one is
    /// "go and look now", the other is "before the end of the day".
    public static func health(_ snapshot: SharedSnapshot?, now: Date) -> Float {
        guard let snapshot else { return 0 }

        let base: Float
        switch snapshot.healthVerdict {
        case .unchecked, .clear: return 0
        case .attention: base = attentionBase
        case .critical: base = criticalBase
        }

        return clamped((base + healthBonus(snapshot)) * weight(age: snapshot.staleness(now: now)))
    }

    /// Separates two projects in the same band by how much is wrong.
    ///
    /// Counts of *kinds* rather than of events throughout. One warning type
    /// affecting five million events is one thing to go and fix; five types
    /// affecting a thousand each is five, and the second is the busier morning.
    static func healthBonus(_ snapshot: SharedSnapshot) -> Float {
        // Data already being refused outright, which nothing else in the snapshot
        // reports — a quota-blocked project raises no ingestion warning at all.
        let blocked = min(15, Float(snapshot.quota?.blockedCount ?? 0) * 5)
        let errors = min(10, Float(snapshot.ingestion?.errorCount ?? 0) * 5)
        // Unrated counts with the warnings, not with the benign: PostHog adds
        // severities when it has something new to warn about.
        let warnings = Float((snapshot.ingestion?.warningCount ?? 0)
            + (snapshot.ingestion?.unratedCount ?? 0))
        return blocked + errors + min(5, warnings)
    }

    // MARK: - Metric

    /// What a metric with one of the user's own watches in breach starts from.
    ///
    /// Far above anything an unwatched metric can reach, because a watch is the
    /// only thing in this app that is an explicit request to be told. Everything
    /// below it is the app's inference; this is the user's instruction.
    static let watchedBreachBase: Float = 80

    /// Below this, a move is the ordinary breathing of a metric and earns nothing.
    ///
    /// Ten per cent, which is at the low end of what users actually type into
    /// `Condition.changesByPercent`. A widget that promoted itself for every
    /// four-per-cent wobble would be at the top of the stack permanently.
    public static let moveFloor: Double = 0.10
    /// Where the move bonus saturates. Past a doubling or a halving, "it moved a
    /// lot" has stopped being a useful gradient.
    public static let moveCeiling: Double = 1.0
    static let moveBonusCeiling: Float = 20

    /// How much a metric deserves the top of a stack.
    ///
    /// Scored against the *configured* metric only — the one every family leads
    /// with, and the only one the small and accessory families draw at all. The
    /// large family shows up to six, so a breach in the fourth of them does not
    /// lift this widget; promoting a card for a number that card might not be
    /// showing is a worse failure than missing a rotation.
    public static func metric(
        _ metric: SharedSnapshot.Metric?,
        in snapshot: SharedSnapshot?,
        watches: [MetricWatch],
        now: Date
    ) -> Float {
        guard let snapshot, let metric else { return 0 }
        let base: Float = isBreaching(metric, in: snapshot, watches: watches) ? watchedBreachBase : 0
        return clamped((base + moveBonus(metric)) * weight(age: snapshot.staleness(now: now)))
    }

    /// Whether any enabled watch on this metric is in breach **of this snapshot**.
    ///
    /// Asked of `MetricWatchEvaluator` with an empty prior breach set, rather than
    /// read out of `breachingWatchIDs`. That file is anti-spam state: it
    /// deliberately keeps an id whose metric has gone missing, so that a
    /// disappearance can never be mistaken for a recovery and buy a second
    /// notification. Reading it here would let the widget claim urgency about a
    /// number the snapshot no longer contains. Evaluating against an empty set
    /// asks the narrower question this needs — is it over the line right now, in
    /// the file I am about to render — and it is pure: no alert is posted, no
    /// latch is written, nothing is fetched.
    public static func isBreaching(
        _ metric: SharedSnapshot.Metric,
        in snapshot: SharedSnapshot,
        watches: [MetricWatch]
    ) -> Bool {
        let mine = watches.filter { $0.metricID == metric.id && $0.isEnabled }
        guard !mine.isEmpty else { return false }
        return !MetricWatchEvaluator.evaluate(
            snapshot: snapshot, watches: mine, breaching: []
        ).breaching.isEmpty
    }

    /// How far the metric moved against its comparison period, mapped onto the
    /// band a move alone can earn.
    ///
    /// Unsigned, deliberately. The snapshot records how a number moved and not
    /// whether moving that way is desirable — a rise in errors and a rise in
    /// signups are the same field — which is the same reason `WidgetPalette`
    /// refuses to paint direction green-good and red-bad. `deltaFraction` is
    /// already `nil` when there is no baseline or the baseline is zero, so neither
    /// "not known" nor an infinite percentage reaches the arithmetic.
    static func moveBonus(_ metric: SharedSnapshot.Metric) -> Float {
        guard let fraction = metric.deltaFraction, fraction.isFinite else { return 0 }
        let magnitude = abs(fraction)
        guard magnitude > moveFloor else { return 0 }
        let span = min(magnitude, moveCeiling) - moveFloor
        return moveBonusCeiling * Float(span / (moveCeiling - moveFloor))
    }

    // MARK: - Plumbing

    /// Total by construction: a NaN reaching WidgetKit would rank unpredictably
    /// rather than loudly, and this codebase has already been bitten twice by a
    /// non-finite double travelling further than anyone expected.
    static func clamped(_ score: Float) -> Float {
        guard score.isFinite else { return 0 }
        return min(max(score, 0), ceiling)
    }
}
