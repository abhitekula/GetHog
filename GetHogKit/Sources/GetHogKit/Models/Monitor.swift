import Foundation

// MARK: - Health issues

/// What a health issue is about.
///
/// Open-ended on purpose: PostHog adds kinds without notice, and the payload
/// shape follows the kind, so an unrecognised one has to be survivable.
public enum HealthIssueKind: String, Sendable, Hashable {
    case sdkOutdated = "sdk_outdated"
    case ingestionWarning = "ingestion_warning"
    case webVitals = "web_vitals"
    case authorizedURLs = "authorized_urls"
    case unknown

    init(raw: String?) {
        self = raw.flatMap(HealthIssueKind.init(rawValue:)) ?? .unknown
    }
}

public enum HealthIssueSeverity: String, Sendable, Hashable {
    case critical, warning, info, unknown

    init(raw: String?) {
        self = raw.flatMap(HealthIssueSeverity.init(rawValue:)) ?? .unknown
    }

    /// Worst first.
    public var rank: Int {
        switch self {
        case .critical: 0
        case .warning: 1
        case .info: 2
        case .unknown: 3
        }
    }
}

public enum HealthIssueStatus: String, Sendable, Hashable {
    case active, resolved, unknown

    init(raw: String?) {
        self = raw.flatMap(HealthIssueStatus.init(rawValue:)) ?? .unknown
    }
}

/// The typed reading of a health issue's `payload`.
///
/// `payload` is polymorphic keyed by `kind` — an `sdk_outdated` issue carries
/// `sdk_name`/`current_version`/`latest_version`, and the other kinds carry
/// entirely different fields. That is structurally the same problem as
/// `insight.result`, so it gets the same treatment: the messiness is decoded
/// once here and never reaches a view, and anything unrecognised degrades to a
/// card rather than throwing.
public enum HealthIssueDetail: Sendable, Hashable {
    case sdkOutdated(name: String, current: String, latest: String)
    case ingestionWarning(summary: String)
    case webVitals(summary: String)
    case authorizedURLs(summary: String)
    case unknown(String)

