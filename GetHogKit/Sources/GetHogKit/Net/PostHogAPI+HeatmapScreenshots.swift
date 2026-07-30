import Foundation

// The saved-render routes, kept apart from the coordinate routes next door
// because they are addressed differently in a way that is easy to get backwards:
// **the two routes below take two different identifiers for the same object.**
//
// They also sit on the CRUD budget rather than the analytics one. Nothing here
// aggregates events — one is a stored record, the other is a file — and taking
// analytics slots for them would come out of the same organisation-wide
// allowance the click queries need.

extension PostHogAPI {

    /// Saved heatmaps for a project.
    ///
    /// A normal `Page`, unlike `/heatmaps/` next door: it does carry `count`.
    ///
    /// Filtered server-side to completed screenshot saves, because they are the
    /// only kind this app can draw — `iframe` and `recording` saves ask a
    /// browser to render the page live. Filtering here rather than in the client
    /// keeps a project full of iframe saves from paging through them to find
    /// nothing.
    public static func savedHeatmaps(
        projectID: Int,
        type: String? = "screenshot",
        status: String? = "completed",
        limit: Int = 100
    ) -> Endpoint {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let type, !type.isEmpty { query.append(URLQueryItem(name: "type", value: type)) }
        if let status, !status.isEmpty {
            query.append(URLQueryItem(name: "status", value: status))
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/heatmap_screenshots/saved/",
            query: query,
            category: .crud
        )
    }

    /// One saved heatmap, **by `short_id`**.
    ///
    /// Not by `id`. The UUID belongs to the content route below and this route
    /// does not resolve it.
    public static func savedHeatmap(projectID: Int, shortID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/heatmap_screenshots/saved/\(shortID)/",
            category: .crud
        )
    }

    /// The rendered page image, **by `id`** — the UUID, not the short id.
    ///
    /// Returns **JPEG bytes, not JSON**, so it must be fetched with
    /// `PostHogClient.data(for:)` and never `send(_:)`; the generic path would
    /// hand a quarter-megabyte of image to `JSONDecoder` and report the failure
    /// as a decoding bug.
    ///
    /// `width` is required in practice: it selects which of the saved renders to
    /// return, and they are genuinely different renderings of the page rather
    /// than one image at several scales.
    public static func heatmapScreenshotContent(
        projectID: Int,
        screenshotID: String,
        width: Int
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/heatmap_screenshots/\(screenshotID)/content/",
            query: [URLQueryItem(name: "width", value: String(width))],
            category: .crud
        )
    }
}
