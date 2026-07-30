import Foundation

/// The endpoint catalog. Every URL GetHog knows how to call lives here, so
/// paths, rate-limit categories, and refresh policy are decided in one place.
public enum PostHogAPI {

    // MARK: - Identity

    public static func me() -> Endpoint {
        Endpoint(path: "/api/users/@me/", category: .crud)
    }

    // MARK: - Dashboards & insights

    public static func dashboards(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/dashboards/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// Tile results arrive inline, so a whole dashboard costs one request.
    ///
    /// Defaults to PostHog's cached results; only an explicit user refresh
    /// escalates to recomputation, because the budget is organisation-wide.
    public static func dashboard(
        projectID: Int,
        dashboardID: Int,
        refresh: Bool = false
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/dashboards/\(dashboardID)/",
            query: [
                URLQueryItem(name: "refresh", value: refresh ? "lazy_async" : "force_cache")
            ],
            category: .analytics
        )
    }

    // MARK: - Events

    public static func events(
        projectID: Int,
        limit: Int = 50,
        before cursor: Date? = nil,
        search: String? = nil,
        eventName: String? = nil
    ) -> Endpoint {
        var clauses: [String] = []

        if let cursor {
            // Keyset paging: PostHog rejects OFFSET for personal API keys.
            clauses.append("timestamp < toDateTime64('\(Self.sqlTimestamp(cursor))', 6)")
        }
        if let eventName, !eventName.isEmpty {
            clauses.append("event = '\(Self.escape(eventName))'")
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

    public static func sessionEvents(
        projectID: Int,
        sessionID: String,
        limit: Int = 500
    ) -> Endpoint {
        let sql = """
            SELECT uuid, event, timestamp, distinct_id, properties.$current_url, properties
            FROM events
            WHERE properties.$session_id = '\(escape(sessionID))'
            ORDER BY timestamp ASC
            LIMIT \(limit)
            """
        return hogql(projectID: projectID, sql: sql)
    }

    public static func hogql(projectID: Int, sql: String) -> Endpoint {
        let payload: [String: Any] = ["query": ["kind": "HogQLQuery", "query": sql]]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        return Endpoint(
            path: "/api/projects/\(projectID)/query/",
            method: "POST",
            body: body,
            category: .query
        )
    }

    // MARK: - Session recordings

    public static func sessionRecordings(
        projectID: Int,
        limit: Int = 50,
        offset: Int = 0
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/session_recordings/",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            category: .analytics
        )
    }

    public static func sessionRecording(projectID: Int, recordingID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/session_recordings/\(recordingID)/",
            category: .analytics
        )
    }

    // MARK: - Replay snapshots
    //
    // PostHog documents these as internal and subject to change, so everything
    // that touches them is isolated and a break degrades the player alone.
    //
    // They used to be reached under `/api/environments/`. That alias is now
    // deprecated and PostHog advertises the date in its own response headers:
    //
    //     deprecation: true
    //     sunset: Fri, 31 Jul 2026 00:00:00 GMT
    //     link: </api/projects/{id}/session_recordings/{id}/snapshots>;
    //           rel="successor-version"
    //
    // Verified before switching: the `/api/projects/` form returns byte-identical
    // data — same `application/jsonl` stream, same `cv:"2024-10"` gzip-in-string
    // encoding — and carries no deprecation headers. The OpenAPI document lists
    // 141 project-scoped families and none under `/api/environments/` at all.
    //
    // Caught by a routine research pass one day before the sunset date, not by a
    // failure. Nothing in the app would have said why playback had stopped.

