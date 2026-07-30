import Foundation

// The token-driven events query. Kept out of the main catalog file because it
// carries one rule the plain `events(…)` call does not: tokens of the *same*
// kind widen the result, tokens of different kinds narrow it.

extension PostHogAPI {

    /// The events feed narrowed by search chips.
    ///
    /// Combining rules, chosen so that adding a chip never silently produces an
    /// empty feed:
    ///
    /// - Event names are OR-ed into an `IN` list — no event is two names at
    ///   once, so AND-ing them would match nothing.
    /// - Person terms are OR-ed for the same reason.
    /// - Property equalities are AND-ed, which is the only reading that makes
    ///   sense for distinct keys.
    /// - The groups are AND-ed together.
    ///
    /// `search` is the residual free text still in the field, so a half-typed
    /// term keeps filtering before it has been committed to a chip.
    public static func events(
        projectID: Int,
        limit: Int = 50,
        before cursor: Date? = nil,
        tokens: [EventFilterToken],
        search: String? = nil
    ) -> Endpoint {
        var clauses: [String] = []

        if let cursor {
            // Keyset paging: PostHog rejects OFFSET for personal API keys.
            clauses.append("timestamp < toDateTime64('\(Self.sqlTimestamp(cursor))', 6)")
        }

        let eventNames = tokens.filter { $0.kind == .event }.map(\.value)
        if eventNames.count == 1 {
            clauses.append("event = '\(Self.escape(eventNames[0]))'")
        } else if eventNames.count > 1 {
            let list = eventNames.map { "'\(Self.escape($0))'" }.joined(separator: ", ")
            clauses.append("event IN (\(list))")
        }

        let people = tokens.filter { $0.kind == .person }.map(\.value)
        if !people.isEmpty {
            let matches = people.map { "distinct_id ILIKE '%\(Self.escape($0))%'" }
            clauses.append(
                people.count == 1 ? matches[0] : "(" + matches.joined(separator: " OR ") + ")"
            )
        }

        for token in tokens where token.kind == .property {
            // A key that is not an identifier cannot be written as a HogQL path.
            // `suggestions(for:)` refuses to build such a token in the first
            // place; this is the backstop for one arriving from stored data.
            guard EventFilterToken.isValidPropertyKey(token.key) else { continue }
            clauses.append("properties.\(token.key) = '\(Self.escape(token.value))'")
        }

        if let search, !search.isEmpty {
            let term = Self.escape(search)
            clauses.append("(event ILIKE '%\(term)%' OR distinct_id ILIKE '%\(term)%')")
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT uuid, event, timestamp, distinct_id, properties.$current_url, properties
            FROM events
            \(whereClause)
            ORDER BY timestamp DESC
            LIMIT \(limit)
            """

        return hogql(projectID: projectID, sql: sql)
    }
}
