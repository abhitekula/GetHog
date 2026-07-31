import Foundation

// The operational resources: workflows, saved query endpoints, insight alerts,
// subscriptions and batch exports. They share a file because the app shows them
// on one screen and they answer one question between them — what is this project
// doing on a schedule, and is any of it broken?
//
// Four of the five are read-only in GetHog. **Alerts are not**, and the
// sentence that used to stand here — that the app has no server to receive a
// push — was true and was never a reason. PostHog evaluates an alert on its own
// servers and delivers it to `subscribed_users` by e-mail or to a configured
// destination; nothing is delivered *to* GetHog either way, exactly as the
// subscriptions line has always said. Setting one is a write like any other, and
// it lives in `AlertDraft.swift` and `PostHogAPI+Alerts.swift`.
//
// Subscriptions stay read-only for a different and real reason: a subscription
// carries a delivery target — an address, a Slack channel, a webhook URL — and
// composing one from a phone means typing somebody else's address into a
// recurring send. That is a decision, and it is stated as one.

// MARK: - Workflows (hog flows)

/// A workflow's lifecycle state, as PostHog's `HogFlow.State` choices.
public enum WorkflowStatus: String, Sendable, Hashable, CaseIterable {
    case draft
    case active
    case archived
    case unknown

    public var title: String {
        switch self {
        case .draft: "Draft"
        case .active: "Active"
        case .archived: "Archived"
        case .unknown: "Unknown"
        }
    }

    /// Anything unrecognised stays `.unknown` rather than reading as live — the
    /// choice list has grown before and a workflow wrongly shown as running is
    /// worse than one shown as unclear.
    public init(raw: String?) {
        switch raw?.lowercased() {
        case "draft": self = .draft
        case "active": self = .active
        case "archived": self = .archived
        default: self = .unknown
        }
    }
}

/// A messaging/automation workflow from `GET /hog_flows/`.
public struct Workflow: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let status: WorkflowStatus
    /// `trigger.type` — how the flow is entered (`event`, `schedule`, …).
    public let triggerKind: String?
    public let version: Int?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let authorName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, status, trigger, version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled workflow"
        description = (try c.decodeIfPresent(String.self, forKey: .description))
            .flatMap { $0.isEmpty ? nil : $0 }
        status = WorkflowStatus(raw: try c.decodeIfPresent(String.self, forKey: .status))
        let trigger = (try? c.decodeIfPresent(JSONValue.self, forKey: .trigger)) ?? nil
        triggerKind = trigger?["type"]?.stringValue
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(PostHogDate.parse)
        authorName = c.decodeUserName(forKey: .createdBy)
    }

    /// Plain-language trigger line, never left to the pill alone.
    public var triggerSummary: String {
        guard let triggerKind else { return "No trigger configured" }
        return "Triggered by \(triggerKind.replacingOccurrences(of: "_", with: " "))"
    }
}

// MARK: - Query endpoints

/// A saved query published over HTTP, from `GET /endpoints/`.
///
/// Named `QueryEndpoint` rather than `Endpoint` because `Endpoint` is already
/// this package's request descriptor.
public struct QueryEndpoint: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    /// The `kind` inside the stored query node — `HogQLQuery`, `TrendsQuery`, …
    public let queryKind: String?
    public let isActive: Bool
    public let isMaterialized: Bool
    public let columnCount: Int
    public let dataFreshnessSeconds: Int?
    public let lastExecutedAt: Date?
    public let createdAt: Date?
    public let authorName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, query, columns
        case isActive = "is_active"
        case isMaterialized = "is_materialized"
        case dataFreshnessSeconds = "data_freshness_seconds"
        case lastExecutedAt = "last_executed_at"
        case createdAt = "created_at"
        case createdBy = "created_by"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled endpoint"
        description = (try c.decodeIfPresent(String.self, forKey: .description))
            .flatMap { $0.isEmpty ? nil : $0 }
        let query = (try? c.decodeIfPresent(JSONValue.self, forKey: .query)) ?? nil
        queryKind = query?["kind"]?.stringValue
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isMaterialized = try c.decodeIfPresent(Bool.self, forKey: .isMaterialized) ?? false
        columnCount = ((try? c.decodeIfPresent([JSONValue].self, forKey: .columns)) ?? nil)?.count ?? 0
        dataFreshnessSeconds = try c.decodeIfPresent(Int.self, forKey: .dataFreshnessSeconds)
        lastExecutedAt = try c.decodeIfPresent(String.self, forKey: .lastExecutedAt)
            .flatMap(PostHogDate.parse)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        authorName = c.decodeUserName(forKey: .createdBy)
    }

    public var statusText: String { isActive ? "Live" : "Disabled" }
}