    public static func snapshotSources(projectID: Int, recordingID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/session_recordings/\(recordingID)/snapshots",
            category: .analytics
        )
    }

    public static func snapshotBlobs(
        projectID: Int,
        recordingID: String,
        range: BlobRange
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/session_recordings/\(recordingID)/snapshots",
            query: [
                URLQueryItem(name: "source", value: "blob_v2"),
                URLQueryItem(name: "start_blob_key", value: range.start),
                URLQueryItem(name: "end_blob_key", value: range.end),
            ],
            category: .analytics
        )
    }

    // MARK: - Feature flags

    public static func featureFlags(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/feature_flags/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    public static func setFlagActive(projectID: Int, flagID: Int, active: Bool) -> Endpoint {
        let body = try? JSONSerialization.data(withJSONObject: ["active": active])
        return Endpoint(
            path: "/api/projects/\(projectID)/feature_flags/\(flagID)/",
            method: "PATCH",
            body: body,
            category: .crud
        )
    }

    // MARK: - Web analytics

    public static func webOverview(projectID: Int, dateFrom: String = "-7d") -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "WebOverviewQuery",
            "dateRange": ["date_from": dateFrom],
            "properties": [],
        ])
    }

    /// `breakdownBy` accepts PostHog's web-stats dimensions, e.g. `Page`,
    /// `InitialReferringDomain`, `DeviceType`, `Country`.
    public static func webStats(
        projectID: Int,
        breakdownBy: String = "Page",
        dateFrom: String = "-7d",
        limit: Int = 50
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "WebStatsTableQuery",
            "breakdownBy": breakdownBy,
            "dateRange": ["date_from": dateFrom],
            "properties": [],
            "limit": limit,
        ])
    }

    /// Core Web Vitals for one metric, bucketed into good / needs-improvement /
    /// poor. Thresholds and percentile are required — the API rejects the query
    /// without them.
    /// - Note: The percentile defaults to **p75 because that is where Google
    ///   defines the Core Web Vitals bands**, and `WebVitalMetric.thresholds`
    ///   are Google's. This previously defaulted to p90, which silently read a
    ///   p90 measurement against a p75 boundary and overstated how bad every
    ///   page was — a page comfortably "good" at p75 could be reported as
    ///   "needs improvement" purely from the mismatch.
    public static func webVitals(
        projectID: Int,
        metric: String = "LCP",
        dateFrom: String = "-7d",
        percentile: String = "p75"
    ) -> Endpoint {
        let thresholds = WebVitalMetric(rawValue: metric)?.thresholds ?? [2500, 4000]
        return queryEndpoint(projectID: projectID, query: [
            "kind": "WebVitalsPathBreakdownQuery",
            "dateRange": ["date_from": dateFrom],
            "properties": [],
            "percentile": percentile,
            "metric": metric,
            "doPathCleaning": true,
            "thresholds": thresholds,
        ])
    }

    public static func marketingAnalytics(
        projectID: Int,
        dateFrom: String = "-30d",
        limit: Int = 50
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "MarketingAnalyticsTableQuery",
            "dateRange": ["date_from": dateFrom],
            "properties": [],
            "limit": limit,
        ])
    }

    /// Logs. Note this can fail with a resource access-control error surfaced as
    /// HTTP 400 rather than 403 — see `PostHogError.accessDenied`.
    public static func logs(
        projectID: Int,
        dateFrom: String = "-24h",
        search: String = "",
        limit: Int = 100
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "LogsQuery",
            "dateRange": ["date_from": dateFrom],
            "limit": limit,
            "orderBy": "latest",
            "searchTerm": search,
            "severityLevels": [],
            "serviceNames": [],
            "filterGroup": ["type": "AND", "values": []],
        ])
    }

    public static func sessionsTimeline(projectID: Int, after: String = "-24h") -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "SessionsTimelineQuery",
            "after": after,
        ])
    }

    // MARK: - Error tracking

    public static func errorTrackingIssues(
        projectID: Int,
        dateFrom: String = "-7d",
        orderBy: String = "users",
        limit: Int = 50
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "ErrorTrackingQuery",
            "dateRange": ["date_from": dateFrom],
            "orderBy": orderBy,
            "limit": limit,
            // Required: omitting it returns HTTP 400 with a pydantic
            // "Field required" validation error.
            "volumeResolution": 0,
        ])
    }

    // MARK: - Directory resources

    public static func persons(projectID: Int, limit: Int = 50, search: String? = nil) -> Endpoint {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        return Endpoint(path: "/api/projects/\(projectID)/persons/", query: query, category: .analytics)
    }

    public static func cohorts(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/cohorts/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    public static func surveys(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/surveys/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    public static func experiments(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/experiments/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    public static func insights(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/insights/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    public static func insight(projectID: Int, insightID: Int, refresh: Bool = false) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/insights/\(insightID)/",
            query: [URLQueryItem(name: "refresh", value: refresh ? "lazy_async" : "force_cache")],
            category: .analytics
        )
    }

    public static func annotations(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/annotations/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    public static func actions(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/actions/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    // MARK: - Helpers

    /// Wraps an arbitrary typed query node for `POST /query/`.
    static func queryEndpoint(projectID: Int, query: [String: Any]) -> Endpoint {
        let body = try? JSONSerialization.data(withJSONObject: ["query": query])
        return Endpoint(
            path: "/api/projects/\(projectID)/query/",
            method: "POST",
            body: body,
            category: .query
        )
    }

    /// Escapes a value for interpolation into HogQL string literals.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    static func sqlTimestamp(_ date: Date) -> String {
        date.formatted(
            .verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(6))",
                timeZone: TimeZone(identifier: "UTC")!,
                calendar: Calendar(identifier: .gregorian)
            )
        )
    }
}
