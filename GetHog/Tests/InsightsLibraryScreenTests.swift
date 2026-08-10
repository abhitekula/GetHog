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

/// Records the result-read path without retaining anything from a real
/// project. The two deterministic responses model PostHog's cached-null then
/// blocking-computed sequence for one fictional HogQL insight.
private actor HogQLResultTransport: HTTPTransport {
    private(set) var refreshes: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let refresh = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "refresh" }?
            .value ?? "absent"
        refreshes.append(refresh)

        let result = refresh == "blocking" ? "[[17]]" : "null"
        let body = """
        {"id": 17, "name": "Synthetic pending result",
         "query": {"kind": "DataVisualizationNode", "display": "BoldNumber",
                   "source": {"kind": "HogQLQuery"}},
         "columns": ["value"], "types": [["value", "UInt64"]],
         "result": \(result)}
        """
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// Succeeds once, then holds a replacement request until the test releases it
/// as a failure. The suspension exposes the store's published state while a
/// new filter or project owns the in-flight request.
private actor SuspendedInsightReplacementTransport: HTTPTransport {
    private var requestCount = 0
    private var secondRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseSecondRequest: CheckedContinuation<Void, Never>?
    private var shouldFailSecondRequest = false

    func waitForSecondRequest() async {
        if requestCount >= 2 { return }
        await withCheckedContinuation { secondRequestWaiters.append($0) }
    }

    func failSecondRequest() {
        if let releaseSecondRequest {
            releaseSecondRequest.resume()
            self.releaseSecondRequest = nil
        } else {
            shouldFailSecondRequest = true
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        requestCount += 1
        if requestCount == 1 {
            let body = #"""
            {"count":1,"next":null,"previous":null,"results":[
              {"id":101,"name":"Project A insight",
               "query":{"source":{"kind":"TrendsQuery"}}}
            ]}
            """#
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
            )
        }

        let waiters = secondRequestWaiters
        secondRequestWaiters = []
        waiters.forEach { $0.resume() }
        if !shouldFailSecondRequest {
            await withCheckedContinuation { releaseSecondRequest = $0 }
        }
        throw URLError(.cannotConnectToHost)
    }
}

private struct FailingInsightTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}

/// Signals once the request has suspended, then relies on cooperative task
/// cancellation to release it. This distinguishes cancellation control flow
/// from a transport failure without sleeps in the test itself.
private actor SuspendedCancellationTransport: HTTPTransport {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        let waiters = startedWaiters
        startedWaiters = []
        waiters.forEach { $0.resume() }

        try await Task.sleep(for: .seconds(60))
        throw URLError(.timedOut)
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
            request: InsightsRequest(search: "signup", kind: .funnels, favoritesOnly: true)
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
        #expect(InsightsRequest(favoritesOnly: true).isFiltering)
    }

    @Test("a replacement filter withdraws old rows and provenance before suspending")
    func filterReplacementWithdrawsPublishedRows() async {
        let transport = SuspendedInsightReplacementTransport()
        let store = InsightsStore()
        let api = client(transport)
        let original = InsightsRequest()
        let replacement = InsightsRequest(search: "checkout")

        await store.load(
            client: api,
            projectID: 1,
            request: original,
            projectName: "Project A"
        )
        #expect(store.insights.map(\.id) == [101])
        #expect(store.loadedProjectID == 1)
        #expect(store.loadedRequest == original)
        #expect(store.loadedProjectName == "Project A")

        let load = Task { @MainActor in
            await store.load(
                client: api,
                projectID: 1,
                request: replacement,
                projectName: "Project A"
            )
        }
        await transport.waitForSecondRequest()

        #expect(store.insights.isEmpty)
        #expect(store.loadedProjectID == nil)
        #expect(store.loadedRequest == nil)
        #expect(store.loadedProjectName == nil)
        #expect(!store.publishes(projectID: 1, request: replacement))

        await transport.failSecondRequest()
        await load.value
        #expect(store.failure != nil)
        #expect(store.insights.isEmpty)
        #expect(store.loadedRequest == nil)
    }

    @Test("a failed project replacement cannot publish the previous project identity")
    func projectReplacementFailureWithdrawsPublishedRows() async {
        let transport = SuspendedInsightReplacementTransport()
        let store = InsightsStore()
        let api = client(transport)
        let request = InsightsRequest()

        await store.load(
            client: api,
            projectID: 1,
            request: request,
            projectName: "Project A"
        )
        let load = Task { @MainActor in
            await store.load(
                client: api,
                projectID: 2,
                request: request,
                projectName: "Project B"
            )
        }
        await transport.waitForSecondRequest()

        #expect(store.insights.isEmpty)
        #expect(store.loadedProjectID == nil)
        #expect(store.loadedProjectName == nil)
        #expect(!store.publishes(projectID: 2, request: request))

        await transport.failSecondRequest()
        await load.value
        #expect(store.failure != nil)
        #expect(store.loadedProjectID == nil)
        #expect(store.loadedProjectName == nil)
    }

    @Test("a first-page failure is visible only to the project and filter that produced it")
    func firstPageFailureHasScope() async {
        let store = InsightsStore()
        let failedRequest = InsightsRequest(search: "checkout")

        await store.load(
            client: client(FailingInsightTransport()),
            projectID: 1,
            request: failedRequest
        )

        #expect(store.failure != nil)
        #expect(store.failure(projectID: 1, request: failedRequest) != nil)
        // Models the debounce interval: controls already answer a new request,
        // while that request has not entered `store.load` yet.
        #expect(store.failure(projectID: 1, request: InsightsRequest(search: "funnel")) == nil)
        #expect(store.failure(projectID: 2, request: failedRequest) == nil)
    }

    @Test("cooperative first-page cancellation does not become a visible failure")
    func cancelledFirstPageHasNoFailure() async {
        let transport = SuspendedCancellationTransport()
        let store = InsightsStore()
        let request = InsightsRequest(search: "superseded")
        let load = Task { @MainActor in
            await store.load(
                client: client(transport),
                projectID: 1,
                request: request
            )
        }

        await transport.waitUntilStarted()
        load.cancel()
        await load.value

        #expect(store.failure == nil)
        #expect(store.failure(projectID: 1, request: request) == nil)
        #expect(!store.isLoading)
    }

    @Test("compact selection is withdrawn synchronously outside the published scope")
    func compactSelectionRequiresPublishedScope() {
        #expect(
            InsightsSelectionAuthority.current(
                selectedID: 101,
                publishesCurrentScope: true
            ) == 101
        )
        #expect(
            InsightsSelectionAuthority.current(
                selectedID: 101,
                publishesCurrentScope: false
            ) == nil
        )
    }

    // MARK: - Presentation

    /// Starred first, and the rest in the order the server sent them — a
    /// partition rather than a sort, so PostHog's own ordering survives inside
    /// each half and a row keeps its place when the next page arrives.
    @Test("puts favorites first without reordering anything else")
    func favoritesLeadTheList() async throws {
        let store = InsightsStore()
        await store.load(
            client: client(PagingTransport(count: 6)),
            projectID: 1,
            request: InsightsRequest()
        )

        #expect(store.favorites.map(\.id) == [1])
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

    @Test("overview ranks loaded kinds, including unknown query shapes")
    func overviewKindGroups() throws {
        let insights = try JSONDecoder().decode(
            [Insight].self,
            from: Data(#"""
            [
              {"id":1,"name":"Created trend","favorited":true,
               "created_at":"2026-01-04T12:00:00Z",
               "query":{"source":{"kind":"TrendsQuery"}}},
              {"id":2,"name":"Newest trend","favorited":false,
               "last_modified_at":"2026-01-03T12:00:00Z",
               "query":{"source":{"kind":"TrendsQuery"}}},
              {"id":3,"name":"Unknown shape","favorited":true,
               "last_modified_at":"2026-01-02T12:00:00Z",
               "query":{"source":{"kind":"SyntheticQuery"}}}
            ]
            """#.utf8)
        )

        let facts = InsightOverviewFacts(
            insights: insights,
            total: 9,
            hasMore: true,
            isFiltering: false
        )

        #expect(facts.loadedCount == 3)
        #expect(facts.favoriteCount == 2)
        #expect(facts.kindCount == 2)
        #expect(facts.kindGroups.map(\.title) == ["Trends", "Other"])
        #expect(facts.kindGroups.map(\.count) == [2, 1])
        #expect(facts.kindGroups.first?.newest.id == 1)
        #expect(facts.recentlyEdited.map(\.id) == [2, 3])
        #expect(facts.coverageSummary == "Showing 3 of 9 insights.")
        #expect(facts.qualifiesMetricsAsLoaded)
    }

    @Test("overview labels filtered rows as loaded even when every match arrived")
    func overviewFilteredScope() throws {
        let insight = try JSONDecoder().decode(
            Insight.self,
            from: Data(#"""
            {"id":7,"name":"Only match","query":{"source":{"kind":"FunnelsQuery"}}}
            """#.utf8)
        )
        let facts = InsightOverviewFacts(
            insights: [insight],
            total: 1,
            hasMore: false,
            isFiltering: true
        )

        #expect(facts.coverageSummary == "1 matching insight.")
        #expect(facts.qualifiesMetricsAsLoaded)
    }

    @Test("overview accessibility says the same loaded count as the visible kind row")
    func overviewKindAccessibilityIncludesCount() {
        #expect(
            InsightOverviewAccessibility.spokenSummary(
                title: "Trends",
                subtitle: "3 insights loaded",
                footnote: "Newest edited yesterday"
            ) == "Trends, 3 insights loaded, Newest edited yesterday"
        )
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

    /// A computed empty HogQL result is a real answer. A null result is the
    /// separate state that may justify the detail screen's one computation.
    @Test("HogQL empty is settled while null is uncomputed")
    func hogQLEmptyAndNullStayDistinct() throws {
        let empty = try JSONDecoder().decode(
            Insight.self,
            from: Data(#"{"id": 3, "query": {"kind": "DataVisualizationNode", "display": "ActionsTable", "source": {"kind": "HogQLQuery"}}, "columns": ["value"], "types": [["value", "UInt64"]], "result": []}"#.utf8)
        )
        let uncomputed = try JSONDecoder().decode(
            Insight.self,
            from: Data(#"{"id": 4, "query": {"kind": "DataVisualizationNode", "display": "ActionsTable", "source": {"kind": "HogQLQuery"}}, "columns": ["value"], "types": [["value", "UInt64"]], "result": null}"#.utf8)
        )

        #expect(empty.isDrawableKind)
        #expect(empty.hasDrawableResult)
        #expect(uncomputed.isDrawableKind)
        #expect(!uncomputed.hasDrawableResult)
        if case .hogQL(let visualization) = empty.renderModel {
            #expect(visualization.rows == [])
        } else {
            Issue.record("expected .hogQL, got \(empty.renderModel)")
        }
    }

    /// Proves the distinction at the network boundary, not only in the model:
    /// `[]` performs no read, while `null` pays for cache lookup and then exactly
    /// one blocking computation.
    @Test("only an uncomputed HogQL result reaches the network")
    func onlyUncomputedHogQLLoadsAndComputes() async throws {
        func decode(_ result: String) throws -> Insight {
            try JSONDecoder().decode(
                Insight.self,
                from: Data(
                    """
                    {"id": 17, "query": {
                       "kind": "DataVisualizationNode", "display": "BoldNumber",
                       "source": {"kind": "HogQLQuery"}},
                     "columns": ["value"], "types": [["value", "UInt64"]],
                     "result": \(result)}
                    """.utf8
                )
            )
        }

        let settledTransport = HogQLResultTransport()
        let settledStore = SavedInsightStore()
        settledStore.seed(try decode("[]"))
        await settledStore.loadResults(client: client(settledTransport), projectID: 1)
        #expect(await settledTransport.refreshes == [])

        let pendingTransport = HogQLResultTransport()
        let pendingStore = SavedInsightStore()
        pendingStore.seed(try decode("null"))
        await pendingStore.loadResults(client: client(pendingTransport), projectID: 1)
        #expect(await pendingTransport.refreshes == ["force_cache", "blocking"])
        #expect(pendingStore.didCompute)
        #expect(pendingStore.insight?.hasDrawableResult == true)
    }

    @Test("intent reduction uses only a HogQL bold-number display")
    func hogQLIntentReductionIsUnambiguous() throws {
        func insight(display: String) throws -> Insight {
            try JSONDecoder().decode(
                Insight.self,
                from: Data(
                    """
                    {"id": 5, "name": "Synthetic headline", "query": {
                      "kind": "DataVisualizationNode", "display": "\(display)",
                      "source": {"kind": "HogQLQuery"}},
                     "columns": ["value"], "types": [["value", "UInt64"]],
                     "result": [[42]]}
                    """.utf8
                )
            )
        }

        let boldInsight = try insight(display: "BoldNumber")
        let tableInsight = try insight(display: "ActionsTable")
        let headline = try #require(IntentMetric(insight: boldInsight, fallbackTitle: "Metric"))
        #expect(headline.displayValue == "42")
        #expect(IntentMetric(insight: tableInsight, fallbackTitle: "Metric") == nil)
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
