import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// Serves a page of insights per request, recording what was asked for.
///
/// The point of a stub here rather than the demo transport is the paging: the
/// demo answers every `/insights/` *list* request with the same five-row fixture
/// whatever `offset` it was given — it narrows only when the request carries a
/// `short_id` — which is exactly the pathological case `InsightsStore` has to
/// survive and therefore cannot be the thing that proves it pages correctly.
private actor PagingTransport: HTTPTransport {
    /// Every id the collection holds, in order.
    private let ids: [Int]
    /// Whether to keep claiming another page exists after the last row, which is
    /// what the demo fixture does.
    private let alwaysClaimsMore: Bool
    private(set) var requestedURLs: [URL] = []

    init(count: Int, alwaysClaimsMore: Bool = false) {
        self.ids = Array(1...max(count, 1))
        self.alwaysClaimsMore = alwaysClaimsMore
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        requestedURLs.append(url)

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let limit = value("limit").flatMap(Int.init) ?? 100
        // The fixture's own defect, reproduced on demand: always answer with the
        // first page regardless of what was asked for.
        let offset = alwaysClaimsMore ? 0 : (value("offset").flatMap(Int.init) ?? 0)

        let slice = Array(ids.dropFirst(offset).prefix(limit))
        let hasMore = alwaysClaimsMore || offset + slice.count < ids.count
        let rows = slice.map { id in
            """
            {"id": \(id), "short_id": "id\(id)", "name": "Insight \(id)",
             "query": {"kind": "InsightVizNode", "source": {"kind": "TrendsQuery"}},
             "deleted": false, "favorited": \(id == 1 ? "true" : "false"),
             "last_modified_at": "2026-01-09T12:00:00Z"}
            """
        }
        let body = """
        {"count": \(ids.count),
         "next": \(hasMore ? "\"https://us.posthog.com/next\"" : "null"),
         "previous": null,
         "results": [\(rows.joined(separator: ","))]}
        """
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private func client(_ transport: some HTTPTransport) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
        transport: transport
    )
}

@Suite("Insights library")
@MainActor
struct InsightsLibraryScreenTests {

    // MARK: - Paging

    /// 140 saved insights against a 50-row page is three requests, and the
    /// screen has to make all three. A single `limit=100` — the app's default
    /// everywhere else — would silently lose 40 of them.
    @Test("pages through a collection larger than one request")
    func pagesThroughTheWholeCollection() async throws {
        let transport = PagingTransport(count: 140)
        let store = InsightsStore()
        let api = client(transport)

        await store.load(client: api, projectID: 1, request: InsightsRequest())
        #expect(store.insights.count == 50)
        #expect(store.total == 140)
        #expect(store.hasMore)

        await store.loadMore(client: api, projectID: 1)
        #expect(store.insights.count == 100)
        #expect(store.hasMore)

        await store.loadMore(client: api, projectID: 1)
        #expect(store.insights.count == 140)
        // The server said so; the screen stops asking.
        #expect(!store.hasMore)

        // Every id exactly once, in order.
        #expect(store.insights.map(\.id) == Array(1...140))
    }

    /// The guard that makes the demo survivable — and any server that repeats a
    /// page. `DemoTransport` answers every `/insights/` list request with the
    /// same five-row fixture *including its `next` link*, so a store that
    /// trusted the server would append those five rows forever. (It does drop
    /// that link for a request naming a `short_id`, which is a single-row lookup
    /// and never paged.)
    @Test("stops when a page adds nothing new, even if the server claims more")
    func stopsOnARepeatedPage() async throws {
        let transport = PagingTransport(count: 5, alwaysClaimsMore: true)
        let store = InsightsStore()
        let api = client(transport)

        await store.load(client: api, projectID: 1, request: InsightsRequest())
        #expect(store.insights.count == 5)
        #expect(store.hasMore)

        await store.loadMore(client: api, projectID: 1)
        // Same five rows came back. Nothing appended, and the list ends rather
        // than growing without ever showing a sixth insight.
        #expect(store.insights.count == 5)
        #expect(!store.hasMore)

        // And a second attempt is a no-op rather than another request.
        let before = await transport.requestedURLs.count
        await store.loadMore(client: api, projectID: 1)
        #expect(await transport.requestedURLs.count == before)
    }

