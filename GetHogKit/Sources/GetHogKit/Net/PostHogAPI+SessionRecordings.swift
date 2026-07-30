import Foundation

/// The session-recording list envelope.
///
/// Measured shape: `{"results": [...], "has_next": bool, "version": int}`,
/// plus `next_cursor` on the unfiltered list. There is **no `count`** — the
/// API never says how many recordings match, so no screen may claim a total.
///
/// `Page` would decode this (its `count`/`next`/`previous` are optional) but
/// would drop `has_next`, which is the only thing that says whether another
/// page exists.
public struct RecordingList: Sendable, Decodable {
    public let results: [SessionRecording]
    public let hasNext: Bool
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasNext = "has_next"
        case nextCursor = "next_cursor"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([SessionRecording].self, forKey: .results) ?? []
        hasNext = try c.decodeIfPresent(Bool.self, forKey: .hasNext) ?? false
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    public static func decode(from data: Data) throws -> RecordingList {
        try JSONDecoder().decode(RecordingList.self, from: data)
    }
}

public extension PostHogAPI {

    /// A playlist's **pinned** recordings.
    ///
    /// Measured: this sub-resource returns only what somebody explicitly added
    /// to the playlist. A saved filter pins nothing, so it answers `200` with
    /// `{"results": [], "has_next": false, "version": 4}` — an empty list, not
    /// an error and not an absent endpoint. Reading that as "this playlist is
    /// empty" is the mistake; a saved filter's contents come from running its
    /// stored query instead, via `SessionRecordingPlaylist.recordingFilter`.
    static func playlistRecordings(
        projectID: Int,
        shortID: String,
        limit: Int = 50
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/session_recording_playlists/\(shortID)/recordings/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .analytics
        )
    }
}
