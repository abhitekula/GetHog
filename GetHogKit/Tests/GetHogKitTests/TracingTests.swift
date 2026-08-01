import Foundation
import Testing

@testable import GetHogKit

/// Local rather than shared: the equivalent in `APITests` is fileprivate, and
/// two test files reaching for one helper would couple them for no gain.
private extension Data {
    var bodyText: String { String(decoding: self, as: UTF8.self) }

    /// The decoded `query` node. Needed wherever a value contains a character
    /// JSON escapes — `JSONSerialization` writes a path as `GET \/api\/orders`,
    /// so a substring check against the raw bytes tests the encoder, not the
    /// request.
    var queryNode: [String: Any] {
        let root = try? JSONSerialization.jsonObject(with: self) as? [String: Any]
        return (root?["query"] as? [String: Any]) ?? [:]
    }
}

@Suite("Tracing endpoints")
struct TracingEndpointTests {

    @Test("builds a span query against the query endpoint")
    func spansEndpoint() throws {
        let endpoint = PostHogAPI.traceSpans(projectID: 1_001, dateFrom: "-30d", limit: 50)

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1001/query/")
        #expect(endpoint.category == .query)

        let body = try #require(endpoint.body).bodyText
        #expect(body.contains("TraceSpansQuery"))
        #expect(body.contains("-30d"))
    }

    @Test("asks for each trace's spans so opening one costs no second request")
    func spansQueryPrefetchesTraceStructure() throws {
        let query = try #require(PostHogAPI.traceSpans(projectID: 1_001).body).queryNode
        #expect(query["rootSpans"] as? Bool == false)
        #expect((query["prefetchSpans"] as? Int ?? 0) > 1)

        // The API ignores the prefetch when it is collapsing to roots, so it is
        // not sent in that mode.
        let collapsed = try #require(
            PostHogAPI.traceSpans(projectID: 1_001, rootSpans: true).body
        ).queryNode
        #expect(collapsed["rootSpans"] as? Bool == true)
        #expect(collapsed["prefetchSpans"] == nil)
    }

    @Test("sends filterGroup as a PropertyGroupFilter object, never as a bare array")
    func filterGroupIsAPropertyGroupFilter() throws {
        // Regression. The wrapper is required even when there is nothing to
        // filter on; a bare array is not a `PropertyGroupFilter` object.
        let unfiltered = try #require(PostHogAPI.traceSpans(projectID: 1_001).body).queryNode
        let group = try #require(unfiltered["filterGroup"] as? [String: Any])
        #expect(group["type"] as? String == "AND")
        #expect((group["values"] as? [Any])?.isEmpty == true)
        // The shape that was rejected.
        #expect(unfiltered["filterGroup"] as? [Any] == nil)
    }

    @Test("filters span names through a nested group, which is where `name` lives")
    func spanNameFilterUsesTheBuiltInField() throws {
        let query = try #require(
            PostHogAPI.traceSpans(projectID: 1_001, spanNameContains: "checkout").body
        ).queryNode
        let group = try #require(query["filterGroup"] as? [String: Any])

        // `values` holds *groups*, not filters. Putting the filters straight in
        // is a second, different 400: "Input should be 'AND' or 'OR'".
        let inner = try #require(group["values"] as? [[String: Any]])
        #expect(inner.count == 1)
        #expect(inner[0]["type"] as? String == "AND")

        let filters = try #require(inner[0]["values"] as? [[String: Any]])
        #expect(filters.count == 1)
        #expect(filters[0]["key"] as? String == "name")
        #expect(filters[0]["type"] as? String == "span")
        #expect(filters[0]["operator"] as? String == "icontains")
        #expect(filters[0]["value"] as? String == "checkout")

        // No group at all when nothing was typed — an empty `icontains` would
        // still be a filter the server has to apply.
        let unfiltered = try #require(PostHogAPI.traceSpans(projectID: 1_001).body).queryNode
        let empty = try #require(unfiltered["filterGroup"] as? [String: Any])
        #expect((empty["values"] as? [Any])?.isEmpty == true)
    }

    @Test("selects error spans by OTel status code, not HTTP status")
    func errorsOnlyUsesOtelCodes() throws {
        let query = try #require(
            PostHogAPI.traceSpans(projectID: 1_001, errorsOnly: true).body
        ).queryNode
        // 2 is OTel Error. A 500 here would silently match nothing.
        #expect(query["statusCodes"] as? [Int] == [2])

        let all = try #require(PostHogAPI.traceSpans(projectID: 1_001).body).queryNode
        #expect(all["statusCodes"] == nil)
    }

    // There is no test for a tree endpoint or a breakdown endpoint. Their
    // builders are gone; what replaced them is covered by `TraceSpanTreeTests`
    // and `TraceServiceFacetTests`, which need no request at all.

    @Test("builds the endpoint usage overview and table queries")
    func endpointUsageEndpoints() throws {
        let overview = PostHogAPI.endpointsUsageOverview(projectID: 1_001, dateFrom: "-7d")
        #expect(overview.path == "/api/projects/1001/query/")
        #expect(overview.category == .query)
        #expect(try #require(overview.body).bodyText.contains("EndpointsUsageOverviewQuery"))

        let table = PostHogAPI.endpointsUsageTable(projectID: 1_001, breakdownBy: .apiKey)
        let body = try #require(table.body).bodyText
        #expect(body.contains("EndpointsUsageTableQuery"))
        // `breakdownBy` is a closed enum server-side; anything else is a 400.
        #expect(body.contains("ApiKey"))
    }

    @Test("offers exactly the four breakdown dimensions the API accepts")
    func breakdownDimensionsMatchTheServerEnum() {
        #expect(
            EndpointUsageDimension.allCases.map(\.rawValue)
                == ["Endpoint", "MaterializationType", "ApiKey", "Status"]
        )
    }
}

