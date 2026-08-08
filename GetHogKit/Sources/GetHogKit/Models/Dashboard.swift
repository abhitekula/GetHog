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
/// return `tiles`, and counting them would cost
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
    public let text: DashboardTextTile?
    public let buttonTile: JSONValue?
    public let widget: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, order, color, insight, text, widget
        case buttonTile = "button_tile"
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
        text = try? c.decodeIfPresent(DashboardTextTile.self, forKey: .text)
        buttonTile = try? c.decodeIfPresent(JSONValue.self, forKey: .buttonTile)
        widget = try? c.decodeIfPresent(JSONValue.self, forKey: .widget)
    }

    public var content: DashboardTileContent {
        if let insight { return .insight(insight) }
        if let text { return .text(text) }
        if let buttonTile { return .button(buttonTile) }
        if let widget { return .widget(widget) }
        return .unknown
    }

    public var renderModel: InsightRenderModel {
        switch content {
        case .insight(let insight): insight.renderModel
        case .text: .unsupported(kind: "Text tile")
        case .button: .unsupported(kind: "Button tile")
        case .widget: .unsupported(kind: "Widget tile")
        case .unknown: .unsupported(kind: "Unknown tile")
        }
    }

    public var title: String {
        switch content {
        case .insight(let insight): insight.title
        case .text: "Note"
        case .button: "Button"
        case .widget: "Widget"
        case .unknown: "Unknown tile"
        }
    }
}

public enum DashboardTileContent: Sendable {
    case insight(Insight)
    case text(DashboardTextTile)
    case button(JSONValue)
    case widget(JSONValue)
    case unknown
}

public struct DashboardTextTile: Sendable, Equatable, Decodable {
    public let body: String

    enum CodingKeys: String, CodingKey { case body }

    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            body = value
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decodeIfPresent(JSONValue.self, forKey: .body) ?? .string("")
        body = value.tabularDescription
    }
}