// MARK: - Alerts

/// An alert's current state.
///
/// PostHog sends this as capitalised prose — "Firing", "Not firing", "Errored",
/// "Snoozed" — not as an enum slug, so it is matched on the words.
public enum AlertState: Sendable, Hashable {
    case firing
    case notFiring
    case errored
    case snoozed
    case unknown

    public var title: String {
        switch self {
        case .firing: "Firing"
        case .notFiring: "Not firing"
        case .errored: "Errored"
        case .snoozed: "Snoozed"
        case .unknown: "Unknown"
        }
    }

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "firing": self = .firing
        case "not firing": self = .notFiring
        case "errored": self = .errored
        case "snoozed": self = .snoozed
        default: self = .unknown
        }
    }
}

/// An insight alert from `GET /alerts/`.
public struct InsightAlert: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let insightID: Int?
    public let insightName: String?
    public let insightShortID: String?
    public let state: AlertState
    public let enabled: Bool
    public let thresholdSummary: String?
    public let lastValue: Double?
    public let lastCheckedAt: Date?
    public let calculationInterval: String?
    /// When an active snooze expires. `nil` is *not snoozed*.
    ///
    /// Read even though `state` already carries a `.snoozed` case, because the
    /// two answer different questions: `state` says the alert is quiet, this says
    /// when it stops being quiet. A snooze control that could not show the end
    /// time would leave "Snoozed" reading as indefinite, which is the one thing a
    /// snooze is not.
    public let snoozedUntil: Date?
    /// When PostHog next evaluates it, if the payload said.
    public let nextCheckAt: Date?
    /// Who PostHog e-mails when it fires, by display name.
    ///
    /// The whole point of the alerts screen on a phone: "who gets told" is the
    /// question a person answers before they trust an alert, and this app has
    /// spent its life unable to state it. `subscribed_users` is a list of ids on
    /// the way *in* and a list of `UserBasicSerializer` objects on the way *out*
    /// — the same asymmetry `insight` has — so this decodes objects and reduces
    /// each to a name.
    ///
    /// Empty is a real answer and must not be dressed up: PostHog's own
    /// `test-delivery` action answers 409 *"Add an email recipient or active
    /// destination before sending a test."* for an alert in exactly that state.
    public let subscribedUsers: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, insight, threshold, state, enabled
        case lastValue = "last_value"
        case lastCheckedAt = "last_checked_at"
        case calculationInterval = "calculation_interval"
        case snoozedUntil = "snoozed_until"
        case nextCheckAt = "next_check_at"
        case subscribedUsers = "subscribed_users"
    }

    private enum InsightKeys: String, CodingKey {
        case id, name
        case shortID = "short_id"
        case derivedName = "derived_name"
    }

    private enum ThresholdKeys: String, CodingKey {
        case configuration
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name))
            .flatMap { $0.isEmpty ? nil : $0 }
        state = AlertState(raw: try c.decodeIfPresent(String.self, forKey: .state))
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastValue = try c.decodeIfPresent(Double.self, forKey: .lastValue)
        lastCheckedAt = try c.decodeIfPresent(String.self, forKey: .lastCheckedAt)
            .flatMap(PostHogDate.parse)
        calculationInterval = try c.decodeIfPresent(String.self, forKey: .calculationInterval)
        // `snoozed_until` is a `RelativeDateTimeField` on the way *in* — "4h",
        // "1d" — and a stored datetime on the way out, so this reads a date and
        // `PostHogAPI.setAlertSnoozed` writes a duration. Neither spelling is a
        // mistake; they are two different directions of the same field.
        snoozedUntil = try c.decodeIfPresent(String.self, forKey: .snoozedUntil)
            .flatMap(PostHogDate.parse)
        nextCheckAt = try c.decodeIfPresent(String.self, forKey: .nextCheckAt)
            .flatMap(PostHogDate.parse)
        // `try?`-and-default, like every other optional field on this type: a
        // subscriber whose shape this build does not recognise must not take the
        // whole alerts page down with it.
        subscribedUsers = ((try? c.decodeIfPresent([PostHogNestedUser].self, forKey: .subscribedUsers))
            ?? nil)?.compactMap(\.displayName) ?? []

        // `insight` is a full InsightBasicSerializer object despite the singular
        // field name; decoding it as the id it looks like throws.
        let insight = try? c.nestedContainer(keyedBy: InsightKeys.self, forKey: .insight)
        insightID = try? insight?.decodeIfPresent(Int.self, forKey: .id)
        insightShortID = try? insight?.decodeIfPresent(String.self, forKey: .shortID)
        let explicitName = ((try? insight?.decodeIfPresent(String.self, forKey: .name)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 }
        let derived = ((try? insight?.decodeIfPresent(String.self, forKey: .derivedName)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 }
        insightName = explicitName ?? derived

        let threshold = try? c.nestedContainer(keyedBy: ThresholdKeys.self, forKey: .threshold)
        let configuration = ((try? threshold?.decodeIfPresent(
            JSONValue.self, forKey: .configuration
        )) ?? nil)
        thresholdSummary = Self.summarise(configuration: configuration)
    }

    /// Alerts are often unnamed; the insight they watch is the next best label.
    public var displayTitle: String {
        name ?? insightName ?? "Untitled alert"
    }

    /// Whether a snooze is still running, judged against `now` rather than
    /// against `state`.
    ///
    /// The two can disagree, and the direction they disagree in is the awkward
    /// one: `state` is written by PostHog's state machine when a check runs, and
    /// a snoozed alert is not checked — so a snooze that expired ten minutes ago
    /// can still be reported as `Snoozed` until the next evaluation. Reading the
    /// date is the only way a screen can offer "Unsnooze" for an alert that has
    /// in fact already woken up, and not offer it for one that has not.
    ///
    /// **Source-derived**: read from the serializer's `update`, never observed —
    /// this project has no alerts to watch a snooze expire on.
    public func isSnoozed(now: Date = Date()) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    /// Who PostHog tells, said in full or admitted to be nobody.
    ///
    /// Never "0 subscribers": an alert nobody is subscribed to and that has no
    /// destination is one PostHog evaluates into silence, which is a finding
    /// rather than a count.
    public var deliverySummary: String {
        switch subscribedUsers.count {
        case 0:
            // Deliberately hedged. This app reads `subscribed_users` and cannot
            // see the alert's Slack/webhook destinations at all — those live on
            // separate CDP function rows this client does not fetch — so an empty
            // list means "no e-mail recipient", not "nobody is told".
            return "No e-mail recipient. PostHog may still post this to a destination GetHog can't see."
        case 1:
            return "E-mails \(subscribedUsers[0])"
        default:
            return "E-mails \(subscribedUsers.count) people: \(subscribedUsers.joined(separator: ", "))"
        }
    }

    /// Turns `{"type": "absolute", "bounds": {"lower": 100}}` into "Below 100".
    private static func summarise(configuration: JSONValue?) -> String? {
        guard let configuration else { return nil }
        let isPercentage = configuration["type"]?.stringValue == "percentage"
        let bounds = configuration["bounds"]
        let lower = bounds?["lower"]?.doubleValue
        let upper = bounds?["upper"]?.doubleValue

        func format(_ value: Double) -> String {
            let scaled = isPercentage ? value * 100 : value
            let text = scaled.formatted(.number.precision(.fractionLength(0...2)))
            return isPercentage ? "\(text)%" : text
        }

        switch (lower, upper) {
        case (let l?, let u?): return "Outside \(format(l))–\(format(u))"
        case (let l?, nil): return "Below \(format(l))"
        case (nil, let u?): return "Above \(format(u))"
        case (nil, nil): return nil
        }
    }
}

