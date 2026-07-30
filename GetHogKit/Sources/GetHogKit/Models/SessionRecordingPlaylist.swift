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

    /// Row subtitle. Says the count is missing rather than printing a zero the
    /// API never claimed.
    public var countSummary: String {
        guard let recordingCount else { return "Count not reported" }
        let recordings = "\(recordingCount) recording\(recordingCount == 1 ? "" : "s")"
        guard let watchedCount else { return recordings }
        return "\(recordings) · \(watchedCount) watched"
    }
}
