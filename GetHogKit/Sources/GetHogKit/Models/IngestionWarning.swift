import Foundation

/// What kind of ingestion problem a warning is about.
///
/// PostHog documents four values — `size`, `merge`, `event`, `unknown` — which
/// makes this the rare enum whose *quarantine* case is also a value the server
/// ships deliberately. Both land in `.unknown(String)`, and both must render as
/// a phrase rather than as a raw identifier: a category this client has never
/// heard of is attached to a warning that is, by definition, new.
public enum IngestionWarningCategory: Sendable, Hashable {
    case size
    case merge
    case event
    /// Carries the raw string rather than discarding it. The value is what the
    /// filter sends back to the API, so throwing it away would leave a chip
    /// that cannot filter.
    case unknown(String)

    init(raw: String?) {
        switch raw {
        case "size": self = .size
        case "merge": self = .merge
        case "event": self = .event
        case let other: self = .unknown(other ?? "unknown")
        }
    }

    /// The string the API expects back as a `category` filter.
    public var apiValue: String {
        switch self {
        case .size: "size"
        case .merge: "merge"
        case .event: "event"
        case .unknown(let raw): raw
        }
    }

    public var title: String {
        switch self {
        case .size: "Payload size"
        case .merge: "Merges"
        case .event: "Events"
        // The server's own catch-all bucket and an unrecognised value are the
        // same case, so "unknown" gets a word people use and anything else is
        // humanised from its own identifier.
        case .unknown(let raw): raw == "unknown" ? "Uncategorised" : IngestionWarning.humanise(raw)
        }
    }

    /// The categories worth offering as filters.
    ///
    /// Deliberately excludes `unknown`: it is the bucket for everything the
    /// server could not classify, so filtering to it is a debugging move, not a
    /// reading move, and it would sit in the bar competing with the three that
    /// answer a question.
    public static let filterable: [IngestionWarningCategory] = [.merge, .event, .size]
}

/// How bad PostHog thinks a warning is.
public enum IngestionWarningSeverity: Sendable, Hashable {
    case error
    case warning
    case info
    case unknown(String)

    init(raw: String?) {
        switch raw {
        case "error": self = .error
        case "warning": self = .warning
        case "info": self = .info
        case let other: self = .unknown(other ?? "unknown")
        }
    }

    /// Worst first. An unrated severity sorts **last** rather than being guessed
    /// at — PostHog never said it was low, and ranking it as though it had would
    /// bury a warning this client has simply not learned to read yet.
    public var rank: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .info: 2
        case .unknown: 3
        }
    }

    public var title: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .info: "Info"
        case .unknown(let raw): IngestionWarning.humanise(raw)
        }
    }
}

/// How wide a window the sparkline covers.
///
/// PostHog's own note on the response: *"Buckets are hourly for time ranges up
/// to 2 days and daily for wider ranges."* The row carries no bucket field, so
/// the window that asked for it is the only thing that can label the axis — and
/// a sparkline whose x-axis is unlabelled and unknowable is decoration.
public enum IngestionWarningWindow: String, Sendable, Hashable, CaseIterable, Identifiable {
    case twoDays = "-2d"
    case sevenDays = "-7d"
    case thirtyDays = "-30d"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .twoDays: "48 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    public enum Bucket: Sendable, Hashable {
        case hourly
        case daily

        public var title: String {
            switch self {
            case .hourly: "hourly"
            case .daily: "daily"
            }
        }
    }

    public var bucket: Bucket {
        self == .twoDays ? .hourly : .daily
    }
}

/// One row of `GET /api/projects/{id}/ingestion_warnings_v2/`.
///
/// The response is a **bare JSON array**, not a `Page` — see `decodeList`. The
/// server pre-aggregates severity, count, last-seen *and* a sparkline per row,
/// which is what makes this the cheapest genuinely-useful screen in the app: one
/// request, no client-side rollup, and enough to tell whether ingestion broke
/// while you were away from a desk.
///
/// The legacy `/ingestion_warnings/` path is **not** in the catalog: it answers
/// 403 *"This action does not support personal API key access"*, and every
/// credential this app can hold is a personal API key.
public struct IngestionWarning: Sendable, Decodable, Identifiable, Hashable {
    /// The warning's machine name — `cannot_merge_already_identified` and
    /// friends. There is no `id` field; this is the only stable identity a row
    /// has, and PostHog returns each type at most once per response.
    public let type: String
    public let category: IngestionWarningCategory
    public let severity: IngestionWarningSeverity
    public let count: Int
    /// Absent on a warning PostHog has aggregated but not timestamped.
    public let lastSeen: Date?
    /// The server's pre-aggregated buckets, oldest first.
    public let sparkline: [Double]
    /// Kept as a count only. `samples[].details` is keyed by warning type and
    /// carries a different shape for every one of them, so nothing can be said
    /// about it that holds across rows — and a phone has no room for a JSON
    /// dump anyway.
    public let sampleCount: Int

    public var id: String { type }

    enum CodingKeys: String, CodingKey {
        case type, category, severity, count, sparkline, samples
        case lastSeen = "last_seen"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        category = IngestionWarningCategory(raw: try c.decodeIfPresent(String.self, forKey: .category))
        severity = IngestionWarningSeverity(raw: try c.decodeIfPresent(String.self, forKey: .severity))
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen).flatMap(PostHogDate.parse)
        // A null bucket means "no events in that hour", not "this hour is
        // missing". Compacting it away would shorten the series and silently
        // re-date every point after it, which on a 12-bucket sparkline is the
        // difference between "it started last night" and "it started this
        // morning".
        sparkline = (try c.decodeIfPresent([Double?].self, forKey: .sparkline) ?? []).map { $0 ?? 0 }
        sampleCount = (try? c.decodeIfPresent([JSONValue].self, forKey: .samples))??.count ?? 0
    }

    /// Decodes the bare array the endpoint actually returns.
    ///
    /// Named rather than left to the call site because the shape is the trap:
    /// every other collection in this client is a `Page`, and a `Page`-shaped
    /// decode of this response throws — which a screen renders as "couldn't
    /// load" when the truth is "nothing is wrong with your ingestion".
    public static func decodeList(from data: Data) throws -> [IngestionWarning] {
        try JSONDecoder().decode([IngestionWarning].self, from: data)
    }

    /// Whether there is a series worth drawing.
    ///
    /// An all-zero sparkline is drawable and a *fact* — the warning fired
    /// outside this window — but a flat line at zero reads as a rendering
    /// failure, so the view says it in words instead.
    public var hasTrend: Bool {
        sparkline.contains { $0 > 0 }
    }

    /// Human-readable name, derived from the type rather than from a lookup
    /// table this client would have to keep in step with PostHog's.
    public var title: String {
        Self.humanise(type)
    }

    /// Worst severity first, then loudest. Both matter: an `info` firing
    /// 40,000 times is noise, and a single `error` is not.
    public static func mostUrgentFirst(_ a: IngestionWarning, _ b: IngestionWarning) -> Bool {
        if a.severity.rank != b.severity.rank { return a.severity.rank < b.severity.rank }
        if a.count != b.count { return a.count > b.count }
        return a.type < b.type
    }

    /// `cannot_merge_already_identified` → `Cannot merge already identified`.
    static func humanise(_ raw: String) -> String {
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return raw }
        return first.uppercased() + words.dropFirst()
    }
}
