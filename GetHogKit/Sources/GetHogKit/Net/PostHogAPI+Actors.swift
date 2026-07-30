import Foundation

public extension PostHogAPI {

    /// The people behind one point of one insight.
    ///
    /// Costs one `query`-category slot, against a budget shared organisation-wide
    /// with the user's production integrations — so this is only ever reached
    /// from an explicit tap. Returns `nil` when the drill cannot be expressed
    /// against the saved query, which is the same answer as "do not offer the
    /// affordance".
    static func insightActors(
        projectID: Int,
        source: JSONValue,
        drill: InsightDrill,
        limit: Int = InsightActors.pageSize,
        offset: Int = 0
    ) -> Endpoint? {
        guard let query = InsightActors.query(
            source: source, drill: drill, limit: limit, offset: offset
        ) else { return nil }

        let body = try? JSONEncoder().encode(JSONValue.object(["query": query]))
        return Endpoint(
            path: "/api/projects/\(projectID)/query/",
            method: "POST",
            body: body,
            category: .query
        )
    }
}