// MARK: - Subscriptions

/// Where a subscription is delivered.
public enum SubscriptionTarget: String, Sendable, Hashable, CaseIterable {
    case email
    case slack
    case webhook
    case unknown

    public var title: String {
        switch self {
        case .email: "Email"
        case .slack: "Slack"
        case .webhook: "Webhook"
        case .unknown: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .email: "envelope"
        case .slack: "number.square"
        case .webhook: "link"
        case .unknown: "questionmark.square"
        }
    }

    public init(raw: String?) {
        self = SubscriptionTarget(rawValue: raw?.lowercased() ?? "") ?? .unknown
    }
}

/// A scheduled insight or dashboard delivery, from `GET /subscriptions/`.
public struct InsightSubscription: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let title: String?
    public let resourceName: String?
    public let resourceType: String?
    public let target: SubscriptionTarget
    public let targetValue: String?
    public let frequency: String?
    public let enabled: Bool
    public let deleted: Bool
    public let nextDeliveryDate: Date?
    public let insightShortID: String?
    public let dashboardID: Int?
    /// PostHog's own words for the schedule, e.g. "sent every week on Monday".
    public let scheduleSummary: String

    enum CodingKeys: String, CodingKey {
        case id, title, summary, frequency, enabled, deleted, dashboard
        case resourceName = "resource_name"
        case resourceType = "resource_type"
        case targetType = "target_type"
        case targetValue = "target_value"
        case nextDeliveryDate = "next_delivery_date"
        case insightShortID = "insight_short_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try c.decodeIfPresent(String.self, forKey: .title))
            .flatMap { $0.isEmpty ? nil : $0 }
        resourceName = (try c.decodeIfPresent(String.self, forKey: .resourceName))
            .flatMap { $0.isEmpty ? nil : $0 }
        resourceType = try c.decodeIfPresent(String.self, forKey: .resourceType)
        target = SubscriptionTarget(raw: try c.decodeIfPresent(String.self, forKey: .targetType))
        targetValue = (try c.decodeIfPresent(String.self, forKey: .targetValue))
            .flatMap { $0.isEmpty ? nil : $0 }
        frequency = try c.decodeIfPresent(String.self, forKey: .frequency)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        nextDeliveryDate = try c.decodeIfPresent(String.self, forKey: .nextDeliveryDate)
            .flatMap(PostHogDate.parse)
        insightShortID = try c.decodeIfPresent(String.self, forKey: .insightShortID)
        dashboardID = try c.decodeIfPresent(Int.self, forKey: .dashboard)

        // `summary` is a computed field and has come back null on older rows; the
        // schedule is the most useful fact on the row, so it degrades to the raw
        // frequency rather than to nothing.
        let summary = (try c.decodeIfPresent(String.self, forKey: .summary))
            .flatMap { $0.isEmpty ? nil : $0 }
        let frequencyValue = try c.decodeIfPresent(String.self, forKey: .frequency)
        scheduleSummary = summary
            ?? frequencyValue.map { "sent \($0)" }
            ?? "Schedule not reported"
    }

    public var displayTitle: String {
        title ?? resourceName ?? "Untitled subscription"
    }

    public var statusText: String { enabled ? "Enabled" : "Paused" }
}

