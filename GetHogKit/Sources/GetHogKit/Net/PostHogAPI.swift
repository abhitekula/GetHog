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

    /// The events feed.
    ///
    /// `since` has no default and is not optional, which is the point: an
    /// unbounded `ORDER BY timestamp DESC` over `events` does not reliably
    /// complete — measured at a median 8.53s and 1 success in 5 against a live
    /// project, failing with PostHog's max-execution-time 504. Making the floor
    /// part of the signature means the slow query cannot be written by
    /// forgetting an argument. See `EventFeed.swift` for the full measurements.
    public static func events(
        projectID: Int,
        limit: Int = 50,
        since floor: Date,
        before cursor: EventCursor? = nil,
        search: String? = nil,
        eventName: String? = nil
    ) -> Endpoint {
        var clauses: [String] = []

        if let eventName, !eventName.isEmpty {
            clauses.append("event = '\(Self.escape(eventName))'")
        }
        if let search, !search.isEmpty {
            let term = Self.escape(search)
            clauses.append("(event ILIKE '%\(term)%' OR distinct_id ILIKE '%\(term)%')")
        }

        return hogql(
            projectID: projectID,
            sql: eventsSQL(limit: limit, since: floor, before: cursor, filters: clauses)
        )
    }

    /// The one place the feed's SQL is written, so the time bound and the
    /// tie-safe ordering cannot be present in one variant and missing from the
    /// other.
    static func eventsSQL(
        limit: Int,
        since floor: Date,
        before cursor: EventCursor?,
        filters: [String]
    ) -> String {
        var clauses = ["timestamp > toDateTime64('\(sqlTimestamp(floor))', 6)"]

        if let cursor {
            // Keyset paging: PostHog rejects OFFSET for personal API keys. On the
            // pair rather than the timestamp alone, because timestamps are not
            // unique — three live events share one microsecond, and a page
            // boundary cutting such a group dropped its remainder silently.
            clauses.append(
                "(timestamp, uuid) < (toDateTime64('\(sqlTimestamp(cursor.timestamp))', 6), "
                    + "'\(escape(cursor.uuid))')"
            )
        }

        clauses.append(contentsOf: filters)

        return """
            SELECT uuid, event, timestamp, distinct_id, properties.$current_url, properties
            FROM events
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY timestamp DESC, uuid DESC
            LIMIT \(limit)
            """
    }

    /// Events belonging to one session, bounded to that session's own window.
    ///
    /// `within` is required and has no default, for the reason the events feed
    /// learned the hard way: an unbounded `FROM events` denies ClickHouse
    /// partition pruning on a shared table, and measured against a live project
    /// that ran 8.5s and failed one time in five under load, against ~1s and no
    /// failures for *any* bound — even a two-year one. Filtering on
    /// `$session_id` does not help; the scan still has to find the rows.
    ///
    /// Measured live while I was here, and it moved the filter too. Three
    /// variants, three runs each, against one real session returning 5 rows:
    ///
    ///     properties.$session_id + bound   38.66s / 5.45s / failed
    ///     $session_id       + bound        failed / 10.17s / 1.35s
    ///     $session_id       , no bound     failed / failed / failed
    ///
    /// `properties.$session_id` is a JSON extraction run over every row in the
    /// window; `$session_id` is the materialised column, and HogQL returns the
    /// identical rows for it. Unbounded fails outright regardless of which one
    /// filters, which is why the window is required rather than advisory.
    ///
    /// The absolute numbers are not stable — the cluster was visibly loaded,
    /// and the same query ran 1.30s in an idle window earlier. The *ordering*
    /// held across every run, and that is what the change rests on.
    ///
    /// The window is padded because the bound is a safety rail, not a filter:
    /// `$session_id` already decides membership. Event timestamps are stamped
    /// by clients whose clocks disagree with the recording's start, so a bound
    /// drawn tight to the recording would drop real events at the edges to save
    /// nothing — the partition pruning is what matters, and a padded range
    /// prunes just as well.
    public static func sessionEvents(
        projectID: Int,
        sessionID: String,
        within window: ClosedRange<Date>,
        limit: Int = 500
    ) -> Endpoint {
        let padding: TimeInterval = 3600
        let from = window.lowerBound.addingTimeInterval(-padding)
        let to = window.upperBound.addingTimeInterval(padding)
        let sql = """
            SELECT uuid, event, timestamp, distinct_id, properties.$current_url, properties
            FROM events
            WHERE $session_id = '\(escape(sessionID))'
              AND timestamp > toDateTime64('\(sqlTimestamp(from))', 6)
              AND timestamp < toDateTime64('\(sqlTimestamp(to))', 6)
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

    /// The recording list, optionally narrowed server-side.
    ///
    /// The filter's own documentation records what the API accepts and why this
    /// is a `GET` rather than a `RecordingsQuery` through `/query/`. The short
    /// version: the `GET` hydrates `person`, `/query/` returns it as `null`.
    ///
    /// An untouched filter contributes no query items, so the unfiltered call
    /// is the same request it always was.
    public static func sessionRecordings(
        projectID: Int,
        limit: Int = 50,
        offset: Int = 0,
        filter: SessionRecordingFilter = SessionRecordingFilter()
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/session_recordings/",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ] + filter.queryItems,
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

    /// One page of the saved-insight collection.
    ///
    /// Filtering and paging are **server-side on every axis**, which is not the
    /// arrangement the rest of this app uses and is deliberate here. The project
    /// index behind the search screen fetches once and filters in memory because
    /// it is 200 small rows; an insights page is not — each row carries the
    /// insight's whole saved `query` subtree, and the 140 rows in the project
    /// this was measured against are 375,505 bytes. Pulling all of them on every
    /// launch to answer a question one query parameter already answers is the
    /// trade the search screen can afford and this one cannot.
    ///
    /// Measured against project [REMOVED PRIVATE DATA] on `us.posthog.com`:
    /// - `?limit=&offset=` pages cleanly; `count` is 140 and `next` goes null on
    ///   the last page.
    /// - `?search=` matches names server-side (`search=task` → 1 of 140).
    /// - `?insight=TRENDS` → 128, `FUNNELS` → 2, `SQL` → 5, `LIFECYCLE` → 3,
    ///   `RETENTION` → 1, `PATHS` → 1, `STICKINESS` → 0. They sum to 140, so the
    ///   filter partitions the collection rather than overlapping it.
    /// - `?insight=GARBAGE` → 0 rather than an error, which is why `InsightKind`
    ///   is a closed enum: an unrecognised value fails silently and empty.
    /// - `?favorited=true` → 0 here. The field is real and per-user; this
    ///   project simply has no starred insights, so the app must not treat an
    ///   empty favourites section as a bug.
    ///
    /// `basic=true` is *not* sent, and that is a cost knowingly paid: measured at
    /// `limit=50` it returns 79,266 bytes against the full row's 119,389, a 34%
    /// saving. What it drops is `deleted` and `is_cached`. Neither is decorative
    /// here — `deleted` is what stops a tombstone being offered as a row, and
    /// `is_cached` is half of what `FreshnessLabel` states — and the alternative
    /// is one `Insight` type whose fields are populated or empty depending on
    /// which endpoint filled it, which is precisely the class of bug that is
    /// invisible until a screen shows a blank where another screen shows a date.
    /// One shape, 40 KB a page.
    public static func insights(
        projectID: Int,
        limit: Int = 100,
        offset: Int = 0,
        search: String? = nil,
        kind: InsightKind? = nil,
        favoritedOnly: Bool = false
    ) -> Endpoint {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        // Omitted at zero rather than sent as `offset=0`, so the first page's URL
        // is byte-identical to the one `ResponseCache` may already hold.
        if offset > 0 {
            query.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        if let kind {
            query.append(URLQueryItem(name: "insight", value: kind.apiValue))
        }
        if favoritedOnly {
            query.append(URLQueryItem(name: "favorited", value: "true"))
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/insights/",
            query: query,
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

    /// One insight, computing it now rather than accepting whatever is cached.
    ///
    /// Separate from `insight(projectID:insightID:refresh:)` because it is a
    /// different promise, not a different parameter. That one's `refresh: true`
    /// sends `lazy_async`, which returns immediately with a `query_status` and a
    /// null `result` and expects the caller to poll — right for an App Intent
    /// that can come back later, wrong for a screen the user is looking at.
    ///
    /// `blocking` waits and returns the numbers. Measured against project [REMOVED PRIVATE DATA]:
    /// `GET /insights/[REMOVED PRIVATE DATA]/?refresh=blocking` returned a populated `result`
    /// in 0.75s where `force_cache` had returned `null`. It is charged to the
    /// organisation-wide budget, so it is only ever reached from an explicit user
    /// action — never from opening a screen.
    public static func computeInsight(projectID: Int, insightID: Int) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/insights/\(insightID)/",
            query: [URLQueryItem(name: "refresh", value: "blocking")],
            category: .analytics
        )
    }

    /// One insight named by its console handle rather than its numeric id.
    ///
    /// A collection request filtered to one row, not `/insights/<short_id>/`.
    /// The path form does work — verified live, `/insights/COaW8hFP/` returns
    /// the same object as `/insights/[REMOVED PRIVATE DATA]/` and a bogus handle 404s — but the
    /// filter is the documented spelling, and the numeric path is the one this
    /// app already depends on. Overloading a single path segment with two id
    /// namespaces would mean a short id that happened to be all digits silently
    /// selecting a different insight.
    ///
    /// Returns a `Page<Insight>`; an unknown handle is an empty page, not a 404,
    /// so the caller distinguishes "no such insight" from "the request failed".
    public static func insight(projectID: Int, shortID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/insights/",
            query: [
                URLQueryItem(name: "short_id", value: shortID),
                URLQueryItem(name: "limit", value: "1"),
            ],
            category: .crud
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
