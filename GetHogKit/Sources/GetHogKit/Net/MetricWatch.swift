import Foundation

/// A threshold the user asked to be told about, evaluated against the snapshot
/// the app already publishes for its widgets.
///
/// PostHog's own alerting fans out from a server, which this app does not have —
/// so alerting was recorded as blocked. But the snapshot written on every
/// background wake already carries each metric's current value, its
/// comparison-period value and its sparkline. Comparing those against a rule the
/// user typed, and posting a *local* notification, needs no server at all.
///
/// What it cannot do is pretend to be real-time. The wake that feeds it is a
/// `BGAppRefreshTask`, which iOS runs when it decides to — hours apart, or not at
/// all in Low Power Mode. Every surface that presents these says so.
public struct MetricWatch: Codable, Sendable, Identifiable, Equatable {

    public enum Condition: Codable, Sendable, Equatable {
        /// Strictly greater. "Above 1000" is what the user typed, and 1000 is
        /// not above 1000 — an inclusive comparison makes a round threshold fire
        /// on the round number itself, which reads as a bug.
        case above(Double)
        /// Strictly less, for the same reason.
        case below(Double)
        /// Magnitude of relative change against `SharedSnapshot.Metric.previous`,
        /// in percent, in either direction. Inclusive, unlike the two above: the
        /// change itself is what the user named as the trigger, so a change of
        /// exactly that size is the event they asked for.
        case changesByPercent(Double)
    }

    /// Stable across edits, so the breach latch survives renaming a watch.
    public let id: String
    /// Matches `SharedSnapshot.Metric.id`.
    public let metricID: String
    /// The tile's name as it stood when the watch was made. Used to list the
    /// watch when its metric is missing from the current snapshot; the
    /// notification itself prefers the metric's current name.
    public let title: String
    public let condition: Condition
    public var isEnabled: Bool

    public init(
        id: String,
        metricID: String,
        title: String,
        condition: Condition,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.metricID = metricID
        self.title = title
        self.condition = condition
        self.isEnabled = isEnabled
    }
}

// MARK: - Formatting

extension MetricWatch {

    /// A number written the way a threshold the user typed should read back.
    ///
    /// Deliberately not `FormatStyle`: these strings go into a notification body
    /// and into a threshold field the user edits, and a locale's grouping
    /// separator makes the second one impossible to parse back. Total by
    /// construction — a non-finite value describes itself rather than trapping,
    /// and the integer shortcut is only taken inside `Int64`'s range, because
    /// `Int(.infinity)` has already trapped twice in this codebase.
    public static func format(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15 else { return String(value) }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        return String(rounded)
    }
}

extension MetricWatch.Condition {

    /// One line describing the rule, for the watch list and the editor.
    public var summary: String {
        switch self {
        case .above(let threshold):
            "Above \(MetricWatch.format(threshold))"
        case .below(let threshold):
            "Below \(MetricWatch.format(threshold))"
        case .changesByPercent(let magnitude):
            "Changes by \(MetricWatch.format(abs(magnitude)))% or more"
        }
    }
}

// MARK: - Alerts

/// One notification's worth of content, ready for `UNMutableNotificationContent`.
///
/// Carries no `Date` and no scheduling: the evaluator does not decide *when*
/// anything is delivered, only that a crossing happened during this wake.
public struct MetricAlert: Sendable, Equatable, Identifiable {
    /// The watch that fired. Doubles as the identity of the alert, because at
    /// most one alert per watch can exist per evaluation.
    public let watchID: String
    public let metricID: String
    public let title: String
    public let body: String

    public var id: String { watchID }

    public init(watchID: String, metricID: String, title: String, body: String) {
        self.watchID = watchID
        self.metricID = metricID
        self.title = title
        self.body = body
    }
}

/// What one evaluation produced: the alerts to post, and the latch to persist.
public struct MetricWatchEvaluation: Sendable, Equatable {
    /// In the order the watches were held, so a wake that trips several is
    /// reproducible rather than dependent on set iteration order.
    public let alerts: [MetricAlert]
    /// The ids now considered in breach. Must be written back before the next
    /// wake, or every one of these fires again.
    public let breaching: Set<String>

    public init(alerts: [MetricAlert], breaching: Set<String>) {
        self.alerts = alerts
        self.breaching = breaching
    }
}

