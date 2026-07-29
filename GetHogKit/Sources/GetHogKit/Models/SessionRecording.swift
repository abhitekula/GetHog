import Foundation

public struct SessionRecording: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let distinctID: String?
    public let recordingDuration: Double?
    public let activeSeconds: Double?
    public let startTime: Date?
    public let endTime: Date?
    public let startURL: String?
    public let clickCount: Int
    public let keypressCount: Int
    public let consoleLogCount: Int
    public let consoleWarnCount: Int
    public let consoleErrorCount: Int
    public let snapshotSource: String?
    public let ongoing: Bool
    public let viewed: Bool
    public let person: Person?

    enum CodingKeys: String, CodingKey {
        case id, viewed, ongoing, person
        case distinctID = "distinct_id"
        case recordingDuration = "recording_duration"
        case activeSeconds = "active_seconds"
        case startTime = "start_time"
        case endTime = "end_time"
        case startURL = "start_url"
        case clickCount = "click_count"
        case keypressCount = "keypress_count"
        case consoleLogCount = "console_log_count"
        case consoleWarnCount = "console_warn_count"
        case consoleErrorCount = "console_error_count"
        case snapshotSource = "snapshot_source"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        distinctID = try c.decodeIfPresent(String.self, forKey: .distinctID)
        recordingDuration = try c.decodeIfPresent(Double.self, forKey: .recordingDuration)
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds)
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime).flatMap(PostHogDate.parse)
        endTime = try c.decodeIfPresent(String.self, forKey: .endTime).flatMap(PostHogDate.parse)
        startURL = try c.decodeIfPresent(String.self, forKey: .startURL)
        clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 0
        keypressCount = try c.decodeIfPresent(Int.self, forKey: .keypressCount) ?? 0
        consoleLogCount = try c.decodeIfPresent(Int.self, forKey: .consoleLogCount) ?? 0
        consoleWarnCount = try c.decodeIfPresent(Int.self, forKey: .consoleWarnCount) ?? 0
        consoleErrorCount = try c.decodeIfPresent(Int.self, forKey: .consoleErrorCount) ?? 0
        snapshotSource = try c.decodeIfPresent(String.self, forKey: .snapshotSource)
        ongoing = try c.decodeIfPresent(Bool.self, forKey: .ongoing) ?? false
        viewed = try c.decodeIfPresent(Bool.self, forKey: .viewed) ?? false
        person = try c.decodeIfPresent(Person.self, forKey: .person)
    }

    /// Only web sessions can be handed to the bundled rrweb player — mobile
    /// replay requires a transform PostHog has not open-sourced.
    public var isReplayable: Bool { snapshotSource == "web" }

    public var personDisplayName: String {
        person?.displayName ?? distinctID ?? "Anonymous"
    }

    public var hasErrors: Bool { consoleErrorCount > 0 }

    public var durationText: String {
        let total = Int(recordingDuration ?? 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    public var pathComponent: String {
        guard let startURL, let url = URL(string: startURL) else { return startURL ?? "—" }
        let path = url.path.isEmpty ? "/" : url.path
        return path
    }
}

public struct Person: Sendable, Decodable, Hashable {
    public let id: Int?
    public let uuid: String?
    public let name: String?
    public let distinctIDs: [String]?
    public let properties: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, uuid, name, properties
        case distinctIDs = "distinct_ids"
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let first = distinctIDs?.first { return first }
        return "Anonymous"
    }

    /// Up to two initials for an avatar bubble.
    public var initials: String {
        let source = displayName
        let letters = source.prefix(while: { $0 != "@" })
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
