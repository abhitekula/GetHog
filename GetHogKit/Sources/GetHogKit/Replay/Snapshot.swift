import Foundation

/// Response from the snapshot endpoint called with no parameters: the list of
/// places this recording's data can be loaded from.
///
/// PostHog documents this API as internal and subject to change without notice,
/// so everything here is deliberately tolerant and isolated from the rest of the
/// app — a break must degrade the player only.
public struct SnapshotSourceListing: Sendable, Decodable {
    public let sources: [SnapshotSource]

    public static func decode(from data: Data) throws -> SnapshotSourceListing {
        try JSONDecoder().decode(SnapshotSourceListing.self, from: data)
    }

    /// Blob keys in numeric order, chunked into request-sized ranges.
    ///
    /// The endpoint caps a request at 20 blobs and rejects a lone `blob_key` for
    /// `blob_v2` ("Must provide both start blob key and end blob key"), so every
    /// request is expressed as a range.
    public func blobRanges(maxPerRequest: Int = 20) -> [BlobRange] {
        let keys = sources
            .filter { $0.source == "blob_v2" }
            .compactMap { Int($0.blobKey ?? "") }
            .sorted()

        guard !keys.isEmpty, maxPerRequest > 0 else { return [] }

        return stride(from: 0, to: keys.count, by: maxPerRequest).map { offset in
            let slice = keys[offset..<min(offset + maxPerRequest, keys.count)]
            return BlobRange(start: String(slice.first!), end: String(slice.last!))
        }
    }

    public var isRealtimeOnly: Bool {
        !sources.isEmpty && sources.allSatisfy { $0.source == "realtime" }
    }
}

public struct SnapshotSource: Sendable, Decodable, Hashable {
    public let source: String
    public let blobKey: String?
    public let startTimestamp: Date?
    public let endTimestamp: Date?

    enum CodingKeys: String, CodingKey {
        case source
        case blobKey = "blob_key"
        case startTimestamp = "start_timestamp"
        case endTimestamp = "end_timestamp"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        blobKey = try c.decodeIfPresent(String.self, forKey: .blobKey)
        startTimestamp = try c.decodeIfPresent(String.self, forKey: .startTimestamp)
            .flatMap(PostHogDate.parse)
        endTimestamp = try c.decodeIfPresent(String.self, forKey: .endTimestamp)
            .flatMap(PostHogDate.parse)
    }
}

public struct BlobRange: Sendable, Hashable {
    public let start: String
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

/// One rrweb event, tagged with the browser window it belongs to.
public struct SnapshotEvent: Sendable, Equatable {
    public let windowID: String
    public let type: Int
    public let timestamp: Double
    /// The complete rrweb event object, forwarded verbatim to the player.
    public let event: JSONValue

    public init(windowID: String, type: Int, timestamp: Double, event: JSONValue) {
        self.windowID = windowID
        self.type = type
        self.timestamp = timestamp
        self.event = event
    }

    /// rrweb event type 2 — a full DOM snapshot, required to start playback.
    public var isFullSnapshot: Bool { type == 2 }
}

public enum SnapshotParser {
    /// Parses the endpoint's `application/jsonl` body.
    ///
    /// Each line is `[windowId, rrwebEvent]`. Malformed lines are skipped rather
    /// than failing the batch: one bad line should not cost the whole replay.
    public static func parse(jsonl data: Data) throws -> [SnapshotEvent] {
        let decoder = JSONDecoder()
        var events: [SnapshotEvent] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty else { continue }
            guard let pair = try? decoder.decode([JSONValue].self, from: Data(line)),
                  pair.count >= 2,
                  let windowID = pair[0].stringValue
            else { continue }

            let event = pair[1]
            guard let type = event["type"]?.intValue,
                  let timestamp = event["timestamp"]?.doubleValue
            else { continue }

            events.append(
                SnapshotEvent(windowID: windowID, type: type, timestamp: timestamp, event: event)
            )
        }
        return events
    }
}
