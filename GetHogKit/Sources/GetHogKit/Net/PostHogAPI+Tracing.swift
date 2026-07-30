import Foundation

/// OpenTelemetry tracing, and usage figures for published query endpoints.
///
/// Every one of these is a `/query/` node, so they all bill against the `.query`
/// budget rather than `.crud`.
///
/// **`TraceSpansQuery` is the only tracing kind the API still has.** Measured
/// 2026-07-30 against project [REMOVED PRIVATE DATA]: `TraceSpansTreeQuery` and
/// `TraceSpansAttributeBreakdownQuery` both answer HTTP 400 `"Unsupported query
/// kind: …"` — not a permission wall, an endpoint that no longer exists for
/// anyone — so their builders are gone and the call tree and the service facet
/// are derived from the spans instead. See `TraceSpan.tree(from:)` and
/// `TraceSpan.serviceNames(from:)`.
///
/// What `TraceSpansQuery` returns still cannot be seen from here: this
/// organisation has no `viewer` access to the `tracing` resource, and PostHog
/// reports that as HTTP **400**, not 403. The response columns follow the column
/// list PostHog documents for the kind.
public extension PostHogAPI {

    // MARK: - Tracing

    /// Spans, for grouping into traces client-side.
    ///
    /// `rootSpans` is left **off** on purpose. Turning it on collapses each
    /// matching trace to its entry span, which sounds right for a phone list —
    /// but the caller groups by `trace_id` anyway, so the collapsed form costs a
    /// second request the moment anyone opens a trace. Asking for the trace's
    /// spans up front fills the detail view from the same round trip.
    ///
    /// The spans that arrive this way are not all matches: siblings pulled in
    /// for context carry `matched_filter = 0`, and the caller has to keep that
    /// distinction rather than draw them all as hits.
    ///
    /// Span-name filtering goes through `filterGroup` rather than a search
    /// parameter: `name` is one of the built-in `span` fields, and this query has
    /// no free-text search of its own.
    static func traceSpans(
        projectID: Int,
        dateFrom: String = "-24h",
        serviceNames: [String] = [],
        spanNameContains: String = "",
        errorsOnly: Bool = false,
        rootSpans: Bool = false,
        prefetchSpans: Int = 10,
        limit: Int = 100
    ) -> Endpoint {
        var filters: [[String: Any]] = []
        if !spanNameContains.isEmpty {
            filters.append([
                "key": "name",
                // `span` reaches the allowlisted top-level columns — `name`,
                // `service_name`, `status_code` — rather than the OTel attribute
                // maps, which are `span_attribute` and `span_resource_attribute`.
                "type": "span",
                "operator": "icontains",
                "value": spanNameContains,
            ])
        }

        // A `PropertyGroupFilter`: an object, and one whose `values` are
        // themselves groups rather than bare filters. Measured 2026-07-30
        // against project [REMOVED PRIVATE DATA], sending this exact body — a bare array is
        // rejected with `"Input should be a valid dictionary or instance of
        // PropertyGroupFilter"`, and filters placed flat inside `values` are
        // rejected with `"Input should be 'AND' or 'OR'"`. Only the nested form
        // parses far enough to reach the access-control check. The bare array
        // shipped once, so `TracingEndpointTests` pins this shape.
        var groups: [[String: Any]] = []
        if !filters.isEmpty {
            groups.append(["type": "AND", "values": filters])
        }

        var query: [String: Any] = [
            "kind": "TraceSpansQuery",
            "dateRange": ["date_from": dateFrom],
            "filterGroup": ["type": "AND", "values": groups],
            "orderBy": "timestamp",
            "orderDirection": "DESC",
            "rootSpans": rootSpans,
            "limit": limit,
        ]
        if !rootSpans {
            // Ignored by the API when `rootSpans` is on, so it is only sent when
            // it can mean something.
            query["prefetchSpans"] = prefetchSpans
        }
        if !serviceNames.isEmpty {
            query["serviceNames"] = serviceNames
        }
        if errorsOnly {
            // OTel status codes, not HTTP ones: 0 Unset, 1 OK, 2 Error.
            query["statusCodes"] = [2]
        }
        return queryEndpoint(projectID: projectID, query: query)
    }

    // There is no `traceSpanTree`, no `traceSpanAttributeBreakdown` and no
    // `traceServices` here. All three were built on kinds the API answers with
    // 400 `"Unsupported query kind"`, so no caller could ever have succeeded —
    // and all three asked for something the spans already carry. The call tree
    // is `parentSpanID`/`spanID`, the service facet is `serviceName`, and both
    // are now derived in `Tracing.swift` from the response already in hand,
    // which also keeps two requests off an organisation-wide rate-limit budget
    // shared with the user's production integrations.

    // MARK: - Endpoint usage

    /// Headline usage figures for the project's published query endpoints.
    ///
    /// Answers 200 whether or not any endpoint exists, with `previous` and
    /// `changeFromPreviousPct` null — so a caller must not read a zero here as a
    /// drop in traffic. See `EndpointUsageOverview.reading(endpointCount:)`.
    static func endpointsUsageOverview(projectID: Int, dateFrom: String = "-7d") -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "EndpointsUsageOverviewQuery",
            "dateRange": ["date_from": dateFrom],
        ])
    }

    /// Usage broken down by one of four server-side dimensions.
    ///
    /// `breakdownBy` is required and closed: anything outside
    /// `EndpointUsageDimension` returns a 400 that lists the four back.
    static func endpointsUsageTable(
        projectID: Int,
        breakdownBy: EndpointUsageDimension,
        dateFrom: String = "-7d",
        limit: Int = 50
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "EndpointsUsageTableQuery",
            "breakdownBy": breakdownBy.rawValue,
            "dateRange": ["date_from": dateFrom],
            "limit": limit,
        ])
    }
}
