import Foundation

public struct PersonSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let distinctIDs: [String]
    public let isIdentified: Bool
    public let createdAt: Date?
    public let properties: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, name, properties
        case distinctIDs = "distinct_ids"
        case isIdentified = "is_identified"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is a UUID string on this endpoint but an integer elsewhere.
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            id = String(n)
        } else {
            id = UUID().uuidString
        }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        distinctIDs = (try? c.decodeIfPresent([String].self, forKey: .distinctIDs)) ?? []
        isIdentified = try c.decodeIfPresent(Bool.self, forKey: .isIdentified) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        properties = try? c.decodeIfPresent(JSONValue.self, forKey: .properties)
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return distinctIDs.first ?? "Anonymous"
    }

    public var initials: String {
        let letters = displayName.prefix(while: { $0 != "@" })
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

public struct Cohort: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let count: Int?
    public let isStatic: Bool
    public let cohortType: String?
    public let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, count, deleted
        case isStatic = "is_static"
        case cohortType = "cohort_type"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled cohort"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        isStatic = try c.decodeIfPresent(Bool.self, forKey: .isStatic) ?? false
        cohortType = try c.decodeIfPresent(String.self, forKey: .cohortType)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

public struct Survey: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let type: String
    public let archived: Bool
    public let startDate: Date?
    public let endDate: Date?
    public let questions: [SurveyQuestion]

    enum CodingKeys: String, CodingKey {
        case id, name, description, type, archived, questions
        case startDate = "start_date"
        case endDate = "end_date"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled survey"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "popover"
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate).flatMap(PostHogDate.parse)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate).flatMap(PostHogDate.parse)
        questions = (try? c.decodeIfPresent([SurveyQuestion].self, forKey: .questions)) ?? []
    }

    /// Launched and not yet stopped. A survey with no start date was never run.
    public var isRunning: Bool {
        guard let startDate, startDate <= Date() else { return false }
        if let endDate, endDate <= Date() { return false }
        return !archived
    }

    public var statusText: String {
        if archived { return "Archived" }
        if isRunning { return "Running" }
        return startDate == nil ? "Draft" : "Stopped"
    }
}

public struct SurveyQuestion: Sendable, Decodable, Hashable {
    public let type: String?
    public let question: String?
    public let choices: [String]?
}

public struct Experiment: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let featureFlagKey: String?
    public let startDate: Date?
    public let endDate: Date?
    public let archived: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, archived
        case featureFlagKey = "feature_flag_key"
        case startDate = "start_date"
        case endDate = "end_date"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled experiment"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        featureFlagKey = try c.decodeIfPresent(String.self, forKey: .featureFlagKey)
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate).flatMap(PostHogDate.parse)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate).flatMap(PostHogDate.parse)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    public var statusText: String {
        if archived { return "Archived" }
        if endDate != nil { return "Complete" }
        if startDate != nil { return "Running" }
        return "Draft"
    }
}

/// Row from `GET /insights/` — the saved insight library, independent of dashboards.
public struct InsightSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String?
    public let derivedName: String?
    public let favorited: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, favorited
        case derivedName = "derived_name"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        derivedName = try c.decodeIfPresent(String.self, forKey: .derivedName)
        favorited = try c.decodeIfPresent(Bool.self, forKey: .favorited) ?? false
    }

    public var title: String {
        if let name, !name.isEmpty { return name }
        if let derivedName, !derivedName.isEmpty { return derivedName }
        return "Untitled insight"
    }
}