@Suite("Tracing access control")
struct TracingAccessTests {

    @Test("an access-denied 400 on a span query becomes a named tracing denial")
    func spanQueryDenialIsNamed() async throws {
        // This organisation has no `viewer` access to `tracing`, and PostHog
        // reports that as a 400. This is the one tracing behaviour that can be
        // proven against the real API, so it is proven end to end here.
        let body = #"{"type":"validation_error","code":"invalid_input","detail":"Access control failure. You don't have `viewer` access to the `tracing` resource."}"#
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: StubTransport(status: 400, body: body)
        )

        do {
            _ = try await client.data(for: PostHogAPI.traceSpans(projectID: 1_001))
            Issue.record("expected the tracing resource to be denied")
        } catch let error as PostHogError {
            #expect(error == .accessDenied(resource: "tracing"))
        }
    }

    @Test("a tracing denial drives the locked state, naming the resource")
    func denialDrivesLockedState() {
        let state = ResourceAccessState(failure: PostHogError.accessDenied(resource: "tracing"), resource: "tracing", defaultScope: "query:read")
        #expect(state == .denied(resource: "tracing"))
        #expect(state.isDenied)
        // The screen has to be able to say *what* is missing, not just "locked".
        #expect(state.headline(ResourceCopy(subject: "Tracing", itemNoun: "spans", emptyHint: "No spans were recorded in this window.")) == "Tracing is locked")
        #expect(state.detail(ResourceCopy(subject: "Tracing", itemNoun: "spans", emptyHint: "No spans were recorded in this window.")).contains("tracing"))
        #expect(state.detail(ResourceCopy(subject: "Tracing", itemNoun: "spans", emptyHint: "No spans were recorded in this window.")).contains("viewer"))
    }

    @Test("a denial that names no resource still locks, against tracing")
    func denialWithoutAResourceStillLocks() {
        // The resource name is scraped out of a prose message; if PostHog ever
        // rewords it the screen must still lock rather than fall through to a
        // generic failure that invites a pointless retry.
        let state = ResourceAccessState(failure: PostHogError.accessDenied(resource: nil), resource: "tracing", defaultScope: "query:read")
        #expect(state == .denied(resource: "tracing"))
    }

    @Test("an ordinary 400 stays a failure and does not masquerade as a denial")
    func plainBadRequestIsNotADenial() {
        let state = ResourceAccessState(failure: PostHogError.http(status: 400, detail: "Field required"), resource: "tracing", defaultScope: "query:read")
        #expect(!state.isDenied)
        #expect(state == .failed("Field required"))
    }

    @Test("a malformed body cannot masquerade as the tracing wall")
    func parseErrorIsNotTheWall() async throws {
        // Exactly from the documented API, 2026-01-13, in answer to `filterGroup` as
        // a bare array. This is what the tracing screen actually showed for as
        // long as that shipped: not the lock, but pydantic's own prose under
        // "Couldn't load spans". Worth pinning — a classifier lenient enough to
        // call this a denial would hide every future client bug behind a wall
        // the user cannot act on.
        let body = #"{"type":"invalid_request","code":"parse_error","detail":"JSON parse error - 1 validation error for QueryRequest\nquery.TraceSpansQuery.filterGroup\n  Input should be a valid dictionary or instance of PropertyGroupFilter [type=model_type, input_value=[], input_type=list]"}"#
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: StubTransport(status: 400, body: body)
        )

        do {
            _ = try await client.data(for: PostHogAPI.traceSpans(projectID: 1_001))
            Issue.record("expected the malformed body to be rejected")
        } catch {
            let state = ResourceAccessState(
                failure: error, resource: "tracing", defaultScope: "query:read"
            )
            #expect(!state.isDenied)
        }
    }

    @Test("a missing scope locks too, but says scope rather than resource")
    func missingScopeIsItsOwnLock() {
        // Resource access and key scope are different problems with different
        // fixes; collapsing them would send the user to the wrong settings page.
        let state = ResourceAccessState(failure: PostHogError.forbidden(missingScope: "query:read"), resource: "tracing", defaultScope: "query:read")
        #expect(state == .missingScope("query:read"))
        #expect(state.isDenied)
        #expect(state.detail(ResourceCopy(subject: "Tracing", itemNoun: "spans", emptyHint: "No spans were recorded in this window.")).contains("query:read"))
    }

    @Test("no rows is empty, not failed")
    func emptyIsNotFailure() {
        #expect(ResourceAccessState.resolved(rowCount: 0) == .empty)
        #expect(ResourceAccessState.resolved(rowCount: 3) == .loaded)
    }
}

