import Foundation

// The project's queryable schema, as the SQL console browses it.
//
// # Why `system.information_schema.*` and not `DatabaseSchemaQuery`
//
// Both query shapes are public. `DatabaseSchemaQuery` returns the full schema in
// one response but omits descriptions. `information_schema` supports a smaller
// table list followed by columns for the table a reader opens, and includes the
// descriptive text that makes a phone-sized schema browser useful.
//
// What `DatabaseSchemaQuery` uniquely offers is `hogql_value`: each field's name
// already correctly backtick-quoted. That is genuinely useful — see
// `HogQLIdentifier` — but it is reproducible locally, and verified so against
// representative public identifier shapes rather than assumed.
//
// **Not carried over, and deliberately:** `DatabaseSchemaQuery` can report row
// counts and sync status for data-warehouse tables. Those belong to the
// Warehouse screen, which is where
// somebody asks whether a sync is healthy; the console asks what it can select
// from.

/// Quoting for a HogQL identifier.
public enum HogQLIdentifier {

    /// A column name as it must be written in a HogQL statement.
    ///
    /// PostHog's own `DatabaseSchemaQuery` returns this per field as
    /// `hogql_value`, which is the authority. This reproduces it locally so the
    /// console does not have to spend a second schema request to learn how to
    /// spell a column it already has the name of.
    ///
    /// `HogQLIdentifierTests` covers plain, reserved, punctuated and
    /// `$`-prefixed names so a quoting change fails at the public boundary.
    ///
    /// This matters more on a phone than the rule's triviality suggests: a
    /// backtick is two keyboard switches away on iOS, and the names that need
    /// one — `$session_id`, `$virt_initial_channel_type` — are exactly the
    /// names nobody remembers precisely.
    public static func quoted(_ name: String) -> String {
        name.isPlainHogQLIdentifier ? name : "`\(name)`"
    }
}

extension String {

    /// Whether this can appear in HogQL unquoted: an ASCII letter or underscore,
    /// then ASCII letters, digits and underscores.
    ///
    /// Empty is *not* plain — it would otherwise be emitted bare and silently
    /// vanish into the surrounding SQL rather than producing a syntax error.
    var isPlainHogQLIdentifier: Bool {
        guard let first = unicodeScalars.first else { return false }
        guard first == "_" || ("a"..."z").contains(first) || ("A"..."Z").contains(first) else {
            return false
        }
        return unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                || ("0"..."9").contains($0)
        }
    }
}

/// What kind of thing a table is, which is how the browser groups them.
///
/// An explicit `.other` rather than a `default` folding an unknown value into
/// one of the known ones. The failure this avoids is the one
/// `DisplayTypeCoverageTests` exists for elsewhere in this project: a new value
/// that matches no case and lands silently in the wrong group reads as the
/// browser having lost a table, not as PostHog having added a category.
public enum SchemaTableKind: Sendable, Hashable {
    /// PostHog's own analytics tables — `events`, `persons`, `sessions`.
    case posthog
    /// Tables synced in from a warehouse source.
    case dataWarehouse
    /// The project's own configuration, queryable — `system.feature_flags`.
    case system
    /// The schema describing the schema.
    case informationSchema
    /// A `table_type` this build has never seen. Shown under its own raw name.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "posthog": self = .posthog
        case "data_warehouse": self = .dataWarehouse
        case "system": self = .system
        case "information_schema": self = .informationSchema
        default: self = .other(rawValue)
        }
    }

    public var title: String {
        switch self {
        case .posthog: "PostHog"
        case .dataWarehouse: "Data warehouse"
        case .system: "Project configuration"
        case .informationSchema: "Schema"
        case .other(let raw): raw
        }
    }

    /// One line saying what the group *is*, for the section footer.
    public var summary: String {
        switch self {
        case .posthog: "The analytics tables — events, persons, sessions."
        case .dataWarehouse: "Tables synced in from an external source."
        case .system: "This project's own configuration, queryable as tables."
        case .informationSchema: "The tables describing these tables."
        case .other: "A table category this version of GetHog doesn't recognise."
        }
    }

    /// Reading order. The warehouse sits second because a project that has one
    /// is usually looking for it, and the 65 `system.*` tables would otherwise
    /// bury its two.
    public var sortOrder: Int {
        switch self {
        case .posthog: 0
        case .dataWarehouse: 1
        case .system: 2
        case .informationSchema: 3
        case .other: 4
        }
    }

    /// Every kind the browser knows to draw, in reading order. `.other` is
    /// excluded because it has no fixed value.
    public static let known: [SchemaTableKind] = [
        .posthog, .dataWarehouse, .system, .informationSchema,
    ]
}

/// One table in the project's schema.
public struct SchemaTable: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let kind: SchemaTableKind
    /// PostHog's prose for the table. 139 of this project's 141 tables have one.
    public let summary: String?

    public init(name: String, kind: SchemaTableKind, summary: String?) {
        self.name = name
        self.kind = kind
        self.summary = summary
    }

    /// A dotted name — a warehouse table such as `github.issues` — needs no
    /// quoting in a `FROM` clause. Measured: `FROM github.issues`,
    /// ``FROM `github.issues` `` and `FROM github_issues` (PostHog's own
    /// underscore alias) all return the same 81 rows, so the plain name is
    /// inserted as-is.
    public var fromClause: String { name }

    public init?(row: QueryRow) {
        guard let name = row.string("table_name") else { return nil }
        self.name = name
        self.kind = SchemaTableKind(rawValue: row.string("table_type") ?? "")
        self.summary = row.string("description")
    }
}

/// One column of one table.
public struct SchemaColumn: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    /// PostHog's own type word — `String`, `DateTime`, `JSON`, `UUID`, `Array`,
    /// `Boolean`, `Integer`, `VirtualTable`, `Unknown`. Passed through rather
    /// than mapped to an enum: it is displayed, never branched on, and a type
    /// this build has not seen should read as itself.
    public let dataType: String
    public let isNullable: Bool
    public let isArray: Bool
    /// `column`, `expression` or `virtual_table` in this project.
    public let fieldKind: String
    public let summary: String?

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = false,
        isArray: Bool = false,
        fieldKind: String = "column",
        summary: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isArray = isArray
        self.fieldKind = fieldKind
        self.summary = summary
    }

    /// The name as it must be written in a query. This is what tapping the row
    /// puts into the editor.
    public var hogqlIdentifier: String { HogQLIdentifier.quoted(name) }

    /// A `virtual_table` column is not selectable on its own — it is a namespace
    /// you reach *through*, as in `person.properties`. Selecting one yields a
    /// query that fails, so the browser says so instead of offering it as a
    /// value.
    public var isNamespace: Bool { fieldKind == "virtual_table" }

    public init?(row: QueryRow) {
        guard let name = row.string("column_name") else { return nil }
        self.name = name
        self.dataType = row.string("data_type") ?? "Unknown"
        // `is_nullable` and `is_array` arrive as ClickHouse `UInt8` — 0 or 1,
        // not JSON booleans. Read through `int` rather than a bool accessor,
        // which would find nothing and silently report every column non-null.
        self.isNullable = (row.int("is_nullable") ?? 0) != 0
        self.isArray = (row.int("is_array") ?? 0) != 0
        self.fieldKind = row.string("field_kind") ?? "column"
        self.summary = row.string("description")
    }
}
