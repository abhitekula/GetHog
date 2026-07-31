import Foundation

// Schema introspection for the SQL console's table browser.
//
// Two requests, and the split is the navigation: one to list the tables, one
// per table the reader actually opens. `DatabaseSchema.swift` records why this
// is `system.information_schema.*` rather than `DatabaseSchemaQuery`, and what
// that choice gives up.
//
// **Cost.** Both are `.query` category. Opening the browser is one request;
// opening a table is one more, and `SchemaStore` caches both for the life of
// the screen, so scrolling the list and returning to a table already seen costs
// nothing. A reader who opens the browser and looks at three tables spends four
// requests, once.
extension PostHogAPI {

    /// Every table the project can select from.
    ///
    /// **The explicit `LIMIT` is load-bearing, and its absence fails silently.**
    /// Measured 2026-07-30 against project [REMOVED PRIVATE DATA]: `SELECT table_name FROM
    /// system.information_schema.tables` with no `LIMIT` returns **100 of 141
    /// rows**, HTTP 200, with `"hasMore": true` and `"limit": 100` in the
    /// envelope and no error anywhere. `QueryResponse` decodes neither field, so
    /// the browser would have shown 100 tables and claimed that was all of them
    /// — a wrong answer, not a missing one. With `LIMIT 1000` the same query
    /// returns all 141 and `hasMore` is absent.
    ///
    /// 1000 against 141 observed: the ceiling exists to bound the response, not
    /// to be reached. A project with more than 1000 tables would be truncated,
    /// and `SchemaStore` reports that rather than hiding it.
    public static func schemaTables(projectID: Int, limit: Int = 1000) -> Endpoint {
        hogql(
            projectID: projectID,
            sql: """
                SELECT table_name, table_type, description
                FROM system.information_schema.tables
                ORDER BY table_name
                LIMIT \(limit)
                """
        )
    }

    /// One table's columns, in the order the table declares them.
    ///
    /// `ORDER BY ordinal_position` rather than by name: a schema is read in
    /// declaration order — `uuid, event, properties, timestamp` — and
    /// alphabetising it puts `$group_0` first and separates `timestamp` from
    /// `created_at`. The browser's search field is what finds a column by name.
    ///
    /// The widest table in this project is `events` at 63 columns, so the same
    /// 100-row default would not in fact have bitten here; the `LIMIT` is
    /// explicit anyway, because "the widest table happens to fit" is a fact
    /// about one project and the silent truncation above is a fact about the API.
    public static func schemaColumns(projectID: Int, table: String, limit: Int = 1000) -> Endpoint {
        hogql(
            projectID: projectID,
            sql: """
                SELECT column_name, data_type, is_nullable, is_array, field_kind, description
                FROM system.information_schema.columns
                WHERE table_name = '\(escape(table))'
                ORDER BY ordinal_position
                LIMIT \(limit)
                """
        )
    }
}