@Suite("Trace span decoding")
struct TraceSpanDecodingTests {

    private func spans() throws -> [TraceSpan] {
        let response = try QueryResponse.decode(from: Fixture.data("trace_spans.json"))
        return TraceSpan.rows(from: response)
    }

    @Test("reads spans out of the positional query response")
    func decodesSpans() throws {
        let spans = try spans()
        #expect(spans.count == 4)

        let root = try #require(spans.first)
        #expect(root.name == "POST /demo/widgets")
        #expect(spans.map(\.kind) == ["Server", "Client", "Internal", "Server"])
        #expect(root.serviceName == "edge-service")
        #expect(root.traceID == "trace-example-widget")
        #expect(root.spanID == "span-widget-entry")
        #expect(root.parentSpanID == nil)
        #expect(root.isRoot)
        #expect(root.durationNanos == 530_000_000)
        #expect(root.status == .ok)
        #expect(root.attributes["http.route"]?.stringValue == "/demo/widgets")
    }

    @Test("keeps context spans distinguishable from the ones that matched")
    func matchedFilterIsKept() throws {
        let spans = try spans()
        // A span can be in the response purely because it shares a trace with a
        // match. Drawing it as a hit would overstate what the filter found.
        #expect(spans[0].matchedFilter)
        #expect(!spans[1].matchedFilter)
    }

    @Test("reads a span status whether it arrives as a code or a word")
    func statusAcceptsBothSpellings() throws {
        let spans = try spans()
        #expect(spans[1].status == .error)
        // Same column, string spelling.
        #expect(spans[2].status == .error)
        #expect(!spans[2].isRoot)
        #expect(spans[3].status == .error)
        #expect(spans[3].isRoot)
    }

