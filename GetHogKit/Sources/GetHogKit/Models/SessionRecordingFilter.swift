import Foundation

/// Server-side narrowing for the session-recording list.
///
/// ## What the API accepts
///
/// Two transports validate against the same public filter model:
///
///     GET  /api/projects/:id/session_recordings/     ← used
///     POST /api/projects/:id/query/  {"kind":"RecordingsQuery"}
///
/// The GET form is used because it hydrates the person row, participates in the
/// analytics request budget, and pages cursor-first (`next_cursor` to `after`)
/// with offset as a compatibility fallback for older/self-hosted responses.
///
/// Fields represented by the model:
///
///     date_from, date_to, events, actions, properties, console_log_filters,
///     having_predicates, filter_test_accounts, operand, session_ids,
///     person_uuid, distinct_ids, limit, offset, after, order, order_direction,
///     user_modified_filters, modifiers, response, tags, version
///
/// `order` is an enum of exactly: `duration`, `recording_duration`,
/// `inactive_seconds`, `active_seconds`, `start_time`, `console_error_count`,
/// `click_count`, `keypress_count`, `mouse_activity_count`, `activity_score`,
/// `recording_ttl`, `surfacing_score`. `order_direction` is `ASC` or `DESC`.
///
/// ## The operand trap
///
/// `operand` applies to the complete filter group rather than one signal.
///
/// So this type offers no OR at all, and `signal` is single-valued. A phone UI
/// that let you tick "rage clicks" *and* "dead clicks" would have to send OR,
/// and would then quietly discard the person and console filters sitting next
/// to it on the same sheet. One signal at a time is the honest shape.
public struct SessionRecordingFilter: Sendable, Hashable, Equatable {

    // MARK: - Vocabulary

    /// Wall-clock length and time actually spent interacting are different
    /// numbers on the same recording — a 34-minute session with 40 active
    /// seconds is a real and common shape — and the API keys them separately.
    public enum DurationMetric: String, Sendable, Hashable, CaseIterable, Codable {
        case total = "duration"
        case active = "active_seconds"

        public var title: String {
            switch self {
            case .total: "Total length"
            case .active: "Active time"
            }
        }
    }

    /// How the duration floor compares.
    ///
    /// Two values because two callers disagree, and both are right:
    ///
    /// * The sheet's own picker offers "30 seconds", "2 minutes" and so on, and
    ///   the client-side picker it replaces dropped a recording when its
    ///   duration was **less than** the choice — so an exactly-30-second
    ///   recording was kept. That is `gte`.
    /// * A saved filter made in the web console stores `gt`. Translating it to
    ///   `gte` would run a filter one recording wider than the one whose name
    ///   is on the screen, so the stored operator is carried through.
    ///
    /// The API accepts both values; this UI intentionally exposes only the two
    /// comparisons it can explain clearly.
    public enum DurationComparison: String, Sendable, Hashable, CaseIterable, Codable {
        case atLeast = "gte"
        case greaterThan = "gt"
    }

    /// The one thing that went wrong, chosen from a list rather than ticked in
    /// combination — see the operand note above.
    public enum Signal: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
        case rageClick
        case deadClick
        case exception
        case consoleError

        public var id: String { rawValue }

        /// The autocaptured event behind the signal, or `nil` when the signal
        /// is not an event at all.
        public var eventName: String? {
            switch self {
            case .rageClick: "$rageclick"
            case .deadClick: "$dead_click"
            case .exception: "$exception"
            case .consoleError: nil
            }
        }

        public var title: String {
            switch self {
            case .rageClick: "Rage clicks"
            case .deadClick: "Dead clicks"
            case .exception: "Exceptions"
            case .consoleError: "Console errors"
            }
        }