// MARK: - Batch exports

/// A scheduled bulk export to a warehouse or object store, from
/// `GET /batch_exports/`.
public struct BatchExport: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let model: String?
    public let destinationType: String?
    public let interval: String?
    public let paused: Bool
    public let createdAt: Date?
    public let lastUpdatedAt: Date?
    public let lastRunHealth: SyncHealth
    public let lastRunAt: Date?
    public let lastRunError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, model, destination, interval, paused
        case createdAt = "created_at"
        case lastUpdatedAt = "last_updated_at"
        case latestRuns = "latest_runs"
    }

    private enum DestinationKeys: String, CodingKey {
        case type
    }

    private struct Run: Decodable {
        let status: String?
        let latestError: String?
        let finishedAt: String?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case status
            case latestError = "latest_error"
            case finishedAt = "finished_at"
            case createdAt = "created_at"
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled export"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        lastUpdatedAt = try c.decodeIfPresent(String.self, forKey: .lastUpdatedAt)
            .flatMap(PostHogDate.parse)

        let destination = try? c.nestedContainer(keyedBy: DestinationKeys.self, forKey: .destination)
        destinationType = (try? destination?.decodeIfPresent(String.self, forKey: .type)) ?? nil

        // `latest_runs` is documented as newest-first, so the head is the run
        // worth reporting. An export with no runs stays `.unknown` — "Completed"
        // would be a claim the API never made.
        let runs = ((try? c.decodeIfPresent([Run].self, forKey: .latestRuns)) ?? nil) ?? []
        let latest = runs.first
        lastRunHealth = SyncHealth(status: latest?.status)
        lastRunAt = (latest?.finishedAt ?? latest?.createdAt).flatMap(PostHogDate.parse)
        lastRunError = latest?.latestError.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var statusText: String { paused ? "Paused" : "Running" }

    /// Plain-language schedule line for the row's secondary text.
    public var scheduleSummary: String {
        guard let interval else { return "Interval not reported" }
        return "Every \(interval)"
    }
}