    @Test("formats nanosecond durations at a readable scale")
    func durationFormatting() {
        #expect(TraceSpan.formatDuration(nanos: 412_000_000) == "412 ms")
        #expect(TraceSpan.formatDuration(nanos: 8_500_000) == "8.5 ms")
        #expect(TraceSpan.formatDuration(nanos: 1_450_000_000) == "1.45 s")
        #expect(TraceSpan.formatDuration(nanos: 45_200) == "45.2 µs")
        #expect(TraceSpan.formatDuration(nanos: 123) == "123 ns")
    }

    @Test("groups spans by trace, root first")
    func groupsIntoTraces() throws {
        let traces = TraceSpan.traces(from: try spans())
        #expect(traces.count == 2)
        let first = try #require(traces.first { $0.id == "trace-example-widget" })
        #expect(first.spans.count == 3)
        #expect(first.root?.name == "POST /demo/widgets")
        #expect(first.serviceName == "edge-service")
        // The trace's span is the root's, not the sum of its children's.
        #expect(first.durationNanos == 530_000_000)
        #expect(first.hasError)
    }
}

/// Builds a span exactly as `/query/` delivers one, so the tree is exercised
/// through the decoder the app actually uses rather than a hand-made struct.
private func makeSpan(
    _ spanID: String,
    parent: String? = nil,
    name: String? = nil,
    service: String = "api-gateway",
    startsAtSecond: Int = 0,
    durationNanos: Int = 1_000_000,
    trace: String = "4bf92f3577b34da6a3ce929d0e0e4736"
) -> TraceSpan {
    let columns = [
        "uuid", "trace_id", "span_id", "parent_span_id", "name",
        "service_name", "status_code", "timestamp", "duration_nano", "is_root_span",
    ]
    let values: [JSONValue] = [
        .string("uuid-\(spanID)"),
        .string(trace),
        .string(spanID),
        parent.map(JSONValue.string) ?? .null,
        .string(name ?? spanID),
        .string(service),
        .number(1),
        .string(String(format: "2026-01-12T10:00:%02d.000000Z", startsAtSecond)),
        .number(Double(durationNanos)),
        .bool(parent == nil),
    ]
    return TraceSpan(row: QueryRow(columns: columns, values: values))!
}

private extension Array where Element == TraceSpanNode {
    var allNodes: [(node: TraceSpanNode, depth: Int)] { flatMap { $0.flattened() } }
}

@Suite("Trace span tree")
struct TraceSpanTreeTests {

    @Test("nests spans under the span that started them")
    func nestsByParentSpanID() throws {
        // `TraceSpansTreeQuery` answers 400 "Unsupported query kind", so the
        // edges come from `parent_span_id`, which is on every span already.
        let spans = [
            makeSpan("root", startsAtSecond: 0, durationNanos: 400_000_000),
            makeSpan("db", parent: "root", startsAtSecond: 1, durationNanos: 200_000_000),
            makeSpan("cache", parent: "root", startsAtSecond: 3, durationNanos: 5_000_000),
            makeSpan("row-fetch", parent: "db", startsAtSecond: 2, durationNanos: 100_000_000),
        ]
        let tree = TraceSpan.tree(from: spans)

        #expect(tree.count == 1)
        let root = try #require(tree.first)
        #expect(root.span.spanID == "root")
        #expect(!root.isOrphan)
        // Children in start order — a trace is read in the order it happened,
        // not by weight.
        #expect(root.children.map(\.span.spanID) == ["db", "cache"])
        #expect(root.children.first?.children.map(\.span.spanID) == ["row-fetch"])
        // Nothing invented, nothing lost.
        #expect(tree.allNodes.count == spans.count)
    }

    @Test("keeps an orphan whose parent was truncated out of the result")
    func orphanIsPromotedNotDropped() throws {
        // The span query is capped by `limit`, and the cap lands mid-trace all
        // the time: a span whose `parent_span_id` names a span that did not come
        // back is the normal case, not a corrupt one.
        let spans = [
            makeSpan("root", startsAtSecond: 0, durationNanos: 400_000_000),
            makeSpan("db", parent: "root", startsAtSecond: 1, durationNanos: 200_000_000),
            makeSpan("stray", parent: "never-returned", startsAtSecond: 2, durationNanos: 9_000_000),
            makeSpan("stray-child", parent: "stray", startsAtSecond: 3, durationNanos: 1_000_000),
        ]
        let tree = TraceSpan.tree(from: spans)

        #expect(tree.allNodes.count == spans.count, "an orphan must not cost the trace a span")
        #expect(tree.map(\.span.spanID) == ["root", "stray"])

        let stray = try #require(tree.last)
        #expect(stray.isOrphan)
        // The subtree hanging off the orphan survives with it.
        #expect(stray.children.map(\.span.spanID) == ["stray-child"])
        #expect(stray.children.first?.isOrphan == false)
        // Nothing above it to take a share of.
        #expect(stray.shareOfParent == nil)
        // The trace's own entry span is not an orphan just because one exists.
        #expect(tree.first?.isOrphan == false)
    }

