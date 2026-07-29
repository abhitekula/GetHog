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

/// Summary row from `GET /dashboards/` (no tiles).
public struct DashboardSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String?
    public let description: String?
    public let pinned: Bool

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Dashboard.CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
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