/// Turns a snapshot plus the user's watches into notifications to post.
///
/// Pure, so the rule that matters most here — *fire on the crossing, not on the
/// condition* — is testable without a notification centre or a two-hour wait.
public enum MetricWatchEvaluator {

    /// Evaluates every watch against `snapshot`.
    ///
    /// `breaching` is the set returned by the previous evaluation, and it is what
    /// makes this anti-spam rather than a firehose: a watch already in that set
    /// stays silent no matter how far past its threshold the metric has gone.
    /// A watch only leaves the set when its metric is *seen* to be back inside
    /// the threshold — never because the metric was missing, unreadable, or
    /// paused, all of which would otherwise read as a recovery and buy a second
    /// notification about an incident that never ended.
    public static func evaluate(
        snapshot: SharedSnapshot,
        watches: [MetricWatch],
        breaching: Set<String>
    ) -> MetricWatchEvaluation {
        var alerts: [MetricAlert] = []
        // Rebuilt from the live watches rather than mutated in place, so ids
        // belonging to deleted watches drain out instead of accumulating in the
        // file for as long as the app is installed.
        var stillBreaching: Set<String> = []

        for watch in watches {
            let wasBreaching = breaching.contains(watch.id)

            guard watch.isEnabled, let metric = snapshot.metric(id: watch.metricID) else {
                if wasBreaching { stillBreaching.insert(watch.id) }
                continue
            }

            switch verdict(for: watch.condition, metric: metric) {
            case .unknown:
                if wasBreaching { stillBreaching.insert(watch.id) }
            case .clear:
                break
            case .breaching(let body):
                stillBreaching.insert(watch.id)
                guard !wasBreaching else { break }
                alerts.append(
                    MetricAlert(
                        watchID: watch.id,
                        metricID: metric.id,
                        // The metric's current name, not the one saved with the
                        // watch: a renamed tile would otherwise send the user
                        // looking for something no longer on the dashboard.
                        title: metric.title,
                        body: body
                    )
                )
            }
        }

        return MetricWatchEvaluation(alerts: alerts, breaching: stillBreaching)
    }

    private enum Verdict {
        case breaching(String)
        case clear
        /// The snapshot cannot answer the question this wake — no comparison
        /// value, a zero baseline, a non-finite figure. Distinct from `clear`
        /// because it must not clear the latch.
        case unknown
    }

    private static func verdict(
        for condition: MetricWatch.Condition,
        metric: SharedSnapshot.Metric
    ) -> Verdict {
        // A malformed tile result decodes to infinity or NaN without complaint,
        // and neither can be compared usefully or written into a sentence.
        guard metric.value.isFinite else { return .unknown }
        let value = MetricWatch.format(metric.value)

        switch condition {
        case .above(let threshold):
            guard threshold.isFinite else { return .unknown }
            guard metric.value > threshold else { return .clear }
            return .breaching(
                "\(metric.title) is \(value), above your threshold of \(MetricWatch.format(threshold))."
            )

        case .below(let threshold):
            guard threshold.isFinite else { return .unknown }
            guard metric.value < threshold else { return .clear }
            return .breaching(
                "\(metric.title) is \(value), below your threshold of \(MetricWatch.format(threshold))."
            )

        case .changesByPercent(let magnitude):
            // `previous` documents nil as "not known", which is not "unchanged".
            // Half the tiles the app reduces to metrics carry no comparison at
            // all, so a baseline invented here would fire a +100% alert on every
            // one of them at the first wake after the watch was made. A baseline
            // of zero is the same problem wearing a different hat: every
            // percentage against zero is infinite, and this codebase has already
            // been bitten twice by an infinity reaching an `Int` conversion.
            guard magnitude.isFinite,
                  let previous = metric.previous,
                  previous.isFinite,
                  previous != 0
            else { return .unknown }

            let change = (metric.value - previous) / abs(previous) * 100
            guard change.isFinite else { return .unknown }
            guard abs(change) >= abs(magnitude) else { return .clear }

            // Direction is spelled out as a word: a notification has no room for
            // a colour, and an arrow glyph is not what VoiceOver reads well.
            let direction = change > 0 ? "up" : "down"
            return .breaching(
                """
                \(metric.title) is \(value), \(direction) \
                \(MetricWatch.format(abs(change)))% from \(MetricWatch.format(previous)).
                """
            )
        }
    }
}
