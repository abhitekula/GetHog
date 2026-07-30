import Foundation

/// The Tier-3 tail: notebooks, the operational automation resources, early
/// access features, Max AI threads and replay playlists.
///
/// Every one of these is a plain CRUD listing — none of them computes anything —
/// so they all bill against the `.crud` budget. Charging them to `.analytics` or
/// `.query` would spend the allowance the screens that *do* compute depend on.
public extension PostHogAPI {

    // MARK: - Notebooks

    static func notebooks(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/notebooks/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// One notebook, including its body.
    ///
    /// Looked up by `short_id`, not by the UUID in `id`: the viewset sets
    /// `lookup_field = "short_id"`, and the UUID form is a 404. The list payload
    /// carries no note text at all, so this is the only way to read one.
    static func notebook(projectID: Int, shortID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/notebooks/\(shortID)/",
            category: .crud
        )
    }

    // MARK: - Automation

    static func hogFlows(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/hog_flows/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// Saved queries published over HTTP. Listing them does not run them.
    static func queryEndpoints(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/endpoints/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    static func alerts(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/alerts/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    static func subscriptions(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/subscriptions/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    static func batchExports(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/batch_exports/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    // MARK: - Early access

    /// Singular `early_access_feature`, not `early_access_features`. The
    /// pluralised spelling every other resource uses returns 404 here.
    static func earlyAccessFeatures(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/early_access_feature/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    // MARK: - Max AI

    /// Max threads. The list serializer omits `messages` entirely.
    static func conversations(projectID: Int, limit: Int = 50) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/conversations/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// One thread, with its messages. Only the retrieve serializer carries them.
    static func conversation(projectID: Int, conversationID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/conversations/\(conversationID)/",
            category: .crud
        )
    }

    // MARK: - Replay playlists

    /// Playlists, including the synthetic ones PostHog injects with negative ids.
    static func sessionRecordingPlaylists(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/session_recording_playlists/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}
