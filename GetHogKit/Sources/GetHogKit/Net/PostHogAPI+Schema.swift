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
    /// **The explicit `LIMIT` is load-bearing, and its absence can fail
    /// silently.** The service may return a default page with truncation
    /// metadata, so the browser must request an explicit bounded page.
    ///
    /// This used to add that `QueryResponse` "decodes neither field", which
    /// stopped being true in the commit that wrote it: `hasMore` and
    /// `appliedLimit` are decoded and `isTruncated` exposes them. That does not
    /// make the `LIMIT` optional, and `PostHogAPI+Groups.swift` records why —
    /// the two fields report only a cap **PostHog** applied, never one the query
    /// asked for. Detecting the default is not the same as avoiding it.
    ///
    /// The ceiling bounds the response rather than promising completeness.
    /// `SchemaStore` reports a possibly truncated result rather than hiding it.
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
    /// The `LIMIT` remains explicit for every table: a current table size is not
    /// a durable guarantee against silent truncation.
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
