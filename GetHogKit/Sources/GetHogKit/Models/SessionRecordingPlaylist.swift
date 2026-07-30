import Foundation

/// What a playlist is: a hand-curated collection, or a saved set of filters.
public enum PlaylistKind: String, Sendable, Hashable, CaseIterable {
    case collection
    case filters
    case unknown

    public var title: String {
        switch self {
        case .collection: "Collection"
        case .filters: "Saved filter"
        case .unknown: "Playlist"
        }
    }

    public var systemImage: String {
        switch self {
        case .collection: "rectangle.stack"
        case .filters: "line.3.horizontal.decrease.circle"
        case .unknown: "questionmark.square"
        }
    }

    public init(raw: String?) {
        self = PlaylistKind(rawValue: raw?.lowercased() ?? "") ?? .unknown
    }
}

/// A replay playlist from `GET /session_recording_playlists/`.
///
/// PostHog injects **synthetic** playlists into this page — "Watch history",
/// "Frustration signals" and friends — carrying negative `id` values, a null
/// `created_at` and a null `created_by`. Two consequences shape this type:
///
/// 1. Identity keys off `short_id`, the stable string the console itself routes
///    on, not the numeric id.
/// 2. Every field the synthetic rows null out is optional. A non-optional decode
///    of `created_at` throws on the very first row and empties the whole screen.
public struct SessionRecordingPlaylist: Sendable, Decodable, Identifiable, Hashable {
    public var id: String { shortID }

