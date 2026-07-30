import Foundation

/// The level PostHog assigned to an SDK, or to the project as a whole.
///
/// Open-ended for the same reason `HealthIssueKind` is, and for a sharper one:
/// PostHog already spells this idea two ways in its own API — the report's
/// `health` says `danger` where an issue's `severity` says `critical` — so both
/// vocabularies are carried here as distinct cases rather than aliased into one.
/// Aliasing would be the first step towards re-deriving the verdict, and the
/// whole point of this endpoint is that the judgement has already been made
/// server-side, with grace periods, minor-count thresholds and traffic shares
/// this client cannot see.
public enum SDKHealthLevel: Sendable, Hashable {
    case healthy
    case info
    case warning
    case danger
    case critical
    /// A level this client has never seen, kept verbatim.
    case unknown(String)

    init(raw: String?) {
        switch raw?.lowercased() {
        case "healthy": self = .healthy
        case "info": self = .info
        case "warning": self = .warning
        case "danger": self = .danger
        case "critical": self = .critical
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }

    /// Worst first.
    ///
    /// `.unknown` sits behind the two definitely-bad levels and ahead of
    /// `warning`: it might be worse than critical or milder than info, and of the
    /// two ways to be wrong, ranking it too high costs a reader one glance while
    /// ranking it too low buries the thing this quarantine exists to surface.
    public var rank: Int {
        switch self {
        case .critical: 0
        case .danger: 1
        case .unknown: 2
        case .warning: 3
        case .info: 4
        case .healthy: 5
        }
    }

    /// PostHog's word, not a translation of it.
    public var title: String {
        switch self {
        case .healthy: "Healthy"
        case .info: "Info"
        case .warning: "Warning"
        case .danger: "Danger"
        case .critical: "Critical"
        case .unknown(let raw):
            // Absent is not a level. Saying "Healthy" here would be a claim the
            // response never made.
            raw.isEmpty ? "Not reported" : ResourceKeyTitle.humanise(raw)
        }
    }

    /// Whether this level should draw attention.
    ///
    /// `.unknown` counts as concerning. PostHog adds levels when it has
    /// something new to warn about, so reading an unrecognised one as "fine"
    /// fails in exactly the direction that matters.
    public var isConcerning: Bool {
        switch self {
        case .healthy, .info: false
        case .warning, .danger, .critical, .unknown: true
        }
    }

    /// Paired with `title` everywhere it is drawn, so severity is never carried
    /// by colour alone.
    public var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger, .critical: "exclamationmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

/// The report's `overall_health` — a separate vocabulary from the levels above.
public enum SDKHealthVerdict: Sendable, Hashable {
    case healthy
    case needsAttention
    case unknown(String)

    init(raw: String?) {
        switch raw?.lowercased() {
        case "healthy": self = .healthy
        case "needs_attention": self = .needsAttention
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }

    public var title: String {
        switch self {
        case .healthy: "Healthy"
        case .needsAttention: "Needs attention"
        case .unknown(let raw):
            raw.isEmpty ? "Not reported" : ResourceKeyTitle.humanise(raw)
        }
    }

    /// Only an explicit `healthy` clears. An unrecognised verdict does not.
    public var isClear: Bool { self == .healthy }
}

/// One SDK's row in the report.
public struct SDKHealthEntry: Sendable, Decodable, Hashable, Identifiable {
    public let name: String
    public let severity: SDKHealthLevel
    public let health: SDKHealthLevel
    public let currentVersion: String?
    public let latestVersion: String?
    public let isOutdated: Bool
    /// PostHog's written explanation — "Latest in-use version 5.28.5 is behind
    /// 5.46.1… Outdated versions still handling >= 10% of traffic: 5.28.5."
    /// Shown verbatim; a paraphrase would be a second, quieter judgement.
    public let reason: String?
    /// Often empty, and empty is normal for a healthy SDK.
    public let banners: [String]

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case severity, health, reason, banners, name
        case sdkName = "sdk_name"
        case currentVersion = "current_version"
        case latestVersion = "latest_version"
        case isOutdated = "is_outdated"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .sdkName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? "SDK"
        severity = SDKHealthLevel(raw: try c.decodeIfPresent(String.self, forKey: .severity))
        health = SDKHealthLevel(raw: try c.decodeIfPresent(String.self, forKey: .health))
        currentVersion = try c.decodeIfPresent(String.self, forKey: .currentVersion)
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        isOutdated = try c.decodeIfPresent(Bool.self, forKey: .isOutdated) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        banners = try c.decodeIfPresent([String].self, forKey: .banners) ?? []
    }

    public static func worstFirst(_ a: SDKHealthEntry, _ b: SDKHealthEntry) -> Bool {
        if a.severity.rank != b.severity.rank { return a.severity.rank < b.severity.rank }
        return a.name < b.name
    }
}

/// `GET /api/projects/{id}/sdk_health/report/`.
///
/// Pre-digested server-side: PostHog has already applied its grace periods,
/// minor-count thresholds, age rules and traffic shares, and returns the verdict
/// plus the sentence behind it. So this is one card rather than a table, and
/// nothing here recomputes a severity — a client that did would sooner or later
/// disagree with the web console, and the console is what the user will check.
public struct SDKHealthReport: Sendable, Decodable, Hashable {
    public let verdict: SDKHealthVerdict
    public let level: SDKHealthLevel
    /// The server's count. The card leads with this rather than with
    /// `flagged.count`, so the headline number is PostHog's own.
    public let needsUpdatingCount: Int
    /// Worst first.
    public let sdks: [SDKHealthEntry]
    public let reason: String?
    public let banners: [String]

    /// The rows worth drawing. Decides what is rendered, never what is claimed —
    /// the headline number stays `needsUpdatingCount`.
    public var flagged: [SDKHealthEntry] {
        sdks.filter { $0.severity.isConcerning }
    }

    enum CodingKeys: String, CodingKey {
        case health, reason, banners, sdks, results
        case overallHealth = "overall_health"
        case needsUpdatingCount = "needs_updating_count"
        case sdkVersions = "sdk_versions"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = SDKHealthVerdict(raw: try c.decodeIfPresent(String.self, forKey: .overallHealth))
        level = SDKHealthLevel(raw: try c.decodeIfPresent(String.self, forKey: .health))
        needsUpdatingCount = try c.decodeIfPresent(Int.self, forKey: .needsUpdatingCount) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        banners = try c.decodeIfPresent([String].self, forKey: .banners) ?? []

        // The container key for the per-SDK rows is the one part of this payload
        // that could not be pinned from the observation the card was built
        // against. Guessing one and being wrong renders an empty card against a
        // project that has two flagged SDKs — a failure that looks exactly like
        // good news — so the plausible spellings are all accepted and the
        // alternates are covered by a test, which makes a future correction a
        // one-line change.
        var rows: [SDKHealthEntry] = []
        for key in [CodingKeys.sdks, .results, .sdkVersions] {
            if let found = try? c.decodeIfPresent([SDKHealthEntry].self, forKey: key), !found.isEmpty {
                rows = found
                break
            }
        }
        sdks = rows.sorted(by: SDKHealthEntry.worstFirst)
    }

    public static func decode(from data: Data) throws -> SDKHealthReport {
        try JSONDecoder().decode(SDKHealthReport.self, from: data)
    }
}
