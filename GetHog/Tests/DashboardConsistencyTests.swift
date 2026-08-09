import Foundation
import GetHogKit
import Testing

@testable import GetHog

private struct DashboardTransportReply: Sendable {
    let statusCode: Int
    let data: Data

    static func ok(_ data: Data) -> Self {
        Self(statusCode: 200, data: data)
    }

    static func status(_ statusCode: Int, _ body: String) -> Self {
        Self(statusCode: statusCode, data: Data(body.utf8))
    }
}

private actor DashboardConsistencyTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var dashboardReplies: [DashboardTransportReply]
    private var queryReplies: [Data]

    init(dashboardReplies: [DashboardTransportReply] = [], queryReplies: [Data] = []) {
        self.dashboardReplies = dashboardReplies
        self.queryReplies = queryReplies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply: DashboardTransportReply
        if request.url?.path.hasSuffix("/query") == true {
            reply = .ok(try #require(queryReplies.isEmpty ? nil : queryReplies.removeFirst()))
        } else {
            reply = try #require(dashboardReplies.isEmpty ? nil : dashboardReplies.removeFirst())
        }
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: reply.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (reply.data, response)
    }

    var queryRequestCount: Int {
        requests.count { $0.url?.path.hasSuffix("/query") == true }
    }

    var dashboardRequestCount: Int {
        requests.count { $0.url?.path.hasSuffix("/query") != true }
    }
}

