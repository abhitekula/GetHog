import Foundation

public struct Dashboard: Sendable, Decodable, Identifiable {
    public let id: Int
    public let name: String?
    public let description: String?
    public let pinned: Bool
    public let tiles: [Tile]

    enum CodingKeys: String, CodingKey {
        case id, name, description, pinned, tiles
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        tiles = try c.decodeIfPresent([Tile].self, forKey: .tiles) ?? []
    }

    public static func decode(from data: Data) throws -> Dashboard {
        try JSONDecoder().decode(Dashboard.self, from: data)
    }

    public var title: String { name?.isEmpty == false ? name! : "Untitled dashboard" }
}

/// How a dashboard came to exist.
///
/// Worth surfacing because it separates the dashboards someone made from the
/// ones a feature flag left behind: five of the ten in the test project are
/// `template`, all named "Generated Dashboard: …". Without the distinction the
/// list is mostly by-products.
public enum DashboardCreationMode: String, Sendable, Hashable {
    case `default`
    case template
    case duplicate
    /// PostHog adds modes without notice. An unrecognised one degrades to a
    /// plain row rather than failing the page decode.
    case unknown

    init(raw: String?) {
        self = raw.flatMap(DashboardCreationMode.init(rawValue:)) ?? .unknown
    }
}

/// Summary row from `GET /dashboards/`.
///
/// Deliberately does **not** carry a tile count: the list endpoint does not
/// return `tiles`, verified against the live API, and counting them would cost
/// one request per row. Freshness and provenance are what this row can honestly
/// show instead.
public struct DashboardSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String?
    public let description: String?
    public let pinned: Bool
    /// When the results were last computed. `nil` for a dashboard nobody has
    /// opened — the common case, and one the UI must state as absence rather
    /// than invent a date for.
    public let lastRefresh: Date?
    public let creationMode: DashboardCreationMode
    public let isShared: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, pinned
        case lastRefresh = "last_refresh"
        case creationMode = "creation_mode"
        case isShared = "is_shared"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        lastRefresh = try c.decodeIfPresent(String.self, forKey: .lastRefresh)
            .flatMap(PostHogDate.parse)
        creationMode = DashboardCreationMode(
            raw: try c.decodeIfPresent(String.self, forKey: .creationMode)
        )
        isShared = try c.decodeIfPresent(Bool.self, forKey: .isShared) ?? false
    }

    public var title: String { name?.isEmpty == false ? name! : "Untitled dashboard" }
}

public struct Tile: Sendable, Decodable, Identifiable {
    public let id: Int
    public let order: Int?
    public let color: String?
    public let isCached: Bool
    public let lastRefresh: Date?
    public let insight: Insight?

    enum CodingKeys: String, CodingKey {
        case id, order, color, insight
        case isCached = "is_cached"
        case lastRefresh = "last_refresh"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        isCached = try c.decodeIfPresent(Bool.self, forKey: .isCached) ?? false
        lastRefresh = try c.decodeIfPresent(String.self, forKey: .lastRefresh)
            .flatMap(PostHogDate.parse)
        insight = try c.decodeIfPresent(Insight.self, forKey: .insight)
    }

    public var renderModel: InsightRenderModel {
        insight?.renderModel ?? .unsupported(kind: "Empty")
    }

    public var title: String { insight?.title ?? "Untitled" }
}
