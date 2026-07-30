import Foundation

/// The project object index.
///
/// One flat, pageable list of every object in a project — insights, flags,
/// dashboards, playlists, surveys, cohorts, pipeline functions, folders — which
/// is the cheapest answer there is to "what is in here", and the only one that
/// does not cost a request per resource type.
public extension PostHogAPI {

    /// The whole index.
    ///
    /// A listing that computes nothing, so it bills `.crud`. The project this
    /// was built against returns 200 rows, comfortably inside one page.
    ///
    /// - Note: `GET /file_system/count_by_path/` — the sibling that would give
    ///   folder counts without walking the list — **rejects personal API keys**:
    ///   `403 "This action does not support personal API key access"`. It is
    ///   deliberately absent from this catalog rather than present and always
    ///   failing. Counts must be derived from the rows this endpoint returns.
    static func fileSystem(projectID: Int, limit: Int = 300) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/file_system/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}
