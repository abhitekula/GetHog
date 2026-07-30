import Foundation

// Clickmap endpoints. Kept out of the main catalog file so they can be read
// alongside the two surprises they carry: neither response is a normal
// paginated page, and the two halves disagree about what a "click" is.

extension PostHogAPI {

    /// Aggregated click coordinates for a page.
    ///
    /// The response is a bare `{"results": […]}` — **no `count`, no `next`**.
    /// `Page` reads it only because its `count` is optional; the `count` on each
    /// row is a per-coordinate click tally and nothing to do with paging.
    ///
    /// `urlExact` narrows to one page. Left nil the endpoint aggregates every
    /// URL in the project, which is the only thing that makes sense without a
    /// screenshot to overlay: the shape of the whole site's click distribution.
    public static func heatmap(
        projectID: Int,
        dateFrom: String = "-7d",
        type: String = "click",
        urlExact: String? = nil,
        limit: Int = 500
    ) -> Endpoint {
        var query = [
            URLQueryItem(name: "date_from", value: dateFrom),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "limit", value: String(limit)),
            // Clicks recorded at the origin are instrumentation noise, not a
            // hotspot in the top-left corner.
            URLQueryItem(name: "hide_zero_coordinates", value: "true"),
        ]
        if let urlExact, !urlExact.isEmpty {
            query.append(URLQueryItem(name: "url_exact", value: urlExact))
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/heatmaps/",
            query: query,
            category: .analytics
        )
    }

    /// Click counts grouped by the element that was clicked.
    ///
    /// Two things to know. The response carries `next`/`previous` but again no
    /// `count`, and the `next` URL leaks PostHog's *internal cluster hostname*
    /// (`posthog-web-django…svc.cluster.local`), so it can never be followed as
    /// an absolute URL — page with `offset` instead.
    ///
    /// Left to its default the endpoint returns `$autocapture`, `$rageclick` and
    /// `$dead_click` rows interleaved in one list — which is deliberately how
    /// this is called. Narrowing with `include` would cost a fresh request every
    /// time the reader switched between the three, against a rate-limit budget
    /// that belongs to the whole organisation; one list filtered on the client
    /// serves all three. What must *not* happen is ranking them together, since
    /// a dead click provably did nothing and is not engagement.
    public static func elementStats(
        projectID: Int,
        dateFrom: String = "-7d",
        include: [String] = [],
        limit: Int = 100,
        offset: Int = 0
    ) -> Endpoint {
        var query = [
            URLQueryItem(name: "date_from", value: dateFrom),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        // Repeated parameters rather than a comma-joined list: the endpoint
        // accepts both, and repeating avoids guessing at its splitting rules.
        query.append(contentsOf: include.map { URLQueryItem(name: "include", value: $0) })

        return Endpoint(
            path: "/api/projects/\(projectID)/elements/stats/",
            query: query,
            category: .analytics
        )
    }
}