        public var systemImage: String {
            switch self {
            case .rageClick: "hand.tap.fill"
            case .deadClick: "hand.raised.slash.fill"
            case .exception: "exclamationmark.octagon.fill"
            case .consoleError: "exclamationmark.triangle.fill"
            }
        }
    }

    /// Only the orders that mean something in a list of sessions. The API
    /// accepts twelve; the rest — `recording_ttl`, `surfacing_score`,
    /// `inactive_seconds` — sort by things this screen does not show.
    public enum Order: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
        case startTime = "start_time"
        case duration
        case activeSeconds = "active_seconds"
        case consoleErrorCount = "console_error_count"
        case clickCount = "click_count"
        case activityScore = "activity_score"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .startTime: "Most recent"
            case .duration: "Longest"
            case .activeSeconds: "Most active time"
            case .consoleErrorCount: "Most errors"
            case .clickCount: "Most clicks"
            case .activityScore: "Busiest"
            }
        }
    }

    /// Date windows resolved server-side. Relative choices stay relative so
    /// the client and server cannot disagree about the project's timezone.
    /// "Any time" is explicit too: omitting `date_from` asks PostHog for its
    /// three-day default, which is not what that label promises. An epoch lower
    /// bound means every recording the project's retention policy still holds.
    public enum DateWindow: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
        case allTime
        case last24Hours
        case last3Days
        case last7Days
        case last30Days
        case last90Days

        public var id: String { rawValue }

        public var relativeDate: String? {
            switch self {
            case .allTime: "1970-01-01T00:00:00Z"
            case .last24Hours: "-24h"
            case .last3Days: "-3d"
            case .last7Days: "-7d"
            case .last30Days: "-30d"
            case .last90Days: "-90d"
            }
        }

        public var title: String {
            switch self {
            case .allTime: "Any time"
            case .last24Hours: "Last 24 hours"
            case .last3Days: "Last 3 days"
            case .last7Days: "Last 7 days"
            case .last30Days: "Last 30 days"
            case .last90Days: "Last 90 days"
            }
        }

        init?(relativeDate: String) {
            guard let match = Self.allCases.first(where: { $0.relativeDate == relativeDate })
            else { return nil }
            self = match
        }
    }

    /// Which recorder produced the session. The list already tells you a mobile
    /// recording cannot be played here; this is how you stop being shown them.
    public enum Source: String, Sendable, Hashable, CaseIterable, Codable {
        case web
        case mobile

        public var title: String {
            switch self {
            case .web: "Web (playable)"
            case .mobile: "Mobile"
            }
        }
    }

    /// A property clause carried through verbatim from a saved filter.
    ///
    /// Saved filters reference person properties this app has no picker for —
    /// `$initial_utm_source`, `$geoip_country_code`. Dropping them would run a
    /// *different* query than the one the name promises, so they are kept and
    /// re-encoded unchanged.
    public struct PropertyClause: Sendable, Hashable, Codable {
        public var key: String
        public var type: String
        public var value: JSONValue?
        public var op: String?

        enum CodingKeys: String, CodingKey {
            case key, type, value
            case op = "operator"
        }

        public init(key: String, type: String, value: JSONValue?, op: String?) {
            self.key = key
            self.type = type
            self.value = value
            self.op = op
        }
    }

    // MARK: - State

    public var dateWindow: DateWindow = .allTime
    /// Seconds. `nil` or `0` means no floor.
    public var minimumDuration: Double?
    public var durationMetric: DurationMetric = .total
    public var durationComparison: DurationComparison = .atLeast
    public var signal: Signal?
    public var source: Source?
    /// Whether PostHog should apply the project's internal and test-user filters.
    public var filterTestAccounts = false
    /// Free text matched against the person's email, case-insensitively.
    ///
    /// Email only. Matching email *or* name would need `operand=OR`, which —
    /// measured — would also OR away the signal and duration clauses beside it.
    /// The field says "email" for that reason rather than promising "person".
    public var personSearch: String?
    /// Free text matched against the page URL the session was on.
    ///
    /// Measured as an **event** property (`$current_url`), not a recording
    /// column: `having_predicates` with `start_url` matched nothing at any
    /// value tried, including ones known to be present.
    public var urlSearch: String?
    public var distinctIDs: [String] = []
    public var order: Order = .startTime
    /// Clauses inherited from a saved filter that have no control on the sheet.
    public var inheritedProperties: [PropertyClause] = []

    public init() {}

    // MARK: - Encoding

    /// The filter as query items. The date is always present because PostHog's
    /// absent value means three days rather than all retained recordings.
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []

        if let date = dateWindow.relativeDate {
            items.append(URLQueryItem(name: "date_from", value: date))
        }

        if filterTestAccounts {
            items.append(URLQueryItem(name: "filter_test_accounts", value: "true"))
        }

        // Duration floor and recorder are both HAVING clauses and share one
        // parameter — assembled together so neither can overwrite the other.
        let having = havingPredicates
        if !having.isEmpty {
            items.append(URLQueryItem(name: "having_predicates", value: encode(having)))
        }

        if let event = signal?.eventName {
            items.append(URLQueryItem(
                name: "events",
                value: encode([["id": event, "name": event, "type": "events", "order": 0]])
            ))
        }

        if signal == .consoleError {
            items.append(URLQueryItem(
                name: "console_log_filters",
                value: encode([[
                    "key": "level", "type": "log_entry",
                    "value": ["error"], "operator": "exact",
                ]])
            ))
        }

        var properties: [[String: Any]] = []
        if let term = trimmedPersonSearch {
            properties.append([
                "key": "email", "type": "person",
                "value": term, "operator": "icontains",
            ])
        }
        if let term = trimmedURLSearch {
            properties.append([
                "key": "$current_url", "type": "event",
                "value": term, "operator": "icontains",
            ])
        }
        properties.append(contentsOf: inheritedProperties.map(dictionary(for:)))
        if !properties.isEmpty {
            items.append(URLQueryItem(name: "properties", value: encode(properties)))
        }

        if !distinctIDs.isEmpty {
            items.append(URLQueryItem(name: "distinct_ids", value: encode(distinctIDs)))
        }

        // Only when it differs from PostHog's own default, so the common
        // request stays as small as it was.
        if order != .startTime {
            items.append(URLQueryItem(name: "order", value: order.rawValue))
        }

        return items
    }

    /// Duration and snapshot source are both `HAVING` clauses on the recording
    /// row, and both survive `operand` — which is why they are safe to combine
    /// with anything else on the sheet.
    private var durationPredicate: [String: Any]? {
        guard let minimumDuration, minimumDuration > 0 else { return nil }
        return [
            "key": durationMetric.rawValue,
            "type": "recording",
            "value": minimumDuration,
            "operator": durationComparison.rawValue,
        ]
    }

    private var sourcePredicate: [String: Any]? {
        guard let source else { return nil }
        return [
            "key": "snapshot_source",
            "type": "recording",
            "value": [source.rawValue],
            "operator": "exact",
        ]
    }

    public var trimmedPersonSearch: String? { Self.trim(personSearch) }
    public var trimmedURLSearch: String? { Self.trim(urlSearch) }

    private static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func dictionary(for clause: PropertyClause) -> [String: Any] {
        var out: [String: Any] = ["key": clause.key, "type": clause.type]
        if let op = clause.op { out["operator"] = op }
        if let value = clause.value, let raw = try? JSONEncoder().encode(value),
           let any = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) {
            out["value"] = any
        }
        return out
    }

    private func encode(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Summary

    /// How many narrowings are in force. Sort order is not one: it changes the
    /// order of the answer, not which sessions are in it, and counting it would
    /// badge the toolbar for a screen showing everything.
    public var activeCount: Int {
        var count = 0
        if dateWindow != .allTime { count += 1 }
        if let minimumDuration, minimumDuration > 0 { count += 1 }
        if signal != nil { count += 1 }
        if source != nil { count += 1 }
        if filterTestAccounts { count += 1 }
        if trimmedPersonSearch != nil { count += 1 }
        if trimmedURLSearch != nil { count += 1 }
        if !distinctIDs.isEmpty { count += 1 }
        count += inheritedProperties.count
        return count
    }

    public var isNarrowed: Bool { activeCount > 0 }

    public mutating func clear() { self = SessionRecordingFilter() }
}

// MARK: - Source predicate folded into having_predicates

extension SessionRecordingFilter {
    /// `having_predicates` carries both the duration floor and the recorder,
    /// so they are assembled together rather than overwriting one another.
    var havingPredicates: [[String: Any]] {
        [durationPredicate, sourcePredicate].compactMap { $0 }
    }
}
