import Foundation
import GetHogKit
import Testing

@testable import GetHog

private struct InsightPreviewReply: Sendable {
    let statusCode: Int
    let data: Data

    static func ok(_ data: Data) -> Self {
        Self(statusCode: 200, data: data)
    }

    static func status(_ statusCode: Int, _ body: String) -> Self {
        Self(statusCode: statusCode, data: Data(body.utf8))
    }
}

private actor ControlledInsightPreviewTransport: HTTPTransport {
    private let replies: [InsightPreviewReply]
    private let heldRequests: Set<Int>
    private let deliversCancelledResponses: Bool
    private var requests: [URLRequest] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var cancellationCount = 0

    init(
        replies: [InsightPreviewReply],
        heldRequests: Set<Int> = [],
        deliversCancelledResponses: Bool = false
    ) {
        self.replies = replies
        self.heldRequests = heldRequests
        self.deliversCancelledResponses = deliversCancelledResponses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let sequence = requests.count
        guard replies.indices.contains(sequence - 1) else {
            throw PostHogError.transport("Missing synthetic insight preview reply")
        }
        if heldRequests.contains(sequence) {
            await withCheckedContinuation { continuation in
                continuations[sequence] = continuation
            }
        }
        if Task.isCancelled {
            cancellationCount += 1
            if !deliversCancelledResponses {
                throw CancellationError()
            }
        }
        let reply = replies[sequence - 1]
        return (
            reply.data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: reply.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func waitForRequests(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }

    func release(_ sequence: Int) {
        continuations.removeValue(forKey: sequence)?.resume()
    }

    func requestCount() -> Int { requests.count }
    func cancelledRequests() -> Int { cancellationCount }

    func requestCount(refresh: String) -> Int {
        requests.count { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains { $0.name == "refresh" && $0.value == refresh } == true
        }
    }
}

private actor InsightPreviewActivationProbe {
    private var didReturn = false

    func markReturned() {
        didReturn = true
    }

    func hasReturned() -> Bool { didReturn }
}

@Suite("Insight Quick Preview")
@MainActor
struct InsightQuickPreviewTests {
    @Test("list metadata is complete before cached enrichment arrives")
    func immediateMetadataIsComplete() throws {
        let summary = try Self.insight(Self.metadataInsight)

        let presentation = InsightQuickPreviewPresentation(summary: summary, enriched: nil)

        #expect(
            presentation == InsightQuickPreviewPresentation(
                title: "Synthetic activation trend",
                description: "A fictional product activation signal.",
                queryKind: "Trends",
                displayType: "Bold number",
                isFavorite: true,
                dashboardCount: 2,
                lastModifiedAt: Date(timeIntervalSince1970: 1_787_738_400),
                cacheState: "Cached result",
                result: nil
            )
        )
    }

    @Test("the accessibility summary includes metadata and semantic enrichment")
    func accessibilitySummaryIsComplete() throws {
        let summary = try Self.insight(Self.metadataInsight)
        let enriched = try Self.insight(Self.headlineInsight)

        let presentation = InsightQuickPreviewPresentation(
            summary: summary,
            enriched: enriched
        )

        #expect(
            presentation.accessibilitySummary
                == "Synthetic activation trend. A fictional product activation signal. Trends. Bold number. Favorite. On 2 dashboards. Edited Aug 26, 2026. Cached result. Cached headline, 12.5K."
        )
    }

    @Test("a bold-number result becomes a formatted headline")
    func headlineResultIsHonest() throws {
        let insight = try Self.insight(Self.headlineInsight)
        #expect(InsightQuickPreviewResult(insight: insight) == .headline("12.5K"))
    }

    @Test("a populated chart reports its display and series count")
    func chartResultIsHonest() throws {
        let insight = try Self.insight(Self.chartInsight)
        #expect(
            InsightQuickPreviewResult(insight: insight)
                == .chart(display: "Line", seriesCount: 2)
        )
    }

    @Test("a computed HogQL table reports displayed rows and columns")
    func tableResultIsHonest() throws {
        let insight = try Self.insight(Self.tableInsight)
        #expect(InsightQuickPreviewResult(insight: insight) == .table(rows: 2, columns: 2))
    }

    @Test("a nonempty heatmap with no plottable cells falls back to its real table")
    func unplottableHeatmapFallsBackToTable() throws {
        let insight = try Self.insight(Self.unplottableHeatmapInsight)
        #expect(InsightQuickPreviewResult(insight: insight) == .table(rows: 1, columns: 3))
    }

    @Test("a computed result with no values is empty")
    func emptyResultIsHonest() throws {
        let insight = try Self.insight(Self.emptyInsight)
        #expect(InsightQuickPreviewResult(insight: insight) == .empty)
    }

    @Test("an uncomputed HogQL result is pending rather than empty")
    func pendingResultIsHonest() throws {
        let insight = try Self.insight(Self.pendingInsight)
        #expect(InsightQuickPreviewResult(insight: insight) == .pending)
    }

    @Test("an unknown query kind stays unsupported")
    func unsupportedResultIsHonest() throws {
        let insight = try Self.insight(Self.unsupportedInsight)
        #expect(InsightQuickPreviewResult(insight: insight) == .unsupported)
    }

    @Test("same-scope activations join one store-owned request")
    func sameScopeActivationsJoin() async {
        let transport = ControlledInsightPreviewTransport(
            replies: [.ok(Self.cachedInsight(id: 7_201, title: "Joined preview"))],
            heldRequests: [1]
        )
        let store = InsightQuickPreviewStore()
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let client = Self.client(transport: transport)

        let first = Task { await store.activate(client: client, scope: scope) }
        await transport.waitForRequests(1)
        let second = Task { await store.activate(client: client, scope: scope) }
        await Task.yield()
        #expect(await transport.requestCount() == 1)

        await transport.release(1)
        await first.value
        await second.value

        #expect(await transport.requestCount() == 1)
        guard case .loaded(let insight, _) = store.state(for: scope) else {
            Issue.record("Joined activation did not publish the cached insight.")
            return
        }
        #expect(insight.title == "Joined preview")
    }

    @Test("cancelling the sole activation waiter cancels and fences its flight")
    func soleCancelledWaiterCancelsFlight() async {
        let transport = ControlledInsightPreviewTransport(
            replies: [.ok(Self.cachedInsight(id: 7_201, title: "Late dismissed preview"))],
            heldRequests: [1],
            deliversCancelledResponses: true
        )
        let store = InsightQuickPreviewStore()
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let probe = InsightPreviewActivationProbe()
        let activation = Task {
            await store.activate(client: Self.client(transport: transport), scope: scope)
            await probe.markReturned()
        }
        await transport.waitForRequests(1)

        activation.cancel()
        #expect(await Self.waitForReturn(probe))
        guard case .idle = store.state(for: scope) else {
            Issue.record("A dismissed sole activation left visible loading or loaded state.")
            await transport.release(1)
            await activation.value
            return
        }

        await transport.release(1)
        #expect(await Self.waitForCancellation(transport))
        await activation.value
        guard case .idle = store.state(for: scope) else {
            Issue.record("A late response published after sole-waiter cancellation.")
            return
        }
        #expect(await transport.requestCount() == 1)
    }

    @Test("cancelling one same-scope waiter preserves the remaining waiter")
    func cancellingOneJoinedWaiterPreservesFlight() async {
        let transport = ControlledInsightPreviewTransport(
            replies: [.ok(Self.cachedInsight(id: 7_201, title: "Shared preview"))],
            heldRequests: [1],
            deliversCancelledResponses: true
        )
        let store = InsightQuickPreviewStore()
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let client = Self.client(transport: transport)
        let cancelledProbe = InsightPreviewActivationProbe()
        let cancelled = Task {
            await store.activate(client: client, scope: scope)
            await cancelledProbe.markReturned()
        }
        await transport.waitForRequests(1)
        let remaining = Task { await store.activate(client: client, scope: scope) }
        await Task.yield()
        await Task.yield()

        cancelled.cancel()
        #expect(await Self.waitForReturn(cancelledProbe))
        guard case .loading = store.state(for: scope) else {
            Issue.record("Cancelling one joiner ended the shared flight.")
            await transport.release(1)
            await cancelled.value
            await remaining.value
            return
        }

        await transport.release(1)
        await cancelled.value
        await remaining.value

        #expect(await transport.requestCount() == 1)
        #expect(await transport.cancelledRequests() == 0)
        guard case .loaded(let insight, _) = store.state(for: scope) else {
            Issue.record("The legitimate same-scope waiter did not receive the shared result.")
            return
        }
        #expect(insight.title == "Shared preview")
    }

    @Test("a completed preview is reused for less than five minutes")
    func completedPreviewIsReused() async {
        var now = Date(timeIntervalSince1970: 1_787_738_400)
        let transport = ControlledInsightPreviewTransport(
            replies: [.ok(Self.cachedInsight(id: 7_201, title: "Reusable preview"))]
        )
        let store = InsightQuickPreviewStore(now: { now })
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let client = Self.client(transport: transport)

        await store.activate(client: client, scope: scope)
        now.addTimeInterval(299)
        await store.activate(client: client, scope: scope)

        #expect(await transport.requestCount() == 1)
        guard case .loaded(_, let loadedAt) = store.state(for: scope) else {
            Issue.record("The reusable insight preview did not remain loaded.")
            return
        }
        #expect(loadedAt == Date(timeIntervalSince1970: 1_787_738_400))
    }

    @Test("a drawable preview supplies detail without another cached-result GET")
    func drawablePreviewSuppliesDetailFromResponseCache() async throws {
        let cache = ResponseCache(
            subdirectory: "InsightPreviewDetailTests-\(UUID().uuidString)"
        )
        let transport = ControlledInsightPreviewTransport(
            replies: [
                .ok(Self.cachedInsight(id: 7_201, title: "Preview result")),
                .ok(Self.cachedInsight(id: 7_201, title: "Duplicate detail result")),
            ]
        )
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let client = Self.client(
            transport: transport,
            cache: cache,
            cacheNamespace: scope.authority.authSessionID.uuidString
        )
        let preview = InsightQuickPreviewStore()
        let detail = SavedInsightStore()
        detail.seed(try Self.insight(Self.detailSeedInsight))

        await preview.activate(client: client, scope: scope)
        await detail.loadResults(client: client, projectID: 1)

        #expect(await transport.requestCount(refresh: "force_cache") == 1)
        #expect(await transport.requestCount(refresh: "blocking") == 0)
        #expect(detail.insight?.title == "Preview result")
        #expect(detail.insight?.hasDrawableResult == true)
        await cache.clear()
    }

    @Test("an empty preview is reused before detail performs one intentional compute")
    func emptyPreviewIsReusedBeforeIntentionalCompute() async throws {
        let cache = ResponseCache(
            subdirectory: "InsightPreviewComputeTests-\(UUID().uuidString)"
        )
        let empty = Data(Self.detailSeedInsight.utf8)
        let computed = Self.cachedInsight(id: 7_201, title: "Computed detail result")
        let transport = ControlledInsightPreviewTransport(
            replies: [.ok(empty), .ok(computed)]
        )
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let client = Self.client(
            transport: transport,
            cache: cache,
            cacheNamespace: scope.authority.authSessionID.uuidString
        )
        let preview = InsightQuickPreviewStore()
        let detail = SavedInsightStore()
        detail.seed(try Self.insight(Self.detailSeedInsight))

        await preview.activate(client: client, scope: scope)
        await detail.loadResults(client: client, projectID: 1)

        #expect(await transport.requestCount(refresh: "force_cache") == 1)
        #expect(await transport.requestCount(refresh: "blocking") == 1)
        #expect(await transport.requestCount() == 2)
        #expect(detail.insight?.title == "Computed detail result")
        #expect(detail.insight?.hasDrawableResult == true)
        #expect(detail.didCompute)
        await cache.clear()
    }

    @Test("the five-minute expiry triggers one replacement request")
    func expiredPreviewReloadsOnce() async {
        var now = Date(timeIntervalSince1970: 1_787_738_400)
        let transport = ControlledInsightPreviewTransport(
            replies: [
                .ok(Self.cachedInsight(id: 7_201, title: "Initial preview")),
                .ok(Self.cachedInsight(id: 7_201, title: "Replacement preview")),
            ]
        )
        let store = InsightQuickPreviewStore(now: { now })
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let client = Self.client(transport: transport)

        await store.activate(client: client, scope: scope)
        now.addTimeInterval(300)
        await store.activate(client: client, scope: scope)

        #expect(await transport.requestCount() == 2)
        guard case .loaded(let insight, let loadedAt) = store.state(for: scope) else {
            Issue.record("The expired insight preview was not replaced.")
            return
        }
        #expect(insight.title == "Replacement preview")
        #expect(loadedAt == now)
    }

    @Test("changing the insight cancels the outgoing request without an error")
    func objectChangeCancelsOutgoingRequest() async {
        let transport = ControlledInsightPreviewTransport(
            replies: [
                .ok(Self.cachedInsight(id: 7_201, title: "Cancelled preview")),
                .ok(Self.cachedInsight(id: 7_202, title: "Current preview")),
            ],
            heldRequests: [1]
        )
        let store = InsightQuickPreviewStore()
        let client = Self.client(transport: transport)
        let first = Task {
            await store.activate(
                client: client,
                scope: Self.scope(projectID: 1, insightID: 7_201)
            )
        }
        await transport.waitForRequests(1)

        let currentScope = Self.scope(projectID: 1, insightID: 7_202)
        await store.activate(client: client, scope: currentScope)
        await transport.release(1)
        await first.value

        #expect(await transport.requestCount() == 2)
        #expect(await transport.cancelledRequests() == 1)
        guard case .loaded(let insight, _) = store.state(for: currentScope) else {
            Issue.record("Cancellation surfaced as a visible preview error.")
            return
        }
        #expect(insight.id == 7_202)
    }

    @Test("authority fencing hides old content and rejects its late response")
    func authorityChangeRejectsLateResponse() async {
        let oldScope = Self.scope(
            projectID: 1,
            insightID: 7_201,
            authSessionID: UUID(uuidString: "018F9000-0000-7000-8000-000000000711")!
        )
        let newScope = Self.scope(
            projectID: 1,
            insightID: 7_201,
            authSessionID: UUID(uuidString: "018F9000-0000-7000-8000-000000000712")!
        )
        let transport = ControlledInsightPreviewTransport(
            replies: [
                .ok(Self.cachedInsight(id: 7_201, title: "Late authority preview")),
                .ok(Self.cachedInsight(id: 7_201, title: "Current authority preview")),
            ],
            heldRequests: [1],
            deliversCancelledResponses: true
        )
        let store = InsightQuickPreviewStore()
        let client = Self.client(transport: transport)
        let oldActivation = Task { await store.activate(client: client, scope: oldScope) }
        await transport.waitForRequests(1)

        guard case .idle = store.state(for: newScope) else {
            Issue.record("The replacement authority could see outgoing content.")
            return
        }
        await store.activate(client: client, scope: newScope)
        await transport.release(1)
        await oldActivation.value

        guard case .loaded(let insight, _) = store.state(for: newScope) else {
            Issue.record("The replacement authority lost publication ownership.")
            return
        }
        #expect(insight.title == "Current authority preview")
    }

    @Test("public invalidation clears state and rejects a late response")
    func invalidationRejectsLateResponse() async {
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let transport = ControlledInsightPreviewTransport(
            replies: [.ok(Self.cachedInsight(id: 7_201, title: "Late invalidated preview"))],
            heldRequests: [1],
            deliversCancelledResponses: true
        )
        let store = InsightQuickPreviewStore()
        let activation = Task {
            await store.activate(client: Self.client(transport: transport), scope: scope)
        }
        await transport.waitForRequests(1)

        store.invalidate()
        guard case .idle = store.state(for: scope) else {
            Issue.record("Invalidation did not clear the visible state.")
            return
        }
        await transport.release(1)
        await activation.value

        guard case .idle = store.state(for: scope) else {
            Issue.record("A late response published after invalidation.")
            return
        }
    }

    @Test("an unavailable preview can be retried deliberately")
    func unavailablePreviewRecoversOnRetry() async {
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let transport = ControlledInsightPreviewTransport(
            replies: [
                .status(503, #"{"detail":"Synthetic preview failure"}"#),
                .ok(Self.cachedInsight(id: 7_201, title: "Recovered preview")),
            ]
        )
        let store = InsightQuickPreviewStore()
        let client = Self.client(transport: transport)

        await store.activate(client: client, scope: scope)
        guard case .unavailable = store.state(for: scope) else {
            Issue.record("The failed preview was not unavailable.")
            return
        }
        await store.activate(client: client, scope: scope)

        guard case .loaded(let insight, _) = store.state(for: scope) else {
            Issue.record("A deliberate retry did not recover the preview.")
            return
        }
        #expect(insight.title == "Recovered preview")
        #expect(await transport.requestCount() == 2)
    }

    @Test("an expiry reload retains the prior value and marks it stale on failure")
    func expiryFailureRetainsStaleValue() async {
        let loadedAt = Date(timeIntervalSince1970: 1_787_738_400)
        var now = loadedAt
        let scope = Self.scope(projectID: 1, insightID: 7_201)
        let transport = ControlledInsightPreviewTransport(
            replies: [
                .ok(Self.cachedInsight(id: 7_201, title: "Retained preview")),
                .status(503, #"{"detail":"Synthetic replacement failure"}"#),
            ],
            heldRequests: [2]
        )
        let store = InsightQuickPreviewStore(now: { now })
        let client = Self.client(transport: transport)

        await store.activate(client: client, scope: scope)
        now.addTimeInterval(300)
        let replacement = Task { await store.activate(client: client, scope: scope) }
        await transport.waitForRequests(2)

        guard case .loading(let previous, let previousLoadedAt) = store.state(for: scope) else {
            Issue.record("The expiry reload did not retain its prior value while loading.")
            return
        }
        #expect(previous?.title == "Retained preview")
        #expect(previousLoadedAt == loadedAt)

        await transport.release(2)
        await replacement.value

        guard case .stale(let insight, let staleLoadedAt) = store.state(for: scope) else {
            Issue.record("The failed replacement discarded its cached value.")
            return
        }
        #expect(insight.title == "Retained preview")
        #expect(staleLoadedAt == loadedAt)
    }

    private static func insight(_ json: String) throws -> Insight {
        try JSONDecoder().decode(Insight.self, from: Data(json.utf8))
    }

    private static func waitForReturn(_ probe: InsightPreviewActivationProbe) async -> Bool {
        for _ in 0..<1_000 {
            if await probe.hasReturned() { return true }
            await Task.yield()
        }
        return false
    }

    private static func waitForCancellation(
        _ transport: ControlledInsightPreviewTransport
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await transport.cancelledRequests() == 1 { return true }
            await Task.yield()
        }
        return false
    }

    private static func cachedInsight(id: Int, title: String) -> Data {
        Data(
            """
            {
              "id": \(id),
              "name": "\(title)",
              "is_cached": true,
              "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
              "result": [{"label":"Synthetic series","count":7,"data":[7],"days":["2026-08-26"]}]
            }
            """.utf8
        )
    }

    private static func scope(
        projectID: Int,
        insightID: Int,
        region: PostHogRegion = .usCloud,
        authSessionID: UUID = UUID(
            uuidString: "018F9000-0000-7000-8000-000000000710"
        )!
    ) -> InsightPreviewScope {
        InsightPreviewScope(
            authority: ResourceRequestAuthority(
                projectID: projectID,
                region: region,
                authSessionID: authSessionID
            ),
            insightID: insightID
        )
    }

    private static func client(
        transport: some HTTPTransport,
        cache: ResponseCache? = nil,
        cacheNamespace: String? = nil
    ) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport,
            responseCache: cache,
            responseCacheNamespace: cacheNamespace
        )
    }

    private static let metadataInsight = #"""
    {
      "id": 7201,
      "name": "Synthetic activation trend",
      "description": "A fictional product activation signal.",
      "favorited": true,
      "dashboards": [7301, 7302],
      "last_modified_at": "2026-08-26T10:00:00Z",
      "last_refresh": "2026-08-26T09:00:00Z",
      "is_cached": true,
      "query": {
        "kind": "InsightVizNode",
        "source": {"kind":"TrendsQuery","trendsFilter":{"display":"BoldNumber"}}
      },
      "result": []
    }
    """#

    private static let detailSeedInsight = #"""
    {
      "id": 7201,
      "name": "Synthetic activation trend",
      "query": {
        "kind": "InsightVizNode",
        "source": {
          "kind":"TrendsQuery",
          "trendsFilter":{"display":"ActionsLineGraph"}
        }
      },
      "result": []
    }
    """#

    private static let headlineInsight = #"""
    {
      "id": 7201,
      "query": {
        "kind": "InsightVizNode",
        "source": {"kind":"TrendsQuery","trendsFilter":{"display":"BoldNumber"}}
      },
      "result": [{"label":"Synthetic activations","aggregated_value":12500,"data":[],"days":[]}]
    }
    """#

    private static let chartInsight = #"""
    {
      "id": 7202,
      "query": {
        "kind": "InsightVizNode",
        "source": {"kind":"TrendsQuery","trendsFilter":{"display":"ActionsLineGraph"}}
      },
      "result": [
        {"label":"Synthetic A","count":7,"data":[3,4],"days":["2026-08-25","2026-08-26"]},
        {"label":"Synthetic B","count":5,"data":[2,3],"days":["2026-08-25","2026-08-26"]}
      ]
    }
    """#

    private static let tableInsight = #"""
    {
      "id": 7203,
      "query": {"kind":"DataVisualizationNode","source":{"kind":"HogQLQuery"},"display":"ActionsTable"},
      "columns": ["synthetic_name", "synthetic_count"],
      "types": [["synthetic_name", "String"], ["synthetic_count", "Int64"]],
      "result": [["Alpha", 7], ["Beta", 5]]
    }
    """#

    private static let unplottableHeatmapInsight = #"""
    {
      "id": 7207,
      "query": {
        "kind": "DataVisualizationNode",
        "source": {"kind":"HogQLQuery"},
        "display": "TwoDimensionalHeatmap"
      },
      "columns": ["synthetic_x", "synthetic_y", "synthetic_value"],
      "types": [
        ["synthetic_x", "String"],
        ["synthetic_y", "String"],
        ["synthetic_value", "Int64"]
      ],
      "result": [["Alpha", "Beta", "not-a-number"]]
    }
    """#

    private static let emptyInsight = #"""
    {
      "id": 7204,
      "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
      "result": []
    }
    """#

    private static let pendingInsight = #"""
    {
      "id": 7205,
      "query": {"kind":"DataVisualizationNode","source":{"kind":"HogQLQuery"},"display":"ActionsTable"},
      "columns": ["synthetic_count"],
      "types": [["synthetic_count", "Int64"]],
      "result": null
    }
    """#

    private static let unsupportedInsight = #"""
    {
      "id": 7206,
      "query": {"kind":"InsightVizNode","source":{"kind":"SyntheticFutureQuery"}},
      "result": []
    }
    """#
}