    public let shortID: String
    public let numericID: Int?
    public let name: String
    public let description: String?
    public let pinned: Bool
    public let isSynthetic: Bool
    public let kind: PlaylistKind
    public let createdAt: Date?
    public let lastModifiedAt: Date?
    public let authorName: String?
    /// Nil when PostHog has not counted this playlist yet — which is the normal
    /// state for a saved filter until it is refreshed.
    public let recordingCount: Int?
    public let watchedCount: Int?
    public let filters: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, name, description, pinned, type, filters
        case shortID = "short_id"
        case derivedName = "derived_name"
        case createdAt = "created_at"
        case createdBy = "created_by"
        case lastModifiedAt = "last_modified_at"
        case isSynthetic = "is_synthetic"
        case recordingsCounts = "recordings_counts"
    }

    private enum CountsKeys: String, CodingKey {
        case collection
        case savedFilters = "saved_filters"
    }

    private struct Bucket: Decodable {
        let count: Int?
        let watchedCount: Int?

        enum CodingKeys: String, CodingKey {
            case count
            case watchedCount = "watched_count"
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        numericID = try c.decodeIfPresent(Int.self, forKey: .id)
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID)
            ?? numericID.map(String.init)
            ?? UUID().uuidString

        let given = (try c.decodeIfPresent(String.self, forKey: .name))
            .flatMap { $0.isEmpty ? nil : $0 }
        let derived = (try c.decodeIfPresent(String.self, forKey: .derivedName))
            .flatMap { $0.isEmpty ? nil : $0 }
        name = given ?? derived ?? "Untitled playlist"

        description = (try c.decodeIfPresent(String.self, forKey: .description))
            .flatMap { $0.isEmpty ? nil : $0 }
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        isSynthetic = try c.decodeIfPresent(Bool.self, forKey: .isSynthetic) ?? false
        kind = PlaylistKind(raw: try c.decodeIfPresent(String.self, forKey: .type))
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        lastModifiedAt = try c.decodeIfPresent(String.self, forKey: .lastModifiedAt)
            .flatMap(PostHogDate.parse)
        authorName = c.decodeUserName(forKey: .createdBy)
        filters = (try? c.decodeIfPresent(JSONValue.self, forKey: .filters)) ?? nil

        // Counts live in two buckets and only the one matching `type` is filled
        // in. Reading the wrong bucket reports a populated saved filter as empty.
        let counts = try? c.nestedContainer(keyedBy: CountsKeys.self, forKey: .recordingsCounts)
        let collection = (try? counts?.decodeIfPresent(Bucket.self, forKey: .collection)) ?? nil
        let saved = (try? counts?.decodeIfPresent(Bucket.self, forKey: .savedFilters)) ?? nil
        let bucket: Bucket? = switch kind {
        case .collection: collection
        case .filters: saved
        case .unknown: collection ?? saved
        }
        recordingCount = bucket?.count
        watchedCount = bucket?.watchedCount
    }

    /// Fraction watched, only when the total is actually known.
    public var watchedProgress: Double? {
        guard let recordingCount, recordingCount > 0, let watchedCount else { return nil }
        return Double(watchedCount) / Double(recordingCount)
    }

    /// The stored query behind a **saved filter**, translated into something
    /// the recordings endpoint accepts. `nil` for a collection, which has no
    /// query at all — its contents are the rows somebody pinned.
    ///
    /// That distinction is the whole reason this property is optional rather
    /// than defaulted: a collection and a saved filter are fetched by
    /// completely different means, and a type that produced a filter for both
    /// would send an empty query for a collection and quietly return the whole
    /// project.
    ///
    /// The stored blob is the web console's own legacy filter shape, and it does
    /// not match the API's input schema. Three mismatches, all measured:
    ///
    /// * `date_to` is the four-character **string** `"null"`, not JSON null.
    ///   Forwarded verbatim it is a 400.
    /// * `filter_test_accounts` is the string `"true"`, not a bool.
    /// * `filter_group` is not an accepted input field at all; its leaves have
    ///   to be sorted into `properties`, `console_log_filters` and
    ///   `having_predicates` by their own `type`.
    public var recordingFilter: SessionRecordingFilter? {
        guard kind == .filters, let filters else { return nil }
        var out = SessionRecordingFilter()

        if let raw = filters["date_from"]?.stringValue,
           let window = SessionRecordingFilter.DateWindow(relativeDate: raw) {
            out.dateWindow = window
        }

        // `duration` is an array of recording-level clauses keyed by which
        // duration they mean — wall clock or active time.
        if case .array(let clauses)? = filters["duration"] {
            for case .object(let clause) in clauses {
                guard let key = clause["key"]?.stringValue,
                      let metric = SessionRecordingFilter.DurationMetric(rawValue: key),
                      case .number(let value)? = clause["value"]
                else { continue }
                out.durationMetric = metric
                out.minimumDuration = value
                // Carried rather than defaulted: the console stores `gt` and
                // this app's own picker means `gte`, and running the wrong one
                // makes the saved filter's list a recording wider than its name.
                if let stored = clause["operator"]?.stringValue,
                   let comparison = SessionRecordingFilter.DurationComparison(rawValue: stored) {
                    out.durationComparison = comparison
                }
            }
        }

        if case .array(let events)? = filters["events"] {
            for case .object(let event) in events {
                guard let id = event["id"]?.stringValue,
                      let signal = SessionRecordingFilter.Signal.allCases.first(
                          where: { $0.eventName == id }
                      )
                else { continue }
                out.signal = signal
            }
        }

        for leaf in Self.leaves(of: filters["filter_group"]) {
            apply(leaf, to: &out)
        }

        if let raw = filters["order"]?.stringValue,
           let order = SessionRecordingFilter.Order(rawValue: raw) {
            out.order = order
        }

        return out
    }

    /// Clauses in the stored filter that `recordingFilter` deliberately does
    /// **not** apply, named so a screen can say the query it ran is wider than
    /// the one the playlist describes.
    ///
    /// Silence here would be the dangerous option: an untranslated clause makes
    /// the result *larger*, and a saved filter showing more than it should looks
    /// exactly like one working correctly.
    public var untranslatedClauses: [String] {
        guard kind == .filters, let filters else { return [] }
        return Self.leaves(of: filters["filter_group"]).compactMap { leaf in
            guard let key = leaf["key"]?.stringValue else { return nil }
            guard leaf["type"]?.stringValue == "log_entry", key != "level" else { return nil }
            return "console \(key)"
        }
    }

    /// `filter_group` nests `{type, values}` to an arbitrary depth; the leaves
    /// are the objects carrying a `key`.
    private static func leaves(of node: JSONValue?) -> [[String: JSONValue]] {
        guard case .object(let object)? = node else { return [] }
        if object["key"] != nil { return [object] }
        guard case .array(let values)? = object["values"] else { return [] }
        return values.flatMap { leaves(of: $0) }
    }

    private func apply(
        _ leaf: [String: JSONValue],
        to filter: inout SessionRecordingFilter
    ) {
        guard let key = leaf["key"]?.stringValue else { return }
        let type = leaf["type"]?.stringValue ?? "person"
        let op = leaf["operator"]?.stringValue

        switch type {
        case "log_entry":
            // Only the level clause has a control on the sheet. The console
            // *message* clause is deliberately not translated: PostHog's own
            // "5+ console log errors" saved filter stores
            // `{key: message, operator: gt, value: "5"}`, which the API accepts
            // and which matches nothing — measured, it turns a filter with 3
            // real results into 0. Reproducing it would reproduce the fault.
            if key == "level", case .array(let levels)? = leaf["value"],
               levels.contains(where: { $0.stringValue == "error" }) {
                filter.signal = .consoleError
            }
        case "recording":
            if key == "snapshot_source", case .array(let sources)? = leaf["value"],
               let raw = sources.first?.stringValue,
               let source = SessionRecordingFilter.Source(rawValue: raw) {
                filter.source = source
            }
        default:
            filter.inheritedProperties.append(
                SessionRecordingFilter.PropertyClause(
                    key: key, type: type, value: leaf["value"], op: op
                )
            )
        }
    }

    /// Row subtitle. Says the count is missing rather than printing a zero the
    /// API never claimed.
    public var countSummary: String {
        guard let recordingCount else { return "Count not reported" }
        let recordings = "\(recordingCount) recording\(recordingCount == 1 ? "" : "s")"
        guard let watchedCount else { return recordings }
        return "\(recordings) · \(watchedCount) watched"
    }
}
