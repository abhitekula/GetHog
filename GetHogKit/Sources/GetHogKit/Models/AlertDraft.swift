import Foundation

// Setting and snoozing PostHog's server-side insight alerts. The threshold lives
// on PostHog's servers, PostHog evaluates it on its own schedule, and GetHog has
// no recurring polling role after the write.
//
// ## Everything here is source-derived and **none of it has been executed**
//
// Only the request shape is established here. It is derived from PostHog's
// `AlertSerializer` (`products/alerts/backend/api/alert.py`) and covered with
// deterministic synthetic requests. The test suite does not retain tenant
// responses or claim that write-response behavior has been observed.

// MARK: - Snoozing

/// How long to silence a firing alert for.
///
/// A closed set, and the titles are the interesting part.
///
/// `snoozed_until` is **not** a datetime field. It is a `RelativeDateTimeField`,
/// and the serializer's `update` runs the string through
/// `relative_date_parse(value, ZoneInfo("UTC"), increase=True,
/// always_truncate=True)`. `always_truncate` is what makes the naive titles
/// wrong: for an `h` unit it truncates to the **start of the hour**, and for
/// anything larger to the **start of the day**. So `"1d"` sent at 15:40 does not
/// mean "for 24 hours" — it means *tomorrow at 00:00 UTC*, which is 8h20m away.
///
/// The titles below say what the server will actually do rather than what the
/// string looks like it says. Three of the four are hour units, where truncation
/// costs at most 59 minutes and "about" covers it honestly; the day one is named
/// for the boundary it lands on, because calling it "24 hours" would be wrong by
/// up to a whole day.
///
/// `relative_date_parse` also accepts an absolute ISO-8601 datetime, so an
/// arbitrary date is expressible. It is not offered: a wheel that lets someone
/// pick 09:30 and silently rounds to 00:00 is a worse control than four buttons
/// that each say where they land.
public enum AlertSnooze: String, Sendable, Hashable, CaseIterable, Identifiable {
    case oneHour = "1h"
    case fourHours = "4h"
    case eightHours = "8h"
    case tomorrow = "1d"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oneHour: "About an hour"
        case .fourHours: "About 4 hours"
        case .eightHours: "About 8 hours"
        case .tomorrow: "Until tomorrow"
        }
    }

    /// The sentence a confirmation dialog puts under the title. Says where the
    /// silence ends and, for the day case, why it is not simply "24 hours".
    public var explanation: String {
        switch self {
        case .oneHour, .fourHours, .eightHours:
            "PostHog rounds this down to the start of the hour, so it can be up to an hour shorter."
        case .tomorrow:
            "PostHog snoozes to the start of the next day in UTC, not for a flat 24 hours — from late in the day that is only a few hours."
        }
    }
}

// MARK: - Threshold

/// The line an alert watches for, as `threshold.configuration`.
///
/// Both bounds are optional and at least one is required — the serializer's
/// `require_threshold_bounds` path raises when a threshold-based alert (one with
/// no `detector_config`) has neither. `make` returns `nil` rather than building a
/// body that will certainly be refused, which is the same contract
/// `FlagRollout.filters` has and for the same reason: rejecting it here means the
/// user is told before a request is spent.
public struct AlertThreshold: Sendable, Hashable, Codable {

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        /// Bounds are read as the metric's own units.
        case absolute
        /// Bounds are read as a **fraction** of the previous interval, so 0.2 is
        /// twenty per cent. `InsightAlert.summarise` already multiplies by 100 on
        /// the way out, which is where that is established.
        case percentage

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .absolute: "A number"
            case .percentage: "A percentage change"
            }
        }
    }

    public let kind: Kind
    /// Fires when the value drops below this.
    public let lower: Double?
    /// Fires when the value rises above this.
    public let upper: Double?

    /// `nil` when neither bound is set or either is not finite.
    public init?(kind: Kind, lower: Double?, upper: Double?) {
        let cleanLower = lower.flatMap { $0.isFinite ? $0 : nil }
        let cleanUpper = upper.flatMap { $0.isFinite ? $0 : nil }
        guard cleanLower != nil || cleanUpper != nil else { return nil }
        self.kind = kind
        self.lower = cleanLower
        self.upper = cleanUpper
    }

    var jsonValue: JSONValue {
        var bounds: [String: JSONValue] = [:]
        if let lower { bounds["lower"] = .number(lower) }
        if let upper { bounds["upper"] = .number(upper) }
        return .object([
            "configuration": .object([
                "type": .string(kind.rawValue),
                "bounds": .object(bounds),
            ])
        ])
    }

    /// The same sentence `InsightAlert.thresholdSummary` produces for a row that
    /// came back from the API, built from a draft that has not been sent yet — so
    /// the composer's preview and the list row cannot describe the same threshold
    /// two different ways.
    public var summary: String {
        func format(_ value: Double) -> String {
            let scaled = kind == .percentage ? value * 100 : value
            let text = scaled.formatted(.number.precision(.fractionLength(0...2)))
            return kind == .percentage ? "\(text)%" : text
        }
        switch (lower, upper) {
        case (let l?, let u?): return "Outside \(format(l))–\(format(u))"
        case (let l?, nil): return "Below \(format(l))"
        case (nil, let u?): return "Above \(format(u))"
        case (nil, nil): return "No threshold"
        }
    }
}

