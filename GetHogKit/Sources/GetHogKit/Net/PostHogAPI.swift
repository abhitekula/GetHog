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
    /// partition pruning on a shared table. Filtering on `$session_id` does not
    /// establish a time partition by itself; the scan still has to find the
    /// rows. The materialised `$session_id` column also avoids JSON extraction
    /// over every row in the window.
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
    /// The filter always contributes a date lower bound so "Any time" cannot
    /// fall through to PostHog's three-day default.
    public static func sessionRecordings(
        projectID: Int,
        limit: Int = 50,
        offset: Int? = nil,
        after: String? = nil,
        filter: SessionRecordingFilter = SessionRecordingFilter()
    ) -> Endpoint {
        var pagination = [URLQueryItem(name: "limit", value: String(limit))]
        if let offset {
            pagination.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        if let after {
            pagination.append(URLQueryItem(name: "after", value: after))
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/session_recordings/",
            query: pagination + filter.queryItems,
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
    // The successor `/api/projects/` form preserves the JSONL snapshot contract,
    // including the versioned gzip-in-string records. Keeping only the supported
    // project-scoped path avoids depending on the deprecated alias.
    //
    // Treat the response header as the source of truth for the migration rather
    // than waiting for playback to fail without an actionable explanation.

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

    /// One web-stats table, broken down by one dimension.
    ///
    /// `breakdownBy` is a closed enum in PostHog's public query contract:
    ///
    ///     Page  InitialPage  ExitPage  ExitClick  PreviousPage  ScreenName
    ///     InitialChannelType  InitialReferringDomain  InitialReferringURL
    ///     InitialUTMSource  InitialUTMCampaign  InitialUTMMedium
    ///     InitialUTMTerm  InitialUTMContent  InitialUTMSourceMediumCampaign
    ///     FirstPageviewChannelType  FirstPageviewReferringDomain
    ///     FirstPageviewUTMSource  FirstPageviewUTMCampaign
    ///     FirstPageviewUTMMedium  FirstPageviewUTMTerm
    ///     FirstPageviewUTMContent  FirstPageviewUTMSourceMediumCampaign
    ///     Browser  OS  Viewport  DeviceType  Country  Region  City
    ///     Timezone  Language  FrustrationMetrics
    ///
    /// Two response-shape differences matter to callers:
    ///
    /// - The breakdown value is not always a string. `Timezone` is a bare
    ///   number, `Viewport` is `[width, height]`, `Region` and `City` are
    ///   arrays, and every UTM dimension's largest bucket is JSON `null`. See
    ///   `WebStatsRow.rows(from:label:)`, which used to drop all of those.
    /// - `FrustrationMetrics` does not return the same **columns**. Every other
    ///   dimension answers `[breakdown_value, visitors, views,
    ///   ui_fill_fraction, cross_sell]`; that one answers `[breakdown_value,
    ///   rage_clicks, dead_clicks, errors, cross_sell]`. Read positionally as
    ///   if it were a stats table, its rage-click count is labelled "visitors"
    ///   and its dead clicks "views" — numbers that are not merely wrong but
    ///   confidently mislabelled. `WebStatsDimension` does not offer it.
    ///
    /// `Language` rows may omit `ui_fill_fraction`, so `cross_sell` sits at the
    /// index it would occupy. Nothing in the app reads index 3, and the two
    /// figures it does read are at 1 and 2 for every dimension.
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

    /// - Parameter cohort: restrict to members of one cohort.
    ///
    /// **`?cohort=` on `/persons/`, not `GET /cohorts/:id/persons/`.** Both
    /// documented paths use the `CohortPersonResult` row shape — `id`, `uuid`,
    /// `distinct_ids`, `properties`,
    /// `is_identified`, `created_at`, plus `matched_recordings` and
    /// `value_at_data_point`, which are `ActorsQuery` residue and unused here).
    /// This spelling is preferred because it is the *same path* an unfiltered
    /// person list uses, so one decoder, one cache key shape, one demo route and
    /// one rate-limit category serve both.
    ///
    /// **Neither spelling returns `count`.** The public `CohortPersonsResponse`
    /// contract requires `{results, next, previous}` without a total. So the number of
    /// members cannot come from here; it comes from the cohort's own `count`
    /// field, which is what the members section says it is showing "of".
    public static func persons(
        projectID: Int,
        limit: Int = 50,
        search: String? = nil,
        cohort: Int? = nil
    ) -> Endpoint {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        if let cohort {
            query.append(URLQueryItem(name: "cohort", value: String(cohort)))
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
    /// index behind the search screen can filter small rows in memory; insight
    /// rows carry the entire saved query subtree, so paging, search, kind and
    /// favorite filters stay server-side. `InsightKind` remains closed because
    /// an unknown kind can look like a legitimate empty result.
    ///
    /// `basic=true` is not sent because it drops `deleted` and `is_cached`.
    /// Neither is decorative
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
    /// `blocking` waits for a computed result. It is charged to the
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
    /// The collection filter is the documented spelling, while the detail path
    /// uses numeric identifiers. Overloading a single path segment with two id
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