    @Test("a parent cycle terminates and still draws every span once")
    func cycleDoesNotLoop() {
        // `parent_span_id` is producer-supplied and nothing validates it. A
        // two-span loop has no entry point at all, so the spans are reachable
        // from no root and would vanish if they were not promoted.
        let spans = [
            makeSpan("a", parent: "b", startsAtSecond: 0),
            makeSpan("b", parent: "a", startsAtSecond: 1),
            makeSpan("self", parent: "self", startsAtSecond: 2),
        ]
        let tree = TraceSpan.tree(from: spans)

        let drawn = tree.allNodes.map(\.node.span.spanID)
        #expect(drawn.count == spans.count)
        #expect(Set(drawn) == ["a", "b", "self"])
    }

    @Test("reports each span's share of its parent, unclamped")
    func shareOfParent() throws {
        let spans = [
            makeSpan("root", startsAtSecond: 0, durationNanos: 100_000_000),
            makeSpan("half", parent: "root", startsAtSecond: 1, durationNanos: 50_000_000),
            // Longer than the span that started it: clock skew between services
            // and work that outlives its caller both do this, and clamping would
            // hide the one thing worth opening the trace for.
            makeSpan("overrun", parent: "root", startsAtSecond: 2, durationNanos: 150_000_000),
        ]
        let root = try #require(TraceSpan.tree(from: spans).first)

        #expect(root.shareOfParent == nil)
        #expect(root.children.first?.shareOfParent == 0.5)
        #expect((root.children.last?.shareOfParent ?? 0) > 1)
    }

    @Test("flattens with the depth a list needs to indent by")
    func flattenedCarriesDepth() {
        let spans = [
            makeSpan("root"),
            makeSpan("child", parent: "root", startsAtSecond: 1),
            makeSpan("grandchild", parent: "child", startsAtSecond: 2),
        ]
        let flat = TraceSpan.tree(from: spans).allNodes
        #expect(flat.map(\.depth) == [0, 1, 2])
        #expect(flat.map(\.node.span.spanID) == ["root", "child", "grandchild"])
    }

    @Test("builds a trace's tree from the spans it already carries")
    func traceGroupExposesItsTree() throws {
        // No request: the detail screen's call tree is the response the list
        // screen already paid for.
        let response = try QueryResponse.decode(from: Fixture.data("trace_spans.json"))
        let traces = TraceSpan.traces(from: TraceSpan.rows(from: response))
        let trace = try #require(traces.first { $0.id == "trace-example-widget" })

        let tree = trace.tree
        #expect(tree.count == 1)
        #expect(tree.first?.span.name == "POST /demo/widgets")
        #expect(tree.first?.children.map(\.span.name) == ["GET widget cache", "Render widget preview"])
        #expect(tree.allNodes.count == trace.spans.count)
    }

    @Test("an empty span list makes an empty tree rather than a crash")
    func emptyInputIsEmptyTree() {
        #expect(TraceSpan.tree(from: []).isEmpty)
    }
}

@Suite("Trace service facet")
struct TraceServiceFacetTests {

    @Test("derives the service filter from the spans in hand")
    func serviceNamesComeFromTheSpans() throws {
        // This used to be a second `/query/` request on a kind the API answers
        // with 400 "Unsupported query kind". `service_name` is on every span,
        // so the facet costs nothing.
        let response = try QueryResponse.decode(from: Fixture.data("trace_spans.json"))
        let spans = TraceSpan.rows(from: response)
        #expect(TraceSpan.serviceNames(from: spans) == ["cache-service", "edge-service", "render-service"])
    }