// MARK: - Condition

/// What the threshold is compared against.
public enum AlertCondition: String, Sendable, Hashable, CaseIterable, Identifiable {
    case absoluteValue = "absolute_value"
    case relativeIncrease = "relative_increase"
    case relativeDecrease = "relative_decrease"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .absoluteValue: "The value itself"
        case .relativeIncrease: "Its rise since last time"
        case .relativeDecrease: "Its fall since last time"
        }
    }
}

// MARK: - Cadence

/// How often PostHog evaluates the alert.
///
/// Six choices exist server-side and **two of them are plan-gated**: the
/// serializer's own help text says real time is Scale+ and every 15 minutes is
/// Boost+. Neither is offered here. This app cannot read the organisation's plan
/// — the one plan probe it has made, `GET /approval_policies/`, answered HTTP 402
/// — so offering a cadence it cannot know is available means a create that fails
/// for a reason the screen would have to guess at. The four unrestricted ones are
/// enough for a phone, and the sixth spelling of "no" in this API is not worth
/// discovering through a failed write.
public enum AlertCalculationInterval: String, Sendable, Hashable, CaseIterable, Identifiable {
    case hourly
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}

// MARK: - Per-kind config

/// `config`, PostHog's per-insight-kind alert configuration.
///
/// Discriminated by `type`, and the arm has to match the insight's query kind or
/// the create is refused by `validate_alert_config`. Only the two an app this
/// size can fill in honestly are modelled:
///
/// * **Trends** needs `series_index` — which of the insight's series to watch.
///   A trends insight with one series has exactly one answer and the composer
///   does not ask; with several it must.
/// * **Funnels** needs `metric`, and takes `funnel_step` (null = the overall
///   last step).
///
/// `HogQLAlertConfig` is deliberately absent even though SQL insights are
/// alertable. It requires an explicit `evaluation` — `last_row` / `first_row` /
/// `any_row` — whose correct value depends on the `ORDER BY` inside somebody's
/// SQL, and the serializer documents it as having "no implicit default" for
/// exactly that reason. A phone cannot read the query's ordering, and picking one
/// would arm an alert that watches the wrong row. `MetricsAlertConfig` is absent
/// because the Metrics product is itself flag-gated
/// (`_enforce_alert_feature_flags` raises "Metrics insight alerts are not enabled
/// for your account") and this app cannot see the flag.
public enum AlertConfig: Sendable, Hashable {
    case trends(seriesIndex: Int)
    case funnel(metric: FunnelMetric, step: Int?)

    public enum FunnelMetric: String, Sendable, Hashable, CaseIterable, Identifiable {
        case fromStart = "conversion_from_start"
        case fromPrevious = "conversion_from_previous"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .fromStart: "Conversion from the first step"
            case .fromPrevious: "Conversion from the previous step"
            }
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .trends(let index):
            return .object([
                "type": .string("TrendsAlertConfig"),
                "series_index": .number(Double(index)),
            ])
        case .funnel(let metric, let step):
            var fields: [String: JSONValue] = [
                "type": .string("FunnelsAlertConfig"),
                "metric": .string(metric.rawValue),
            ]
            // Written as an explicit null rather than omitted: the serializer
            // documents null as *the overall last step*, which is a choice, and
            // omitting the key leaves the choice to whatever the default happens
            // to be. Source-derived; not observed.
            fields["funnel_step"] = step.map { .number(Double($0)) } ?? .null
            return .object(fields)
        }
    }

    /// The `alertable_query_kind` this arm belongs to, so a draft cannot pair a
    /// funnel config with a trends insight.
    var sourceKind: String {
        switch self {
        case .trends: "TrendsQuery"
        case .funnel: "FunnelsQuery"
        }
    }
}