private actor GatedDashboardRangeTransport: HTTPTransport {
    private let heldReply: Data
    private var immediateReplies: [Data]
    private var hasHeldFirstQuery = false
    private var heldContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var firstQueryWaiters: [CheckedContinuation<Void, Never>] = []

    init(heldReply: Data, immediateReplies: [Data]) {
        self.heldReply = heldReply
        self.immediateReplies = immediateReplies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        if !hasHeldFirstQuery {
            hasHeldFirstQuery = true
            let waiters = firstQueryWaiters
            firstQueryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                heldContinuation = continuation
            }
        }

        return (try #require(immediateReplies.isEmpty ? nil : immediateReplies.removeFirst()), response)
    }

    func waitForFirstQuery() async {
        guard !hasHeldFirstQuery else { return }
        await withCheckedContinuation { continuation in
            firstQueryWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        let response = HTTPURLResponse(
            url: URL(string: "https://us.posthog.com/api/projects/1/query")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        heldContinuation?.resume(returning: (heldReply, response))
        heldContinuation = nil
    }
}

private actor OutOfOrderDashboardListTransport: HTTPTransport {
    private var projectOneRequests = 0
    private var oldRefreshStarted = false
    private var newScopeStarted = false
    private var releaseOld: CheckedContinuation<Void, Never>?
    private var releaseNew: CheckedContinuation<Void, Never>?

    func waitForOldRefresh() async {
        while !oldRefreshStarted { await Task.yield() }
    }

    func waitForNewScope() async {
        while !newScopeStarted { await Task.yield() }
    }

    func releaseOldRefresh() {
        releaseOld?.resume()
        releaseOld = nil
    }

    func releaseNewScope() {
        releaseNew?.resume()
        releaseNew = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let projectID = request.url?.pathComponents
            .drop(while: { $0 != "projects" })
            .dropFirst()
            .first
            .flatMap(Int.init) ?? 0
        if projectID == 1 {
            projectOneRequests += 1
            if projectOneRequests == 2 {
                oldRefreshStarted = true
                await withCheckedContinuation { releaseOld = $0 }
            }
        } else if projectID == 2 {
            newScopeStarted = true
            await withCheckedContinuation { releaseNew = $0 }
        }
        let body = """
        {"count":1,"next":null,"previous":null,"results":[
          {"id":\(9_000 + projectID),"name":"Project \(projectID) dashboard","pinned":false}
        ]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private actor GatedDashboardListRetryTransport: HTTPTransport {
    private var requestCount = 0
    private var retryStarted = false
    private var retryContinuation: CheckedContinuation<Void, Never>?

    func waitForRetry() async {
        while !retryStarted { await Task.yield() }
    }

    func requests() -> Int {
        requestCount
    }

    func releaseRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 1 {
            return reply(
                request,
                status: 503,
                body: #"{"detail":"Synthetic dashboard list failed"}"#
            )
        }
        if requestCount == 2 {
            retryStarted = true
            await withCheckedContinuation { retryContinuation = $0 }
        }
        return reply(
            request,
            status: 200,
            body: """
            {"count":1,"next":null,"previous":null,"results":[
              {"id":9001,"name":"Recovered dashboard","pinned":false}
            ]}
            """
        )
    }

    private func reply(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (Data, HTTPURLResponse) {
        (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private actor HeldCancelableDashboardTransport: HTTPTransport {
    private let responseBody: Data
    private var requestCount = 0
    private var requestStarted = false
    private var heldContinuation: CheckedContinuation<Void, Never>?

    init(responseBody: Data) {
        self.responseBody = responseBody
    }

    func waitForRequest() async {
        while !requestStarted { await Task.yield() }
    }

    func requests() -> Int {
        requestCount
    }

    func release() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        await withCheckedContinuation { continuation in
            heldContinuation = continuation
            requestStarted = true
        }
        try Task.checkCancellation()
        return (
            responseBody,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private actor OutOfOrderPinnedPreviewTransport: HTTPTransport {
    private var requestCount = 0
    private var firstRequestStarted = false
    private var releaseFirstRequest: CheckedContinuation<Void, Never>?

    func waitForFirstRequest() async {
        while !firstRequestStarted { await Task.yield() }
    }

    func releaseFirst() {
        releaseFirstRequest?.resume()
        releaseFirstRequest = nil
    }

    func requests() -> Int {
        requestCount
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let projectID = request.url?.pathComponents
            .drop(while: { $0 != "projects" })
            .dropFirst()
            .first
            .flatMap(Int.init) ?? 0

        if projectID == 1 {
            firstRequestStarted = true
            await withCheckedContinuation { releaseFirstRequest = $0 }
        }

        let body = projectID == 1
            ? Self.projectOneDashboard
            : Self.projectTwoDashboard
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }

    private static let projectOneDashboard = Data(
        #"{"id":9001,"name":"Project 1 pinned dashboard","tiles":[]}"#.utf8
    )
    private static let projectTwoDashboard = Data(
        #"{"id":9001,"name":"Project 2 pinned dashboard","tiles":[]}"#.utf8
    )
}

private actor HeldFirstPinnedPreviewTransport: HTTPTransport {
    private let heldReply: Data
    private var subsequentReplies: [Data]
    private var requestCount = 0
    private var refreshValues: [String?] = []
    private var firstRequestStarted = false
    private var releaseFirstRequest: CheckedContinuation<Void, Never>?

    init(heldReply: Data, subsequentReplies: [Data]) {
        self.heldReply = heldReply
        self.subsequentReplies = subsequentReplies
    }

    func waitForFirstRequest() async {
        while !firstRequestStarted { await Task.yield() }
    }

    func releaseFirst() {
        releaseFirstRequest?.resume()
        releaseFirstRequest = nil
    }

    func requests() -> Int {
        requestCount
    }

    func receivedRefreshValues() -> [String?] {
        refreshValues
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let sequence = requestCount
        refreshValues.append(
            URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "refresh" })?
                .value
        )
        if sequence == 1 {
            firstRequestStarted = true
            await withCheckedContinuation { releaseFirstRequest = $0 }
        }
        let body = sequence == 1
            ? heldReply
            : try #require(subsequentReplies.isEmpty ? nil : subsequentReplies.removeFirst())
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

@Suite("Dashboard consistency")
@MainActor
struct DashboardConsistencyTests {
    @Test("a late dashboard list cannot publish across a project switch")
    func dashboardListIsProjectScoped() async {
        let transport = OutOfOrderDashboardListTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardsStore()

        await store.load(client: client, projectID: 1)
        #expect(store.dashboards.map(\.title) == ["Project 1 dashboard"])
        let oldRefresh = Task { await store.load(client: client, projectID: 1) }
        await transport.waitForOldRefresh()
        let newScope = Task { await store.load(client: client, projectID: 2) }
        await transport.waitForNewScope()
        #expect(store.dashboards.isEmpty)

        await transport.releaseNewScope()
        await newScope.value
        #expect(store.dashboards.map(\.title) == ["Project 2 dashboard"])
        await transport.releaseOldRefresh()
        await oldRefresh.value
        #expect(store.dashboards.map(\.title) == ["Project 2 dashboard"])
    }

    @Test("selected inspector uses the same effective range model as its card")
    func selectedPresentationUsesRangeOverride() async throws {
        let store = DashboardDetailStore()
        store.dashboard = try Dashboard.decode(from: Self.savedDashboard)
        store.selectedTileID = 9_101

        let transport = DashboardConsistencyTransport(queryReplies: [Self.totalSevenQuery])
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )

        await store.apply(range: .week, compare: false, client: client, projectID: 1)

        let expected = InsightRenderModel.timeSeries(
            [
                Series(
                    label: "Synthetic events",
                    total: 7,
                    points: [
                        Point(day: "2026-02-01", value: 3),
                        Point(day: "2026-02-02", value: 4),
                    ]
                ),
            ],
            style: .line
        )
        let tile = try #require(store.dashboard?.tiles.first)

        #expect(store.overrides[tile.id] == expected)
        #expect(store.selectedPresentation?.model == expected)
    }

    @Test("selected inspector resolves the latest tile after dashboard reload")
    func selectedPresentationTracksReloadedTile() async throws {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [
                .ok(Self.savedDashboard),
                .ok(Self.refreshedDashboard),
            ]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()

        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: false)
        store.selectedTileID = 9_101
        #expect(store.selectedPresentation?.model == Self.totalOneModel)

        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: true)

        #expect(store.selectedTileID == 9_101)
        #expect(store.selectedPresentation?.model == Self.totalNineModel)
    }

    @Test("a range chosen before initial load applies after tiles arrive")
    func preLoadRangeAppliesAfterLoad() async throws {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.savedDashboard)],
            queryReplies: [Self.totalSevenQuery]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()
        store.range = .week

        await store.load(
            client: client,
            projectID: 1,
            dashboardID: 9_001,
            refresh: false
        )

        let tile = try #require(store.dashboard?.tiles.first)
        let expected = InsightRenderModel.timeSeries(
            [
                Series(
                    label: "Synthetic events",
                    total: 7,
                    points: [
                        Point(day: "2026-02-01", value: 3),
                        Point(day: "2026-02-02", value: 4),
                    ]
                ),
            ],
            style: .line
        )
        #expect(store.presentation(for: tile).model == expected)
        #expect(await transport.queryRequestCount == 1)
    }

    @Test("a late range response cannot overwrite the newest selection")
    func staleRangeResponseIsDiscarded() async throws {
        let transport = GatedDashboardRangeTransport(
            heldReply: Self.totalSevenQuery,
            immediateReplies: [Self.totalThirtyQuery]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()
        store.dashboard = try Dashboard.decode(from: Self.savedDashboard)

        store.range = .week
        let old = Task {
            await store.applySelectedRange(client: client, projectID: 1)
        }
        await transport.waitForFirstQuery()

        store.range = .month
        await store.applySelectedRange(client: client, projectID: 1)
        await transport.releaseFirst()
        await old.value

        let tile = try #require(store.dashboard?.tiles.first)
        let expected = InsightRenderModel.timeSeries(
            [
                Series(
                    label: "Synthetic events",
                    total: 30,
                    points: [Point(day: "2026-02-03", value: 30)]
                ),
            ],
            style: .line
        )
        #expect(store.range == .month)
        #expect(store.presentation(for: tile).model == expected)
        #expect(store.rangeError == nil)
        #expect(!store.isApplyingRange)
    }

    @Test("refresh failure keeps prior dashboard and exposes retryable nonfatal failure")
    func refreshFailureIsNonfatalAndVisibleToPresentation() async {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [
                .ok(Self.savedDashboard),
                .status(503, #"{"detail":"Synthetic dashboard recompute failed"}"#),
            ]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()

        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: false)
        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: true)

        #expect(store.dashboard?.id == 9_001)
        #expect(store.contentState == .tiles)
        #expect(store.loadFailure?.refresh == true)
        #expect(store.loadFailure?.failure.summary.contains("Synthetic dashboard recompute failed") == true)
    }

    @Test("failed refresh does not discard a valid in-flight range result")
    func failedRefreshKeepsCurrentRangeApplication() async throws {
        let store = DashboardDetailStore()
        store.dashboard = try Dashboard.decode(from: Self.savedDashboard)

        let initialTransport = DashboardConsistencyTransport(
            queryReplies: [Self.totalSevenQuery]
        )
        let initialClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: initialTransport
        )
        store.range = .week
        await store.applySelectedRange(client: initialClient, projectID: 1)

        let rangeTransport = GatedDashboardRangeTransport(
            heldReply: Self.totalThirtyQuery,
            immediateReplies: []
        )
        let rangeClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: rangeTransport
        )
        store.range = .month
        let pendingRange = Task {
            await store.applySelectedRange(client: rangeClient, projectID: 1)
        }
        await rangeTransport.waitForFirstQuery()

        let failingTransport = DashboardConsistencyTransport(
            dashboardReplies: [
                .status(503, #"{"detail":"Synthetic dashboard recompute failed"}"#),
            ]
        )
        let failingClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: failingTransport
        )
        await store.load(client: failingClient, projectID: 1, dashboardID: 9_001, refresh: true)
        await rangeTransport.releaseFirst()
        await pendingRange.value

        let tile = try #require(store.dashboard?.tiles.first)
        #expect(store.range == .month)
        #expect(store.presentation(for: tile).model == Self.totalThirtyModel)
        #expect(store.loadFailure?.refresh == true)
    }

    @Test("fatal recompute failure retains recompute retry mode")
    func fatalRecomputeFailureRetainsRetryMode() async {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [
                .status(503, #"{"detail":"Synthetic initial recompute failed"}"#),
            ]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()

        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: true)

        guard case let .failed(failure) = store.contentState else {
            Issue.record("Initial recompute failure was not fatal presentation state.")
            return
        }
        #expect(failure.refresh)
    }

    @Test("dashboard starts loading and a successful zero-tile response becomes empty")
    func initialLoadingAndZeroTileStateAreDistinct() async {
        let store = DashboardDetailStore()
        #expect(store.contentState == .loading)

        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.emptyDashboard)]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        await store.load(client: client, projectID: 1, dashboardID: 9_002, refresh: false)

        #expect(store.contentState == .empty)
        #expect(store.loadFailure == nil)
    }

    @Test("dashboard hosts reuse one store for the same dashboard id")
    func storePoolPreservesDashboardSessionIdentity() {
        let pool = DashboardDetailStorePool()
        let firstHost = pool.store(for: 9_001, projectID: 1)
        firstHost.range = .month
        firstHost.selectedTileID = 9_101

        let secondHost = pool.store(for: 9_001, projectID: 1)

        #expect(firstHost === secondHost)
        #expect(secondHost.range == .month)
        #expect(secondHost.selectedTileID == 9_101)
        #expect(pool.store(for: 9_002, projectID: 1) !== firstHost)
        #expect(pool.store(for: 9_001, projectID: 2) !== firstHost)
    }

    @Test("a project switch clears the prior dashboard even when replacement loading fails")
    func projectSwitchFailureCannotRetainPriorDashboard() async {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [
                .ok(Self.savedDashboard),
                .status(503, #"{"detail":"Synthetic replacement failed"}"#),
            ]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()

        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: false)
        #expect(store.dashboard?.id == 9_001)
        await store.load(client: client, projectID: 2, dashboardID: 9_001, refresh: false)

        #expect(store.dashboard == nil)
        guard case .failed = store.contentState else {
            Issue.record("The replacement project's failure retained prior-project content.")
            return
        }
    }

    @Test("clearing root detail state discards authentication-bound dashboard sessions")
    func rootDetailResetClearsDashboardPool() {
        let details = OpenDetails()
        let prior = details.dashboardStores.store(for: 9_001, projectID: 1)
        prior.selectedTileID = 9_101
        details[.dashboards] = AnyHashable(9_001)

        details.reset()

        #expect(details[.dashboards] == nil)
        #expect(details.dashboardStores.store(for: 9_001, projectID: 1) !== prior)
    }

    @Test("a remounted saved range does not spend a duplicate query batch")
    func remountedRangeApplicationIsDeduplicated() async {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.savedDashboard)],
            queryReplies: [Self.totalSevenQuery]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()
        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: false)
        store.range = .week
        await store.applySelectedRange(client: client, projectID: 1)
        #expect(await transport.queryRequestCount == 1)

        await store.applySelectedRangeIfNeeded(client: client, projectID: 1)

        #expect(await transport.queryRequestCount == 1)
    }

    @Test("a remounted non-Saved dashboard does not refetch or rerun its tiles")
    func remountedDashboardLoadIsDeduplicated() async throws {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.savedDashboard), .ok(Self.savedDashboard)],
            queryReplies: [Self.totalSevenQuery, Self.totalSevenQuery]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()
        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: false)
        store.range = .week
        await store.applySelectedRange(client: client, projectID: 1)

        await store.loadIfNeeded(client: client, projectID: 1, dashboardID: 9_001)

        let tile = try #require(store.dashboard?.tiles.first)
        #expect(await transport.dashboardRequestCount == 1)
        #expect(await transport.queryRequestCount == 1)
        #expect(store.presentation(for: tile).model == Self.totalSevenModel)
    }

    @Test("an explicit dashboard refresh still fetches and reapplies a non-Saved range")
    func explicitRefreshBypassesMountDeduplication() async throws {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.savedDashboard), .ok(Self.refreshedDashboard)],
            queryReplies: [Self.totalSevenQuery, Self.totalThirtyQuery]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()
        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: false)
        store.range = .week
        await store.applySelectedRange(client: client, projectID: 1)

        await store.loadIfNeeded(client: client, projectID: 1, dashboardID: 9_001)
        await store.load(client: client, projectID: 1, dashboardID: 9_001, refresh: false)

        let tile = try #require(store.dashboard?.tiles.first)
        #expect(await transport.dashboardRequestCount == 2)
        #expect(await transport.queryRequestCount == 2)
        #expect(store.presentation(for: tile).model == Self.totalThirtyModel)
    }

    @Test("a remounted dashboard survives cancellation of the outgoing mount task")
    func remountedDashboardSharesAStoreOwnedLoad() async {
        let transport = HeldCancelableDashboardTransport(responseBody: Self.savedDashboard)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardDetailStore()
        let outgoingMount = Task {
            await store.loadIfNeeded(client: client, projectID: 1, dashboardID: 9_001)
        }
        await transport.waitForRequest()
        outgoingMount.cancel()

        let release = Task {
            await Task.yield()
            await transport.release()
        }
        await store.loadIfNeeded(client: client, projectID: 1, dashboardID: 9_001)
        await release.value
        await outgoingMount.value

        #expect(await transport.requests() == 1)
        #expect(store.dashboard?.id == 9_001)
        #expect(store.contentState == .tiles)
    }

    @Test("an unavailable dashboard list sends nothing and loads when availability changes")
    func unavailableDashboardListDefersItsRequest() async {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.dashboardList)]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardsStore()

        let unavailable = DashboardListLoadScope(projectID: 1, isAvailable: false)
        #expect(store.contentState(isAvailable: false) == .unavailable)
        await unavailable.load(store: store, client: client)
        #expect(await transport.dashboardRequestCount == 0)

        let available = DashboardListLoadScope(projectID: 1, isAvailable: true)
        await available.load(store: store, client: client)

        #expect(await transport.dashboardRequestCount == 1)
        #expect(store.dashboards.map(\.title) == ["Project 1 dashboard"])
        #expect(store.contentState(isAvailable: true) == .loaded)
        #expect(store.contentState(isAvailable: false) == .unavailable)
    }

    @Test("repeated dashboard retries share one active request and present loading")
    func repeatedDashboardRetryIsCoalesced() async {
        let transport = GatedDashboardListRetryTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardsStore()
        await store.load(client: client, projectID: 1)
        #expect(store.error != nil)

        let firstRetry = Task { await store.load(client: client, projectID: 1) }
        await transport.waitForRetry()
        #expect(store.contentState(isAvailable: true) == .loading)
        let release = Task {
            await Task.yield()
            await transport.releaseRetry()
        }
        await store.load(client: client, projectID: 1)
        await release.value
        await firstRetry.value

        #expect(await transport.requests() == 2)
        #expect(store.dashboards.map(\.title) == ["Recovered dashboard"])
        #expect(store.contentState(isAvailable: true) == .loaded)
    }

    @Test("a remounted dashboard list survives cancellation of the outgoing task")
    func remountedDashboardListSharesAStoreOwnedLoad() async {
        let transport = HeldCancelableDashboardTransport(responseBody: Self.dashboardList)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardsStore()
        let outgoingMount = Task { await store.load(client: client, projectID: 1) }
        await transport.waitForRequest()
        outgoingMount.cancel()

        let release = Task {
            await Task.yield()
            await transport.release()
        }
        await store.load(client: client, projectID: 1)
        await release.value
        await outgoingMount.value

        #expect(await transport.requests() == 1)
        #expect(store.dashboards.map(\.title) == ["Project 1 dashboard"])
        #expect(store.contentState(isAvailable: true) == .loaded)
    }

    @Test("a remounted pinned preview shares one cached dashboard request")
    func remountedPinnedPreviewSharesAStoreOwnedLoad() async {
        let transport = HeldCancelableDashboardTransport(responseBody: Self.savedDashboard)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = PinnedDashboardPreviewStore()
        let authSessionID = UUID()
        let outgoingMount = Task {
            await store.loadIfNeeded(
                client: client,
                projectID: 1,
                dashboardID: 9_001,
                authSessionID: authSessionID
            )
        }
        await transport.waitForRequest()
        outgoingMount.cancel()

        let release = Task {
            await Task.yield()
            await transport.release()
        }
        await store.loadIfNeeded(
            client: client,
            projectID: 1,
            dashboardID: 9_001,
            authSessionID: authSessionID
        )
        await release.value
        await outgoingMount.value

        #expect(await transport.requests() == 1)
        #expect(store.dashboard?.id == 9_001)
    }

    @Test("a late pinned preview cannot publish across a same-id project switch")
    func pinnedPreviewIsProjectScoped() async {
        let transport = OutOfOrderPinnedPreviewTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = PinnedDashboardPreviewStore()
        let authSessionID = UUID()

        let oldScope = Task {
            await store.loadIfNeeded(
                client: client,
                projectID: 1,
                dashboardID: 9_001,
                authSessionID: authSessionID
            )
        }
        await transport.waitForFirstRequest()

        await store.loadIfNeeded(
            client: client,
            projectID: 2,
            dashboardID: 9_001,
            authSessionID: authSessionID
        )
        #expect(store.dashboard?.title == "Project 2 pinned dashboard")

        await transport.releaseFirst()
        await oldScope.value

        #expect(await transport.requests() == 2)
        #expect(store.dashboard?.title == "Project 2 pinned dashboard")
    }

    @Test("a late pinned preview cannot publish across an authentication epoch")
    func pinnedPreviewIsAuthenticationScoped() async {
        let transport = HeldFirstPinnedPreviewTransport(
            heldReply: Self.previewDashboard(id: 9_001, title: "Prior authentication preview"),
            subsequentReplies: [
                Self.previewDashboard(id: 9_001, title: "Replacement authentication preview"),
            ]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = PinnedDashboardPreviewStore()

        let oldScope = Task {
            await store.loadIfNeeded(
                client: client,
                projectID: 1,
                dashboardID: 9_001,
                authSessionID: UUID()
            )
        }
        await transport.waitForFirstRequest()

        await store.loadIfNeeded(
            client: client,
            projectID: 1,
            dashboardID: 9_001,
            authSessionID: UUID()
        )
        #expect(store.dashboard?.title == "Replacement authentication preview")

        await transport.releaseFirst()
        await oldScope.value

        #expect(await transport.requests() == 2)
        #expect(await transport.receivedRefreshValues() == ["force_cache", "force_cache"])
        #expect(store.dashboard?.title == "Replacement authentication preview")
    }

    @Test("a late pinned preview cannot publish after the pinned dashboard changes")
    func pinnedPreviewIsDashboardScoped() async {
        let transport = HeldFirstPinnedPreviewTransport(
            heldReply: Self.previewDashboard(id: 9_001, title: "Previous pinned dashboard"),
            subsequentReplies: [
                Self.previewDashboard(id: 9_002, title: "Replacement pinned dashboard"),
            ]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = PinnedDashboardPreviewStore()
        let authSessionID = UUID()

        let oldScope = Task {
            await store.loadIfNeeded(
                client: client,
                projectID: 1,
                dashboardID: 9_001,
                authSessionID: authSessionID
            )
        }
        await transport.waitForFirstRequest()

        await store.loadIfNeeded(
            client: client,
            projectID: 1,
            dashboardID: 9_002,
            authSessionID: authSessionID
        )
        #expect(store.dashboard?.title == "Replacement pinned dashboard")

        await transport.releaseFirst()
        await oldScope.value

        #expect(await transport.requests() == 2)
        #expect(await transport.receivedRefreshValues() == ["force_cache", "force_cache"])
        #expect(store.dashboard?.id == 9_002)
        #expect(store.dashboard?.title == "Replacement pinned dashboard")
    }

    @Test("an invalid pinned-preview scope immediately clears and rejects late tiles")
    func invalidPinnedPreviewScopeClearsAndRejectsLateResponse() async {
        let transport = HeldFirstPinnedPreviewTransport(
            heldReply: Self.previewDashboard(id: 9_001, title: "Stale pinned dashboard"),
            subsequentReplies: []
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = PinnedDashboardPreviewStore()

        let oldScope = Task {
            await store.loadIfNeeded(
                client: client,
                projectID: 1,
                dashboardID: 9_001,
                authSessionID: UUID()
            )
        }
        await transport.waitForFirstRequest()

        await store.loadIfNeeded(
            client: client,
            projectID: nil,
            dashboardID: 9_001,
            authSessionID: UUID()
        )
        #expect(store.dashboard == nil)
        #expect(!store.isLoading)
        #expect(await transport.requests() == 1)

        await transport.releaseFirst()
        await oldScope.value

        #expect(await transport.requests() == 1)
        #expect(store.dashboard == nil)
        #expect(!store.isLoading)
    }

    private static func previewDashboard(id: Int, title: String) -> Data {
        Data("{\"id\":\(id),\"name\":\"\(title)\",\"tiles\":[]}".utf8)
    }

    private static let totalSevenQuery = Data(
        """
        {"results":[{"label":"Synthetic events","count":7,
          "data":[3,4],"days":["2026-02-01","2026-02-02"]}]}
        """.utf8
    )

    private static let dashboardList = Data(
        """
        {"count":1,"next":null,"previous":null,"results":[
          {"id":9001,"name":"Project 1 dashboard","pinned":false}
        ]}
        """.utf8
    )

    private static let totalThirtyQuery = Data(
        """
        {"results":[{"label":"Synthetic events","count":30,
          "data":[30],"days":["2026-02-03"]}]}
        """.utf8
    )

    private static let totalOneModel = InsightRenderModel.timeSeries(
        [
            Series(
                label: "Synthetic events",
                total: 1,
                points: [Point(day: "2026-01-31", value: 1)]
            ),
        ],
        style: .line
    )

    private static let totalNineModel = InsightRenderModel.timeSeries(
        [
            Series(
                label: "Synthetic events",
                total: 9,
                points: [Point(day: "2026-02-04", value: 9)]
            ),
        ],
        style: .line
    )

    private static let totalSevenModel = InsightRenderModel.timeSeries(
        [
            Series(
                label: "Synthetic events",
                total: 7,
                points: [
                    Point(day: "2026-02-01", value: 3),
                    Point(day: "2026-02-02", value: 4),
                ]
            ),
        ],
        style: .line
    )

    private static let totalThirtyModel = InsightRenderModel.timeSeries(
        [
            Series(
                label: "Synthetic events",
                total: 30,
                points: [Point(day: "2026-02-03", value: 30)]
            ),
        ],
        style: .line
    )

    private static let savedDashboard = Data(
        """
        {
          "id": 9001,
          "name": "Synthetic operations",
          "tiles": [
            {
              "id": 9101,
              "insight": {
                "id": 9201,
                "name": "Synthetic trend",
                "query": {"kind":"InsightVizNode","source":{
                  "kind":"TrendsQuery","series":[],"dateRange":{"date_from":"-30d"}
                }},
                "result":[{"label":"Synthetic events","count":1,
                  "data":[1],"days":["2026-01-31"]}]
              }
            }
          ]
        }
        """.utf8
    )

    private static let emptyDashboard = Data(
        """
        {
          "id": 9002,
          "name": "Synthetic empty dashboard",
          "tiles": []
        }
        """.utf8
    )

    private static let refreshedDashboard = Data(
        """
        {
          "id": 9001,
          "name": "Synthetic operations",
          "tiles": [
            {
              "id": 9101,
              "insight": {
                "id": 9201,
                "name": "Synthetic trend",
                "query": {"kind":"InsightVizNode","source":{
                  "kind":"TrendsQuery","series":[],"dateRange":{"date_from":"-30d"}
                }},
                "result":[{"label":"Synthetic events","count":9,
                  "data":[9],"days":["2026-02-04"]}]
              }
            }
          ]
        }
        """.utf8
    )
}
