import Foundation

public struct ErrorTrackingResponse: Sendable, Decodable {
    public let issues: [ErrorIssue]

    enum CodingKeys: String, CodingKey { case results }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = (try? c.decodeIfPresent([ErrorIssue].self, forKey: .results)) ?? []
    }

    public static func decode(from data: Data) throws -> ErrorTrackingResponse {
        try JSONDecoder().decode(ErrorTrackingResponse.self, from: data)
    }
}

public struct ErrorIssue: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let issueDescription: String?
    public let status: String
    public let library: String?
    public let function: String?
    public let firstSeen: Date?
    public let lastSeen: Date?

    private let aggregations: Aggregations?

    struct Aggregations: Sendable, Decodable, Hashable {
        let occurrences: Double?
        let sessions: Double?
        let users: Double?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, status, library, function, aggregations
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown error"
        issueDescription = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        library = try c.decodeIfPresent(String.self, forKey: .library)
        function = try c.decodeIfPresent(String.self, forKey: .function)
        firstSeen = try c.decodeIfPresent(String.self, forKey: .firstSeen).flatMap(PostHogDate.parse)
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen).flatMap(PostHogDate.parse)
        aggregations = try? c.decodeIfPresent(Aggregations.self, forKey: .aggregations)
    }

    // Counts live under `aggregations`; the identically-named top-level columns
    // are present but null.
    public var occurrences: Double { aggregations?.occurrences ?? 0 }
    public var sessions: Double { aggregations?.sessions ?? 0 }
    public var users: Double { aggregations?.users ?? 0 }

    public var isResolved: Bool { status == "resolved" }
    public var isSuppressed: Bool { status == "suppressed" }
}
