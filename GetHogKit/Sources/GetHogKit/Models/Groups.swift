import Foundation

// PostHog's B2B group analytics. A group is an account-like entity — a company,
// a workspace, a example product — that events are attributed to alongside the person
// who triggered them. A project defines up to five group *types*, and each type
// holds its own set of groups.

// MARK: - Group types

/// One of a project's defined group types.
///
/// `GET /groups_types/` answers with a **bare JSON array**, not the
/// `{count, results}` envelope every other collection endpoint uses — the
/// viewset sets `pagination_class = None`. Decoding it as `Page` throws.
public struct GroupType: Sendable, Decodable, Identifiable, Hashable, Comparable {
    public let groupType: String
    public let index: Int
    private let rawSingular: String?
    private let rawPlural: String?
    public let detailDashboardID: Int?
    public let defaultColumns: [String]
    public let createdAt: Date?

    public var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case groupType = "group_type"
        case index = "group_type_index"
        case rawSingular = "name_singular"
        case rawPlural = "name_plural"
        case detailDashboardID = "detail_dashboard"
        case defaultColumns = "default_columns"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupType = try c.decodeIfPresent(String.self, forKey: .groupType) ?? "group"
        index = try c.decode(Int.self, forKey: .index)
        // Null until someone renames the type in PostHog, which is the normal
        // state for a type the SDK created on first `$groupidentify`.
        rawSingular = try c.decodeIfPresent(String.self, forKey: .rawSingular).flatMap {
            $0.isEmpty ? nil : $0
        }
        rawPlural = try c.decodeIfPresent(String.self, forKey: .rawPlural).flatMap {
            $0.isEmpty ? nil : $0
        }
        detailDashboardID = try? c.decodeIfPresent(Int.self, forKey: .detailDashboardID)
        defaultColumns = (try? c.decodeIfPresent([String].self, forKey: .defaultColumns)) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
    }

    /// Sentence-case for a heading. The raw type is left exactly as stored,
    /// because `wedding_subdomain` is an identifier the user chose and titlecasing
    /// it would misrepresent what they have to type into a filter.
    public var singularName: String { rawSingular.map(Self.sentenceCased) ?? groupType }
    public var pluralName: String { rawPlural.map(Self.sentenceCased) ?? groupType }

    private static func sentenceCased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    public static func < (a: GroupType, b: GroupType) -> Bool { a.index < b.index }
}

// MARK: - Groups

/// One group, read out of a `GroupsQuery` result row.
///
/// `GroupsQuery` returns positional arrays with a parallel `columns` array, so
/// this is built from a `QueryRow` rather than decoded directly.
public struct GroupRow: Sendable, Identifiable, Hashable {
    public let key: String
    public let displayName: String
    /// False when `displayName` is only the key echoed back, so a row can say
    /// "unnamed" instead of showing a cuid twice.
    public let hasDisplayName: Bool
    public let createdAt: Date?
    public let properties: JSONValue?

    public var id: String { key }

    public init?(row: QueryRow) {
        // `group_name` is an **object** — `{"display_name": ..., "key": ...}` —
        // not the string the column name suggests. The query runner builds it as
        // a tuple and rewrites it into a dict before responding, so reading it as
        // a String yields an empty column rather than an error.
        let nameCell = row.value("group_name")
        let displayName = nameCell?["display_name"]?.stringValue
        let nameKey = nameCell?["key"]?.stringValue

        guard let key = row.string("key") ?? nameKey else { return nil }
        self.key = key
        self.createdAt = row.date("created_at")

        if let displayName, !displayName.isEmpty, displayName != key {
            self.displayName = displayName
            self.hasDisplayName = true
        } else {
            // The server already falls back to the key when `properties.name` is
            // unset; this repeats the fallback for the case where the caller did
            // not select `group_name` at all.
            self.displayName = key
            self.hasDisplayName = false
        }

        self.properties = Self.properties(from: row.value("properties"))
    }

    public var propertyCount: Int {
        guard case .object(let dict) = properties else { return 0 }
        return dict.count
    }

    /// ClickHouse stores group properties as a JSON *string*, and that is how the
    /// query API has handed them back; a pre-parsed object has also been seen.
    /// Accepting only one shape loses the entire property tree on the other.
    private static func properties(from value: JSONValue?) -> JSONValue? {
        switch value {
        case .object(let dict): return dict.isEmpty ? nil : value
        case .string(let raw):
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let dict) = parsed, !dict.isEmpty
            else { return nil }
            return parsed
        default: return nil
        }
    }
}