    @Test("asks for the app's page size rather than the catalogue default")
    func usesItsOwnPageSize() async throws {
        let transport = PagingTransport(count: 200)
        let store = InsightsStore()
        await store.load(client: client(transport), projectID: 1, request: InsightsRequest())

        let first = try #require(await transport.requestedURLs.first)
        let items = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains { $0.name == "limit" && $0.value == "50" })
        // Not `offset=0`: the first page's URL has to match the unfiltered one
        // byte for byte or the response cache never hits.
        #expect(!items.contains { $0.name == "offset" })
    }

    // MARK: - Filtering

    /// Every filter is a query parameter, because the collection is 375 KB and
    /// pulling all of it to filter in memory is the trade the search screen can
    /// afford and this one cannot.
    @Test("sends every filter to the server rather than filtering locally")
    func filtersReachTheServer() async throws {
        let transport = PagingTransport(count: 10)
        let store = InsightsStore()
        await store.load(
            client: client(transport),
            projectID: 1,
            request: InsightsRequest(search: "signup", kind: .funnels, favouritesOnly: true)
        )

        let url = try #require(await transport.requestedURLs.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains { $0.name == "search" && $0.value == "signup" })
        #expect(items.contains { $0.name == "insight" && $0.value == "FUNNELS" })
        #expect(items.contains { $0.name == "favorited" && $0.value == "true" })
    }

    /// Drives which empty state the screen shows, and the two are not
    /// interchangeable: "this project has no saved insights" is about the
    /// project, "nothing matched" is about three controls the reader can undo.
    @Test("knows whether anything is narrowing the list")
    func knowsWhenItIsFiltering() {
        #expect(!InsightsRequest().isFiltering)
        // Whitespace is not a search term. Sending it would narrow the list to
        // nothing while the field looks empty.
        #expect(!InsightsRequest(search: "   ").isFiltering)
        #expect(InsightsRequest(search: "signup").isFiltering)
        #expect(InsightsRequest(kind: .trends).isFiltering)
        #expect(InsightsRequest(favouritesOnly: true).isFiltering)
    }

    // MARK: - Presentation

    /// Starred first, and the rest in the order the server sent them — a
    /// partition rather than a sort, so PostHog's own ordering survives inside
    /// each half and a row keeps its place when the next page arrives.
    @Test("puts favourites first without reordering anything else")
    func favouritesLeadTheList() async throws {
        let store = InsightsStore()
        await store.load(
            client: client(PagingTransport(count: 6)),
            projectID: 1,
            request: InsightsRequest()
        )

        #expect(store.favourites.map(\.id) == [1])
        #expect(store.others.map(\.id) == [2, 3, 4, 5, 6])
    }

    /// A list that stops at 50 of 140 with no explanation is silent truncation,
    /// and this screen truncates by design on every project with more than a
    /// page.
    @Test("states how much of the collection is on screen")
    func statesItsOwnCoverage() async throws {
        let store = InsightsStore()
        let api = client(PagingTransport(count: 140))

        await store.load(client: api, projectID: 1, request: InsightsRequest())
        #expect(store.coverageSummary == "Showing 50 of 140 insights.")

        // No summary at all before anything has loaded, rather than "0 insights"
        // over a skeleton.
        #expect(InsightsStore().coverageSummary == nil)
    }

    // MARK: - Result readiness

    /// The distinction the detail screen's escalation rests on. A trends insight
    /// with an empty `result` decodes to a perfectly valid model of nothing, and
    /// drawing it produces a blank plot rather than an error.
    @Test("an empty result is not a drawable one")
    func emptyResultIsNotDrawable() throws {
        let empty = try JSONDecoder().decode(
            Insight.self,
            from: Data("""
            {"id": 1, "query": {"kind": "InsightVizNode", "source": {"kind": "TrendsQuery"}},
             "result": null}
            """.utf8)
        )
        #expect(!empty.hasDrawableResult)
        // Worth a query: trends is a kind this app draws.
        #expect(empty.isDrawableKind)

        let populated = try JSONDecoder().decode(
            Insight.self,
            from: Data("""
            {"id": 2, "query": {"kind": "InsightVizNode", "source": {"kind": "TrendsQuery"}},
             "result": [{"label": "$pageview", "count": 3,
                         "data": [1, 1, 1], "days": ["2026-01-01", "2026-01-02", "2026-01-03"]}]}
            """.utf8)
        )
        #expect(populated.hasDrawableResult)
    }

    /// Five of the project's 140 insights are HogQL, which has no render shape
    /// here. Escalating one to a blocking query would spend the organisation's
    /// budget to produce the same "not drawn on mobile yet" card.
    @Test("a kind with no chart is settled, never recomputed")
    func unsupportedKindIsNotWorthComputing() throws {
        let hogQL = try JSONDecoder().decode(
            Insight.self,
            from: Data(#"{"id": 3, "query": {"kind": "DataTableNode", "source": {"kind": "HogQLQuery"}}}"#.utf8)
        )
        #expect(!hogQL.isDrawableKind)
        // Settled: there is nothing a recomputation could add.
        #expect(hogQL.hasDrawableResult)
        if case .unsupported = hogQL.renderModel {} else {
            Issue.record("expected .unsupported, got \(hogQL.renderModel)")
        }
    }

    /// A link carries one string and it may be either spelling. The parser does
    /// not classify it, so this is the only place that does — and it must never
    /// coerce, or an all-digit handle would select a different insight.
    @Test("matches a link identifier in either spelling")
    func matchesEitherIdentifierSpelling() throws {
        let insight = try JSONDecoder().decode(
            Insight.self,
            from: Data(#"{"id": 710101, "short_id": "example-meteor-report"}"#.utf8)
        )
        #expect(insight.matches("example-meteor-report"))
        #expect(insight.matches("710101"))
        #expect(!insight.matches("somethingelse"))
    }
}