    @Test("deduplicates, sorts, and drops a service with no name")
    func facetIsCleanAndStable() {
        let spans = [
            makeSpan("a", service: "web"),
            makeSpan("b", parent: "a", service: "web"),
            makeSpan("c", parent: "a", service: "auth"),
            // A span can arrive with an empty `service_name`: it would render as
            // a blank menu row, and filtering by it would match nothing.
            makeSpan("d", parent: "a", service: ""),
        ]
        #expect(TraceSpan.serviceNames(from: spans) == ["auth", "web"])
        #expect(TraceSpan.serviceNames(from: []).isEmpty)
    }
}

@Suite("Endpoint usage")
struct EndpointUsageTests {

    @Test("decodes the overview metrics")
    func decodesOverview() throws {
        let overview = try EndpointUsageOverview.decode(
            from: Fixture.data("endpoints_usage_overview.json")
        )
        let requests = try #require(overview.metric(named: "example_orbit_requests"))
        #expect(requests.value == 12)
        #expect(requests.title == "Example orbit requests")
    }

    @Test("treats an absent comparison as absent, never as zero")
    func absentComparisonIsNotZero() throws {
        // `previous` and `changeFromPreviousPct` come back null here. Rendering
        // that as a 0% delta would assert a flat trend PostHog never reported.
        let overview = try EndpointUsageOverview.decode(
            from: Fixture.data("endpoints_usage_overview.json")
        )
        let requests = try #require(overview.metric(named: "example_orbit_requests"))
        #expect(requests.previous == nil)
        #expect(requests.changeFromPreviousPct == nil)
        #expect(!requests.hasComparison)
    }

    @Test("distinguishes nothing configured from nothing happening")
    func zeroMeansTwoDifferentThings() throws {
        let overview = EndpointUsageOverview(metrics: [
            EndpointUsageMetric(
                key: "example_orbit_requests",
                value: 0,
                previous: nil,
                changeFromPreviousPct: nil
            )
        ])

        // No endpoint is defined, so zero requests is a definition, not a trend.
        #expect(overview.reading(endpointCount: 0) == .noEndpointsDefined)
        // Endpoints exist and none was called: that *is* a fact about traffic.
        #expect(overview.reading(endpointCount: 3) == .noTraffic)
    }

    @Test("reports traffic once any metric is non-zero")
    func trafficReading() {
        let overview = EndpointUsageOverview(metrics: [
            EndpointUsageMetric(key: "total_requests", value: 42, previous: nil, changeFromPreviousPct: nil)
        ])
        #expect(overview.reading(endpointCount: 1) == .traffic)
        // Still meaningless without an endpoint to attribute it to.
        #expect(overview.reading(endpointCount: 0) == .noEndpointsDefined)
    }

    @Test("builds breakdown rows from the response's own column names")
    func breakdownIsColumnDriven() {
        // The project defines no endpoints, so this table's columns could not be
        // observed live. Reading them off the response instead of hard-coding a
        // guessed schema means a wrong guess cannot mislabel a number.
        let json = #"""
        {"columns":["endpoint_name","request_count","error_count"],
         "results":[["orders_daily",1200,4],["signups",90,0]]}
        """#
        let response = try! QueryResponse.decode(from: Data(json.utf8))
        let rows = EndpointUsageBreakdownRow.rows(from: response)

        #expect(rows.count == 2)
        #expect(rows[0].label == "orders_daily")
        #expect(rows[0].measures.map(\.name) == ["Request count", "Error count"])
        #expect(rows[0].measures.first?.value == 1200)
    }

    @Test("survives a response whose columns are not the ones expected")
    func breakdownToleratesAnUnknownShape() {
        let json = #"""
        {"columns":["something_new"],"results":[["only-a-label"]]}
        """#
        let response = try! QueryResponse.decode(from: Data(json.utf8))
        let rows = EndpointUsageBreakdownRow.rows(from: response)
        #expect(rows.count == 1)
        #expect(rows[0].label == "only-a-label")
        #expect(rows[0].measures.isEmpty)
    }
}