    /// One line, suitable for a row subtitle.
    public var summary: String {
        switch self {
        case .sdkOutdated(let name, let current, let latest):
            "\(name) \(current) → \(latest)"
        case .ingestionWarning(let text), .webVitals(let text), .authorizedURLs(let text):
            text
        case .unknown(let kind):
            kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct HealthIssue: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let kind: HealthIssueKind
    public let severity: HealthIssueSeverity
    public let status: HealthIssueStatus
    public let dismissed: Bool
    public let detail: HealthIssueDetail
    public let createdAt: Date?
    public let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, severity, status, dismissed, payload
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    enum PayloadKeys: String, CodingKey {
        case sdkName = "sdk_name"
        case currentVersion = "current_version"
        case latestVersion = "latest_version"
        case reason, message, metric, summary, description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Ids come back as UUID strings, but a numeric id would decode as a
        // number and throw here — so both are accepted.
        if let string = try? c.decode(String.self, forKey: .id) {
            id = string
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        kind = HealthIssueKind(raw: try c.decodeIfPresent(String.self, forKey: .kind))
        severity = HealthIssueSeverity(raw: try c.decodeIfPresent(String.self, forKey: .severity))
        status = HealthIssueStatus(raw: try c.decodeIfPresent(String.self, forKey: .status))
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        resolvedAt = try c.decodeIfPresent(String.self, forKey: .resolvedAt).flatMap(PostHogDate.parse)

        let payload = try? c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        detail = Self.detail(kind: kind, payload: payload, rawKind: kind == .unknown
            ? (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "unknown"
            : kind.rawValue)
    }

    private static func detail(
        kind: HealthIssueKind,
        payload: KeyedDecodingContainer<PayloadKeys>?,
        rawKind: String
    ) -> HealthIssueDetail {
        func string(_ key: PayloadKeys) -> String? {
            try? payload?.decodeIfPresent(String.self, forKey: key)
        }
        /// First non-empty of several plausible fields. The kinds other than
        /// `sdk_outdated` were not observable in the project this was built
        /// against, so the exact field name is not certain for them — this
        /// takes whichever is present rather than guessing one and showing a
        /// blank row if it guessed wrong.
        func firstText() -> String {
            [string(.summary), string(.message), string(.reason),
             string(.description), string(.metric)]
                .compactMap { $0 }
                .first { !$0.isEmpty }
                ?? rawKind.replacingOccurrences(of: "_", with: " ").capitalized
        }

        switch kind {
        case .sdkOutdated:
            return .sdkOutdated(
                name: string(.sdkName) ?? "SDK",
                current: string(.currentVersion) ?? "?",
                latest: string(.latestVersion) ?? "?"
            )
        case .ingestionWarning: return .ingestionWarning(summary: firstText())
        case .webVitals: return .webVitals(summary: firstText())
        case .authorizedURLs: return .authorizedURLs(summary: firstText())
        case .unknown: return .unknown(rawKind)
        }
    }

    /// Active before resolved, then worst severity first.
    ///
    /// Resolved issues are kept rather than filtered out — "this fixed itself"
    /// is information — but they must never outrank something still broken.
    public static func mostUrgentFirst(_ a: HealthIssue, _ b: HealthIssue) -> Bool {
        let aActive = a.status == .active
        let bActive = b.status == .active
        if aActive != bActive { return aActive }
        return a.severity.rank < b.severity.rank
    }
}

// MARK: - Signal reports

public enum SignalReportStatus: String, Sendable, Hashable {
    case potential, ready, inProgress = "in_progress", resolved, failed
    case unknown

    init(raw: String?) {
        self = raw.flatMap(SignalReportStatus.init(rawValue:)) ?? .unknown
    }

    /// Reports awaiting a decision come first; the rest are history.
    public var rank: Int {
        switch self {
        case .ready: 0
        case .potential: 1
        case .inProgress: 2
        case .failed: 3
        case .resolved: 4
        case .unknown: 5
        }
    }

    public var title: String {
        switch self {
        case .potential: "Potential"
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .resolved: "Resolved"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }
}

/// A finding surfaced by a scheduled scout.
public struct SignalReport: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String?
    public let status: SignalReportStatus
    /// `nil` on roughly half the live rows, and that absence is meaningful —
    /// it means nobody has triaged this yet, which is different from "low".
    public let priority: String?
    public let signalCount: Int
    /// Often more than one: `[error_tracking, github]` is the commonest value
    /// in the live data, so this is a set rather than a scalar.
    public let sourceProducts: [String]
    public let alreadyAddressed: Bool?
    public let implementationPRURL: URL?
    public let implementationPRMerged: Bool
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, status, priority
        case signalCount = "signal_count"
        case sourceProducts = "source_products"
        case alreadyAddressed = "already_addressed"
        case implementationPRURL = "implementation_pr_url"
        case implementationPRMerged = "implementation_pr_merged"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled report"
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        status = SignalReportStatus(raw: try c.decodeIfPresent(String.self, forKey: .status))
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        signalCount = try c.decodeIfPresent(Int.self, forKey: .signalCount) ?? 0
        sourceProducts = try c.decodeIfPresent([String].self, forKey: .sourceProducts) ?? []
        alreadyAddressed = try c.decodeIfPresent(Bool.self, forKey: .alreadyAddressed)
        implementationPRURL = try c.decodeIfPresent(String.self, forKey: .implementationPRURL)
            .flatMap(URL.init(string:))
        implementationPRMerged =
            try c.decodeIfPresent(Bool.self, forKey: .implementationPRMerged) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
    }
}

// MARK: - Tasks

/// The state of a task's most recent agent run.
///
/// Embedded in the list response, so a row can show run state without a second
/// request — the same property that makes the dashboard endpoint cheap.
public struct AgentTaskRun: Sendable, Decodable, Hashable {
    public let status: String?
    public let branch: String?
    public let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case status, branch
        case completedAt = "completed_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
            .flatMap(PostHogDate.parse)
    }
}

/// An item in the Inbox.
///
/// Every task in the project this was built against was filed by an agent —
/// half by a scout, half from a signal report, none by hand. That is what makes
/// this a triage queue rather than a to-do list.
public struct AgentTask: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let description: String?
    public let taskNumber: Int?
    public let originProduct: String?
    /// Absent on half the live rows.
    public let repository: String?
    public let latestRun: AgentTaskRun?
    /// Set on tasks a signal report filed, which is what lets Inbox link back
    /// to the report instead of restating it.
    public let signalReportID: String?
    public let archived: Bool
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, description, repository, archived
        case taskNumber = "task_number"
        case originProduct = "origin_product"
        case latestRun = "latest_run"
        case signalReport = "signal_report"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled task"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        taskNumber = try c.decodeIfPresent(Int.self, forKey: .taskNumber)
        originProduct = try c.decodeIfPresent(String.self, forKey: .originProduct)
        repository = try c.decodeIfPresent(String.self, forKey: .repository)
        latestRun = try c.decodeIfPresent(AgentTaskRun.self, forKey: .latestRun)
        signalReportID = try c.decodeIfPresent(String.self, forKey: .signalReport)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
    }
}
