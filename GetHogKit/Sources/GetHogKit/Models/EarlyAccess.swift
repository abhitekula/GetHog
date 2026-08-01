import Foundation

/// How far along an early access feature is.
///
/// The full choice list from PostHog's `EarlyAccessFeature.Stage`. `draft` is
/// easy to overlook — it is the stage a freshly created feature sits in, so
/// omitting it would classify valid rows as `.unknown`.
public enum EarlyAccessStage: String, Sendable, Hashable, CaseIterable, Identifiable {
    case draft
    case concept
    case alpha
    case beta
    case generalAvailability = "general-availability"
    case archived
    /// Not one of PostHog's choices — where an unrecognised stage lands.
    case unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .draft: "Draft"
        case .concept: "Concept"
        case .alpha: "Alpha"
        case .beta: "Beta"
        case .generalAvailability: "General availability"
        case .archived: "Archived"
        case .unknown: "Unknown stage"
        }
    }

    /// What the stage means for the people opted in, said in words so the pill's
    /// colour is never carrying the meaning by itself.
    public var explanation: String {
        switch self {
        case .draft: "Not yet offered to anyone."
        case .concept: "Gauging interest; opting in does not enable the feature."
        case .alpha: "Opted-in users have the flag enabled."
        case .beta: "Opted-in users have the flag enabled."
        case .generalAvailability: "Rolled out; opting in enables the flag."
        case .archived: "No longer offered."
        case .unknown: "PostHog reported a stage this version doesn't recognise."
        }
    }

    /// Ordered as the lifecycle runs, so a grouped list reads front to back.
    public var order: Int {
        switch self {
        case .draft: 0
        case .concept: 1
        case .alpha: 2
        case .beta: 3
        case .generalAvailability: 4
        case .archived: 5
        case .unknown: 6
        }
    }

    /// The stages a reader can actually opt into, minus `.unknown`.
    public static var known: [EarlyAccessStage] {
        allCases.filter { $0 != .unknown }.sorted { $0.order < $1.order }
    }
}

/// A feature offered for early access, from `GET /early_access_feature/`.
///
/// Note the singular path: PostHog serves `early_access_feature/`, and the
/// pluralised spelling 404s.
public struct EarlyAccessFeature: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let stage: EarlyAccessStage
    public let flagID: Int?
    public let flagKey: String?
    public let flagActive: Bool?
    public let documentationURL: URL?
    public let createdAt: Date?
    public let authorName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, stage
        case featureFlag = "feature_flag"
        case documentationURL = "documentation_url"
        case createdAt = "created_at"
        case createdBy = "created_by"
    }

    private enum FlagKeys: String, CodingKey {
        case id, key, active
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled feature"
        description = (try c.decodeIfPresent(String.self, forKey: .description))
            .flatMap { $0.isEmpty ? nil : $0 }
        stage = (try c.decodeIfPresent(String.self, forKey: .stage))
            .flatMap(EarlyAccessStage.init(rawValue:)) ?? .unknown
        documentationURL = (try c.decodeIfPresent(String.self, forKey: .documentationURL))
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        authorName = c.decodeUserName(forKey: .createdBy)

        // A feature created through the API can exist before its flag does.
        let flag = try? c.nestedContainer(keyedBy: FlagKeys.self, forKey: .featureFlag)
        flagID = (try? flag?.decodeIfPresent(Int.self, forKey: .id)) ?? nil
        flagKey = ((try? flag?.decodeIfPresent(String.self, forKey: .key)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 }
        flagActive = (try? flag?.decodeIfPresent(Bool.self, forKey: .active)) ?? nil
    }
}
