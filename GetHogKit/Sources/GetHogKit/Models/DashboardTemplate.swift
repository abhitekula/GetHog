import Foundation

/// One tile a template would create.
///
/// Each entry is a fully-formed insight: a `name`, a `type`, a `query` — almost
/// always an `InsightVizNode` wrapping the real query node — and a grid
/// `layouts` block. Only the parts a phone can show are kept; the query itself
/// is not decoded, because this app never runs a template's queries. It shows
/// what a template *would* build.
public struct DashboardTemplateTile: Sendable, Decodable, Hashable {
    public let name: String
    public let summary: String?
    /// The insight kind, already unwrapped — `TrendsQuery`, `RetentionQuery`,
    /// `FunnelsQuery`. `nil` for a tile with no query at all, such as a text
    /// card.
    public let queryKind: String?
    /// `INSIGHT`, `TEXT`. Used only when there is no query kind to show.
    public let tileType: String?

    enum CodingKeys: String, CodingKey {
        case name, query, type
        case description
    }

    enum QueryKeys: String, CodingKey {
        case kind, source
    }

    enum SourceKeys: String, CodingKey {
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled tile"
        summary = try c.decodeIfPresent(String.self, forKey: .description)
        tileType = try c.decodeIfPresent(String.self, forKey: .type)

        // `query.kind` is `InsightVizNode` on nearly every tile, so reading the
        // outer kind would label all six tiles of a template identically and
        // say nothing about any of them. The kind worth showing is one level
        // down, in `query.source.kind`; the outer one is the fallback for the
        // node types that have no source.
        let query = try? c.nestedContainer(keyedBy: QueryKeys.self, forKey: .query)
        let source = try? query?.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
        queryKind = (try? source?.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 }
            ?? (try? query?.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 }
    }

    /// `TrendsQuery` → `Trends`, `DataTableNode` → `Data table`.
    ///
    /// A tile with no query names itself from its own type instead, so a text
    /// card reads as "Text" rather than as a blank where a kind should be.
    public var kindTitle: String {
        guard let queryKind else {
            guard let tileType, !tileType.isEmpty else { return "Tile" }
            return tileType.prefix(1).uppercased() + tileType.dropFirst().lowercased()
        }
        var stem = queryKind
        for suffix in ["Query", "Node"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        guard !stem.isEmpty else { return queryKind }
        // `InsightViz` and `DataTable` are camel case; a phone row reads better
        // as words, and splitting on the capitals is derived from the value
        // rather than from a lookup table that would drift.
        var words = ""
        for (index, character) in stem.enumerated() {
            if index > 0, character.isUppercase { words.append(" ") }
            words.append(index == 0 ? Character(character.uppercased()) : Character(character.lowercased()))
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A blank a template needs filled before it can be applied.
///
/// This is the fact a table would hide. A template's tiles are parameterised —
/// `"series": ["{DAILY_ACTIVE_USER}"]` is a placeholder, not an event — so
/// applying one is a small interview, not a button.
public struct DashboardTemplateVariable: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// `event` on everything observed. Kept as a string because the set is not
    /// documented and a closed enum would drop a kind rather than show it.
    public let type: String?
    public let summary: String?
    public let isRequired: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, description, required
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        type = try c.decodeIfPresent(String.self, forKey: .type)
        summary = try c.decodeIfPresent(String.self, forKey: .description)
        isRequired = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }
}

/// A dashboard template.
///
/// `GET /api/projects/{id}/dashboard_templates/?limit=50` answers 200 with 26
/// records against the live project, every one `scope: "global"` — PostHog's own
/// library rather than anything this team wrote. Several carry real artwork on
/// `posthog.com`, which is what makes the screen a gallery instead of a table.
///
/// Read-only here by decision, not by omission: applying a template is
/// `POST .../dashboards/create_from_template_json/` and needs `dashboard:write`.
/// See `PostHogAPI+DashboardTemplates` for why that is not offered.
public struct DashboardTemplate: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let templateName: String
    public let summary: String?
    public let tags: [String]
    /// `nil` when the response did not serialise tiles at all, which is a
    /// different fact from an empty array and must not be reported as "0
    /// insights" on a template that builds twenty.
    public let tiles: [DashboardTemplateTile]?
    public let variables: [DashboardTemplateVariable]?
    public let imageURL: URL?
    /// `global`, `team`, `organization`, `feature_flag`. A plain string because
    /// the set is PostHog's to grow and an unrecognised scope should still show.
    public let scope: String?
    public let isFeatured: Bool
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, tags, tiles, variables, scope
        case templateName = "template_name"
        case dashboardDescription = "dashboard_description"
        case imageURL = "image_url"
        case isFeatured = "is_featured"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        templateName = try c.decodeIfPresent(String.self, forKey: .templateName) ?? "Untitled template"
        let description = try c.decodeIfPresent(String.self, forKey: .dashboardDescription)
        summary = (description?.isEmpty == false) ? description : nil
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        tiles = try c.decodeIfPresent([DashboardTemplateTile].self, forKey: .tiles)
        variables = try c.decodeIfPresent([DashboardTemplateVariable].self, forKey: .variables)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL).flatMap(URL.init(string:))
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        isFeatured = try c.decodeIfPresent(Bool.self, forKey: .isFeatured) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
    }

    /// `nil` means the tiles were not returned, not that there are none.
    public var tileCount: Int? { tiles?.count }

    /// Distinct insight kinds in tile order — what the template builds, in the
    /// one line a gallery card has room for. Tile counts run 4 to 47 on the live
    /// library, so listing every tile is never an option.
    public var insightKinds: [String] {
        var seen: Set<String> = []
        return (tiles ?? []).compactMap { tile in
            let title = tile.kindTitle
            return seen.insert(title).inserted ? title : nil
        }
    }

    /// Whether applying this would first have to ask the reader something.
    public var isParameterised: Bool {
        !(variables ?? []).isEmpty
    }

    /// Featured first, then by name — the order PostHog's own picker uses, so a
    /// template someone saw on the web is in the same place here.
    ///
    /// The name comparison is case- and diacritic-insensitive: a byte-wise `<`
    /// sorts every capitalised name above every lowercase one, which shuffles
    /// the gallery for no reason a reader could see.
    public static func featuredFirst(_ a: DashboardTemplate, _ b: DashboardTemplate) -> Bool {
        if a.isFeatured != b.isFeatured { return a.isFeatured }
        let order = a.templateName.compare(
            b.templateName,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        return order == .orderedAscending
    }
}