/// Which insight kinds PostHog will accept an alert on, and which of those this
/// app can compose one for.
///
/// `Insight.alertable_query_kind` on master returns non-nil for exactly four
/// kinds: `TrendsQuery`, `HogQLQuery`, `FunnelsQuery`, `MetricsQuery`. This app
/// composes for the first and third — see `AlertConfig` for why the other two
/// are read-only here. The distinction matters on screen: an alert that already
/// exists on a SQL insight is listed and can be snoozed, it just cannot be
/// *created* from a phone.
public enum AlertableInsight {

    /// Every kind PostHog itself will alert on.
    public static let supportedByPostHog: Set<String> = [
        "TrendsQuery", "HogQLQuery", "FunnelsQuery", "MetricsQuery",
    ]

    /// The subset this app can build a `config` for.
    public static let composable: Set<String> = ["TrendsQuery", "FunnelsQuery"]

    public static func isAlertable(sourceKind: String) -> Bool {
        supportedByPostHog.contains(sourceKind)
    }

    public static func isComposable(sourceKind: String) -> Bool {
        composable.contains(sourceKind)
    }

    /// Why the composer is unavailable for this insight, in the words of whatever
    /// actually makes it unavailable — never a bare disabled button.
    ///
    /// `nil` when a draft can be composed.
    public static func unavailableReason(sourceKind: String) -> String? {
        if composable.contains(sourceKind) { return nil }
        switch sourceKind {
        case "HogQLQuery":
            return "PostHog alerts on SQL insights, but it needs to be told which row of your result is the current value — and that depends on the ORDER BY inside the query. Set this one up in PostHog."
        case "MetricsQuery":
            return "Alerts on metrics insights are behind a PostHog feature flag that this app can't see the state of. Set this one up in PostHog."
        default:
            return "PostHog only alerts on trends, funnel and SQL insights. This one is a \(sourceKind)."
        }
    }
}

// MARK: - The draft

/// Everything `POST /alerts/` needs, as one value the composer can hold and a
/// test can assert on.
///
/// `subscribedUserIDs` is required and must be non-empty *in this app*, though
/// the serializer declares `allow_empty=True`. An alert with no subscriber and no
/// configured destination is one PostHog will evaluate and have nowhere to
/// report — its own `test-delivery` action answers 409 *"Add an email recipient
/// or active destination before sending a test."* for precisely that state. The
/// composer defaults it to the signed-in user, which is the only user id this app
/// knows without spending a request (`MeResponse.userID`).
public struct AlertDraft: Sendable, Hashable {
    public let insightID: Int
    public let name: String
    public let subscribedUserIDs: [Int]
    public let threshold: AlertThreshold
    public let condition: AlertCondition
    public let config: AlertConfig
    public let interval: AlertCalculationInterval

    public init(
        insightID: Int,
        name: String,
        subscribedUserIDs: [Int],
        threshold: AlertThreshold,
        condition: AlertCondition,
        config: AlertConfig,
        interval: AlertCalculationInterval
    ) {
        self.insightID = insightID
        self.name = name
        self.subscribedUserIDs = subscribedUserIDs
        self.threshold = threshold
        self.condition = condition
        self.config = config
        self.interval = interval
    }

    /// `nil` when the draft cannot produce a request PostHog would accept, which
    /// is checked here rather than at the call site so the composer's Save button
    /// and the endpoint builder cannot disagree about what is valid.
    var jsonValue: JSONValue? {
        guard !subscribedUserIDs.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { return nil }

        return .object([
            "insight": .number(Double(insightID)),
            "name": .string(trimmed),
            "subscribed_users": .array(subscribedUserIDs.map { .number(Double($0)) }),
            "threshold": threshold.jsonValue,
            "condition": .object(["type": .string(condition.rawValue)]),
            "config": config.jsonValue,
            "calculation_interval": .string(interval.rawValue),
            // Sent explicitly rather than left to the model default: an alert
            // created from a phone is created because somebody wants it running
            // now, and a create that silently lands disabled is the failure this
            // app would have no way to notice.
            "enabled": .bool(true),
        ])
    }

    /// Whether this draft would build a request at all — the cheap form of the
    /// same question, for enabling a button.
    public var isSendable: Bool { jsonValue != nil }

    /// One sentence naming the object and the direction, for the confirmation
    /// dialog. Every mutating call in this app has one.
    public func confirmation(insightTitle: String) -> String {
        """
        PostHog will check \(insightTitle) \(interval.title.lowercased()) and e-mail \
        \(subscriberPhrase) when \(condition.title.lowercased()) is \
        \(threshold.summary.lowercased()). Nothing is sent to this phone.
        """
    }

    private var subscriberPhrase: String {
        subscribedUserIDs.count == 1 ? "you" : "\(subscribedUserIDs.count) people"
    }
}
