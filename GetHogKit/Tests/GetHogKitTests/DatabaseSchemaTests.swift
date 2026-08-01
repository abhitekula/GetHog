import Foundation
import Testing

@testable import GetHogKit

// The schema browser's models and the queries behind them.
//
// The assertions below are authored contract examples for response shapes,
// row-count handling, and identifier quoting.

@Suite("HogQL identifier quoting")
struct HogQLIdentifierTests {

    /// Representative schema names that exercise the quoting rule.
    ///
    /// Each pair keeps a schema name on the left and its expected `hogql_value`
    /// on the right, including the punctuation cases most likely to regress.
    @Test(
        "reproduces PostHog's own hogql_value",
        arguments: [
            ("uuid", "uuid"),
            ("event", "event"),
            ("distinct_id", "distinct_id"),
            ("elements_chain", "elements_chain"),
            ("person_mode", "person_mode"),
            ("team_id", "team_id"),
            ("$session_id", "`$session_id`"),
            ("$window_id", "`$window_id`"),
            ("$group_0", "`$group_0`"),
            ("$virt_initial_channel_type", "`$virt_initial_channel_type`"),
            ("$virt_revenue", "`$virt_revenue`"),
            ("$start_timestamp", "`$start_timestamp`"),
        ]
    )
    func matchesPostHog(name: String, expected: String) {
        #expect(HogQLIdentifier.quoted(name) == expected)
    }

    @Test("quotes a name with a dot, which would otherwise parse as a table reference")
    func dottedName() {
        #expect(HogQLIdentifier.quoted("a.b") == "`a.b`")
    }

    @Test("quotes a name that starts with a digit")
    func leadingDigit() {
        #expect(HogQLIdentifier.quoted("1st") == "`1st`")
    }

    @Test("quotes a name containing a space")
    func space() {
        #expect(HogQLIdentifier.quoted("first seen") == "`first seen`")
    }

    /// An empty name emitted bare would vanish into the surrounding SQL instead
    /// of producing a syntax error, which is the one failure mode worse than a
    /// rejected query.
    @Test("quotes an empty name rather than emitting nothing")
    func empty() {
        #expect(HogQLIdentifier.quoted("") == "``")
    }

    @Test("leaves a leading underscore unquoted")
    func underscore() {
        #expect(HogQLIdentifier.quoted("_internal") == "_internal")
    }
}

@Suite("Schema table decoding")
struct SchemaTableTests {

    private func row(_ values: [JSONValue]) -> QueryRow {
        QueryRow(columns: ["table_name", "table_type", "description"], values: values)
    }

    /// Public schema table categories, each mapped independently.
    @Test(
        "decodes the public table_type values",
        arguments: [
            ("posthog", SchemaTableKind.posthog),
            ("data_warehouse", .dataWarehouse),
            ("system", .system),
            ("information_schema", .informationSchema),
        ]
    )
    func kinds(raw: String, expected: SchemaTableKind) throws {
        let table = try #require(SchemaTable(row: row([.string("t"), .string(raw), .null])))
        #expect(table.kind == expected)
    }

    /// The trap `DisplayTypeCoverageTests` exists for, in a second place: an
    /// unrecognised category must not land in a known bucket.
    @Test("keeps an unknown table_type as itself rather than folding it into a known one")
    func unknownKind() throws {
        let table = try #require(
            SchemaTable(row: row([.string("t"), .string("lakehouse"), .null]))
        )
        #expect(table.kind == .other("lakehouse"))
        #expect(table.kind.title == "lakehouse")
        #expect(!SchemaTableKind.known.contains(table.kind))
    }

    @Test("carries PostHog's description, which is why this source was chosen")
    func description() throws {
        let table = try #require(
            SchemaTable(
                row: row([
                    .string("events"), .string("posthog"),
                    .string("Every analytics event captured for the project."),
                ])
            )
        )
        #expect(table.summary == "Every analytics event captured for the project.")
    }

    @Test("skips a row with no table name rather than inventing one")
    func missingName() {
        #expect(SchemaTable(row: row([.null, .string("posthog"), .null])) == nil)
    }

    /// Measured: `FROM github.issues`, ``FROM `github.issues` `` and
    /// `FROM github_issues` all returned the same 81 rows, so the plain name is
    /// what goes into the statement.
    @Test("uses a dotted warehouse table name unquoted")
    func dottedTable() throws {
        let table = try #require(
            SchemaTable(row: row([.string("github.issues"), .string("data_warehouse"), .null]))
        )
        #expect(table.fromClause == "github.issues")
    }
}

@Suite("Schema column decoding")
struct SchemaColumnTests {

    private func row(_ values: [JSONValue]) -> QueryRow {
        QueryRow(
            columns: [
                "column_name", "data_type", "is_nullable", "is_array", "field_kind", "description",
            ],
            values: values
        )
    }

