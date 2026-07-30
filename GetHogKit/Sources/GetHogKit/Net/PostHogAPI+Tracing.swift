import Foundation

/// OpenTelemetry tracing, and usage figures for published query endpoints.
///
/// Every one of these is a `/query/` node, so they all bill against the `.query`
/// budget rather than `.crud`.
///
/// **These cannot be verified against real data in the project they were built
/// for.** `TraceSpansQuery` returns HTTP **400** — `"Access control failure. You
/// don't have `viewer` access to the `tracing` resource."` — and the project
/// defines no query endpoints, so every usage figure is zero. The kinds and
/// required fields below were established by probing the live API for validation
/// errors, which name every missing field; the response columns follow the
/// column list PostHog documents per kind.
public extension PostHogAPI {

    // MARK: - Tracing

    /// Where an attribute key lives. `span` reaches the allowlisted top-level
    /// columns only (`service_name`, `status_code`); the other two reach the
    /// OTel attribute maps.
    enum SpanBreakdownType: String, Sendable, CaseIterable {
        case span
        case spanAttribute = "span_attribute"
        case spanResourceAttribute = "span_resource_attribute"
    }

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
        var filterGroup: [[String: Any]] = []
        if !spanNameContains.isEmpty {
            filterGroup.append([
                "key": "name",
                "type": SpanBreakdownType.span.rawValue,
                "operator": "icontains",
                "value": spanNameContains,
            ])
        }

        var query: [String: Any] = [
            "kind": "TraceSpansQuery",
            "dateRange": ["date_from": dateFrom],
            "filterGroup": filterGroup,
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

    /// The aggregated call tree under one operation.
    ///
    /// **Both** `serviceName` and `spanName` are required — the API rejects the
    /// query with either missing. `spanName` bounds the matched trace set, whose
    /// `(trace_id, parent_span_id)` self-join is unsafe at high cardinality
    /// without it; `serviceName` scopes the rows that come back.
    static func traceSpanTree(
        projectID: Int,
        serviceName: String,
        spanName: String,
        dateFrom: String = "-24h"
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "TraceSpansTreeQuery",
            "serviceName": serviceName,
            "spanName": spanName,
            "dateRange": ["date_from": dateFrom],
            "filterGroup": [],
        ])
    }

    /// Spans grouped by one attribute's value.
    ///
    /// **Both** `breakdownKey` and `breakdownType` are required.
    static func traceSpanAttributeBreakdown(
        projectID: Int,
        breakdownKey: String,
        breakdownType: SpanBreakdownType,
        serviceNames: [String] = [],
        dateFrom: String = "-24h"
    ) -> Endpoint {
        var query: [String: Any] = [
            "kind": "TraceSpansAttributeBreakdownQuery",
            "breakdownKey": breakdownKey,
            "breakdownType": breakdownType.rawValue,
            "dateRange": ["date_from": dateFrom],
            "orderBy": "count",
            "filterGroup": [],
        ]
        if !serviceNames.isEmpty {
            query["serviceNames"] = serviceNames
        }
        return queryEndpoint(projectID: projectID, query: query)
    }

    /// The service list, for the explorer's filter.
    ///
    /// Built on the breakdown kind rather than a dedicated one: no "list
    /// services" kind was verified against the live API, and `service_name` is an
    /// allowlisted top-level `span` column, so the same verified request answers
    /// the question. One fewer unproven kind in the catalog.
    static func traceServices(projectID: Int, dateFrom: String = "-24h") -> Endpoint {
        traceSpanAttributeBreakdown(
            projectID: projectID,
            breakdownKey: "service_name",
            breakdownType: .span,
            dateFrom: dateFrom
        )
    }

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