    /// `is_nullable` and `is_array` come back as ClickHouse `UInt8` — measured
    /// `[['is_nullable', 'UInt8'], ['is_array', 'UInt8']]` in the response's own
    /// `types`. Reading them as JSON booleans finds nothing and reports every
    /// column non-null, which is a wrong answer that looks like a plausible one.
    @Test("reads UInt8 flags, not JSON booleans")
    func uint8Flags() throws {
        let column = try #require(
            SchemaColumn(
                row: row([
                    .string("maybe"), .string("String"), .number(1), .number(1),
                    .string("column"), .null,
                ])
            )
        )
        #expect(column.isNullable)
        #expect(column.isArray)
    }

    @Test("treats zero as false")
    func zeroFlags() throws {
        let column = try #require(
            SchemaColumn(
                row: row([
                    .string("uuid"), .string("UUID"), .number(0), .number(0),
                    .string("column"), .string("Unique identifier of this event row."),
                ])
            )
        )
        #expect(!column.isNullable)
        #expect(!column.isArray)
        #expect(column.summary == "Unique identifier of this event row.")
    }

    @Test("quotes a dollar-prefixed column for insertion")
    func quoting() throws {
        let column = try #require(
            SchemaColumn(
                row: row([
                    .string("$session_id"), .string("String"), .number(0), .number(0),
                    .string("column"), .null,
                ])
            )
        )
        #expect(column.hogqlIdentifier == "`$session_id`")
    }

    /// A `virtual_table` field is a namespace reached *through*, not a value —
    /// `SELECT person FROM events` is not a query PostHog will run.
    @Test("marks a virtual_table field as a namespace, not a selectable value")
    func namespace() throws {
        let column = try #require(
            SchemaColumn(
                row: row([
                    .string("person"), .string("VirtualTable"), .number(0), .number(0),
                    .string("virtual_table"), .null,
                ])
            )
        )
        #expect(column.isNamespace)
    }

    @Test("keeps an unrecognised data type as itself")
    func unknownType() throws {
        let column = try #require(
            SchemaColumn(
                row: row([
                    .string("x"), .string("Tuple"), .number(0), .number(0),
                    .string("column"), .null,
                ])
            )
        )
        #expect(column.dataType == "Tuple")
    }
}

@Suite("Schema endpoints")
struct SchemaEndpointTests {

    private func sql(_ endpoint: Endpoint) throws -> String {
        let body = try #require(endpoint.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let query = try #require(json["query"] as? [String: Any])
        #expect(query["kind"] as? String == "HogQLQuery")
        return try #require(query["query"] as? String)
    }

    /// The measured API surprise this whole endpoint is shaped around: without
    /// an explicit `LIMIT`, `/query/` returns 100 of the project's 141 tables
    /// with HTTP 200 and `hasMore: true`.
    ///
    /// This used to end "and `QueryResponse` decodes neither `hasMore` nor
    /// `limit` — so the truncation is invisible to this client", which was false
    /// the moment it was written: the same commit that added this file added the
    /// decoding, and `QueryResponse.isTruncated` has read it since.
    ///
    /// The `LIMIT` is still load-bearing, and the flag is the reason to say why
    /// rather than to delete the sentence. `PostHogAPI+Groups.swift` records the
    /// measurement: `hasMore` and `limit` come back **only** when PostHog
    /// applied its own cap — the identical query written `LIMIT 200` returned
    /// 200 rows of 423 with neither field present. So the envelope can report a
    /// cap this client did not ask for and can never report one it did. Writing
    /// the `LIMIT` is what keeps the browser off the 100-row default; it is not
    /// made redundant by being able to detect the default.
    @Test("always writes an explicit LIMIT, because the default silently caps at 100")
    func tablesLimit() throws {
        let statement = try sql(PostHogAPI.schemaTables(projectID: 1))
        #expect(statement.contains("LIMIT 1000"))
        #expect(statement.contains("system.information_schema.tables"))
    }

    @Test("columns are ordered by declaration, not alphabetically")
    func columnOrder() throws {
        let statement = try sql(PostHogAPI.schemaColumns(projectID: 1, table: "events"))
        #expect(statement.contains("ORDER BY ordinal_position"))
        #expect(statement.contains("LIMIT 1000"))
    }

    @Test("selects the description column, which is the reason for this source")
    func selectsDescriptions() throws {
        #expect(try sql(PostHogAPI.schemaTables(projectID: 1)).contains("description"))
        #expect(try sql(PostHogAPI.schemaColumns(projectID: 1, table: "e")).contains("description"))
    }

    /// A table name reaches this as a string from the API, and a quote in one
    /// would otherwise end the literal early.
    @Test("escapes a quote in a table name")
    func escapesTableName() throws {
        let statement = try sql(PostHogAPI.schemaColumns(projectID: 1, table: "o'brien"))
        #expect(statement.contains("o\\'brien"))
    }

    @Test("spends the query budget, not the analytics one")
    func category() {
        #expect(PostHogAPI.schemaTables(projectID: 1).category == .query)
        #expect(PostHogAPI.schemaColumns(projectID: 1, table: "e").category == .query)
    }
}
