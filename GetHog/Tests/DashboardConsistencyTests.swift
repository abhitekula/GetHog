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

/// The first dashboard-list request succeeds, a same-project refresh fails,
/// and the retry succeeds. Every row and failure is synthetic.
private actor DashboardListRefreshFailureTransport: HTTPTransport {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 2 {
            throw PostHogError.transport("Synthetic dashboard list refresh failed")
        }
        let body = #"{"count":1,"next":null,"previous":null,"results":[{"id":9001,"name":"Synthetic dashboard","pinned":true}]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private actor HeldDashboardListTransport: HTTPTransport {
    private var requestStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRequest() async {
        while !requestStarted { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestStarted = true
        await withCheckedContinuation { continuation = $0 }
        let body = #"{"count":1,"next":null,"previous":null,"results":[{"id":9077,"name":"Late US dashboard","pinned":false}]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
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

private actor HeldFirstDashboardPreviewTransport: HTTPTransport {
    private let heldReply: Data
    private var subsequentReplies: [Data]
    private var requestCount = 0
    private var cancelledRequestCount = 0
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

    func cancelledRequests() -> Int {
        cancelledRequestCount
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let sequence = requestCount
        if sequence == 1 {
            firstRequestStarted = true
            await withCheckedContinuation { releaseFirstRequest = $0 }
            if Task.isCancelled {
                cancelledRequestCount += 1
                throw CancellationError()
            }
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
    @Test("the same numeric project on another host clears rows when its load fails")
    func dashboardListFailureAcrossHostsDoesNotRetainRows() async {
        let initialTransport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.dashboardList)]
        )
        let initialClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: initialTransport
        )
        let store = DashboardsStore()
        await store.load(client: initialClient, projectID: 1)
        #expect(store.dashboards.map(\.title) == ["Project 1 dashboard"])

        let failingTransport = DashboardConsistencyTransport(
            dashboardReplies: [
                .status(503, #"{"detail":"Synthetic EU dashboard list failed"}"#),
            ]
        )
        let failingClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .euCloud),
            transport: failingTransport
        )

        await store.load(client: failingClient, projectID: 1)

        #expect(store.dashboards.isEmpty)
        #expect(store.loadedAt == nil)
        guard case .failed = store.contentState(isAvailable: true) else {
            Issue.record("A failed load for another host retained the previous host's rows")
            return
        }
    }

    @Test("a late dashboard list cannot publish across a host switch with the same project ID")
    func dashboardListIsHostScoped() async {
        let initialTransport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.dashboardList)]
        )
        let initialClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: initialTransport
        )
        let store = DashboardsStore()
        await store.load(client: initialClient, projectID: 1)

        let heldTransport = HeldDashboardListTransport()
        let heldClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: heldTransport
        )
        let oldRefresh = Task { await store.load(client: heldClient, projectID: 1) }
        await heldTransport.waitForRequest()

        let euBody = #"{"count":1,"next":null,"previous":null,"results":[{"id":9177,"name":"Current EU dashboard","pinned":false}]}"#
        let euTransport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Data(euBody.utf8))]
        )
        let euClient = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .euCloud),
            transport: euTransport
        )
        let newScope = Task { await store.load(client: euClient, projectID: 1) }

        await heldTransport.release()
        await oldRefresh.value
        await newScope.value

        #expect(store.dashboards.map(\.title) == ["Current EU dashboard"])
    }

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

    @Test("same-project dashboard list refresh failure preserves rows and retry state")
    func dashboardListRefreshFailurePreservesRows() async {
        let transport = DashboardListRefreshFailureTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
        let store = DashboardsStore()

        await store.load(client: client, projectID: 1)
        let firstPageIDs = store.dashboards.map(\.id)
        #expect(firstPageIDs == [9001])

        await store.load(client: client, projectID: 1)

        #expect(store.dashboards.map(\.id) == firstPageIDs)
        #expect(store.contentState(isAvailable: true) == .loaded)
        #expect(store.error?.contains("Synthetic dashboard list refresh failed") == true)
        #expect(
            DashboardListRefreshPresentation.resolve(
                dashboardCount: store.dashboards.count,
                error: store.error
            ) == DashboardListRefreshPresentation(
                message: "Couldn't refresh dashboards. Couldn't reach PostHog: Synthetic dashboard list refresh failed",
                actionTitle: "Try again"
            )
        )

        await store.load(client: client, projectID: 1)

        #expect(store.dashboards.map(\.id) == firstPageIDs)
        #expect(store.error == nil)
        #expect(
            DashboardListRefreshPresentation.resolve(
                dashboardCount: store.dashboards.count,
                error: store.error
            ) == nil
        )
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

        let unavailable = DashboardListLoadScope(
            projectID: 1,
            region: .usCloud,
            isAvailable: false
        )
        #expect(store.contentState(isAvailable: false) == .unavailable)
        await unavailable.load(store: store, client: client)
        #expect(await transport.dashboardRequestCount == 0)

        let available = DashboardListLoadScope(
            projectID: 1,
            region: .usCloud,
            isAvailable: true
        )
        let otherHost = DashboardListLoadScope(
            projectID: 1,
            region: .euCloud,
            isAvailable: true
        )
        #expect(available != otherHost)
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

    @Test("dashboard preview uses the exact cached dashboard endpoint")
    func dashboardPreviewUsesCachedDashboardEndpoint() async throws {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.savedDashboard)]
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore()

        await store.activate(
            client: client,
            scope: Self.previewScope(projectID: 1_001, dashboardID: 9_001)
        )

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/projects/1001/dashboards/9001")
        #expect(
            URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                .queryItems == [URLQueryItem(name: "refresh", value: "force_cache")]
        )
        #expect(await transport.dashboardRequestCount == 1)
        #expect(await transport.queryRequestCount == 0)
        guard case .loaded(let dashboard, _) = store.state else {
            Issue.record("The cached dashboard response did not publish as loaded.")
            return
        }
        #expect(dashboard.id == 9_001)
    }

    @Test("a completed dashboard preview supplies detail without a second request")
    func completedDashboardPreviewSuppliesDetailFromResponseCache() async {
        let cache = ResponseCache(
            subdirectory: "DashboardPreviewDetailTests-\(UUID().uuidString)"
        )
        let authority = ResourceRequestAuthority(
            projectID: 1_001,
            region: .usCloud,
            authSessionID: UUID(
                uuidString: "018F9000-0000-7000-8000-000000000720"
            )!
        )
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.savedDashboard), .ok(Self.savedDashboard)]
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport,
            responseCache: cache,
            responseCacheNamespace: authority.authSessionID.uuidString
        )
        let preview = DashboardPreviewStore()
        let detail = DashboardDetailStore()

        await preview.activate(
            client: client,
            scope: DashboardPreviewScope(authority: authority, dashboardID: 9_001)
        )
        await detail.loadIfNeeded(client: client, projectID: 1_001, dashboardID: 9_001)

        #expect(await transport.dashboardRequestCount == 1)
        #expect(detail.dashboard?.title == "Synthetic operations")
        #expect(detail.dashboard?.id == 9_001)
        await cache.clear()
    }

    @Test("same-scope dashboard preview activations join one store-owned flight")
    func sameScopeDashboardPreviewActivationsJoin() async {
        let transport = HeldCancelableDashboardTransport(responseBody: Self.savedDashboard)
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore()
        let scope = Self.previewScope(projectID: 1, dashboardID: 9_001)

        let first = Task { await store.activate(client: client, scope: scope) }
        await transport.waitForRequest()
        let second = Task { await store.activate(client: client, scope: scope) }
        await Task.yield()
        #expect(await transport.requests() == 1)

        await transport.release()
        await first.value
        await second.value

        #expect(await transport.requests() == 1)
        guard case .loaded(let dashboard, _) = store.state else {
            Issue.record("Joined callers did not receive the shared result.")
            return
        }
        #expect(dashboard.id == 9_001)
    }

    @Test("a completed dashboard preview is reused inside five minutes")
    func completedDashboardPreviewIsReusedInsideFiveMinutes() async {
        var now = Date(timeIntervalSince1970: 1_787_738_400)
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [.ok(Self.savedDashboard)]
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore(now: { now })
        let scope = Self.previewScope(projectID: 1, dashboardID: 9_001)

        await store.activate(client: client, scope: scope)
        now.addTimeInterval(299)
        await store.activate(client: client, scope: scope)

        #expect(await transport.dashboardRequestCount == 1)
        guard case .loaded(_, let loadedAt) = store.state else {
            Issue.record("The reusable value did not remain loaded.")
            return
        }
        #expect(loadedAt == Date(timeIntervalSince1970: 1_787_738_400))
    }

    @Test("a dashboard preview reloads at the five-minute expiry")
    func dashboardPreviewReloadsAtFiveMinuteExpiry() async {
        var now = Date(timeIntervalSince1970: 1_787_738_400)
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [
                .ok(Self.previewDashboard(id: 9_001, title: "Initial cached preview")),
                .ok(Self.previewDashboard(id: 9_001, title: "Replacement cached preview")),
            ]
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore(now: { now })
        let scope = Self.previewScope(projectID: 1, dashboardID: 9_001)

        await store.activate(client: client, scope: scope)
        now.addTimeInterval(300)
        await store.activate(client: client, scope: scope)

        #expect(await transport.dashboardRequestCount == 2)
        guard case .loaded(let dashboard, let loadedAt) = store.state else {
            Issue.record("The expired value was not replaced.")
            return
        }
        #expect(dashboard.title == "Replacement cached preview")
        #expect(loadedAt == now)
    }

    @Test("a different dashboard activation cancels the previous flight")
    func differentDashboardActivationCancelsPreviousFlight() async {
        let transport = HeldFirstDashboardPreviewTransport(
            heldReply: Self.previewDashboard(id: 9_001, title: "Cancelled preview"),
            subsequentReplies: [
                Self.previewDashboard(id: 9_002, title: "Current preview"),
            ]
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore()
        let first = Task {
            await store.activate(
                client: client,
                scope: Self.previewScope(projectID: 1, dashboardID: 9_001)
            )
        }
        await transport.waitForFirstRequest()

        await store.activate(
            client: client,
            scope: Self.previewScope(projectID: 1, dashboardID: 9_002)
        )
        await transport.releaseFirst()
        await first.value

        #expect(await transport.requests() == 2)
        #expect(await transport.cancelledRequests() == 1)
        guard case .loaded(let dashboard, _) = store.state else {
            Issue.record("Cancellation surfaced as a user-facing preview failure.")
            return
        }
        #expect(dashboard.id == 9_002)
        #expect(dashboard.title == "Current preview")
    }

    @Test("a new authority hides retained content before replacement activation completes")
    func authorityChangeSynchronouslyHidesRetainedDashboardPreview() async {
        var now = Date(timeIntervalSince1970: 1_787_738_400)
        let oldScope = Self.previewScope(
            projectID: 1,
            dashboardID: 9_001,
            authSessionID: UUID(
                uuidString: "018F9000-0000-7000-8000-000000000601"
            )!
        )
        let newScope = Self.previewScope(
            projectID: 1,
            dashboardID: 9_001,
            authSessionID: UUID(
                uuidString: "018F9000-0000-7000-8000-000000000602"
            )!
        )
        let store = DashboardPreviewStore(now: { now })
        let initialTransport = DashboardConsistencyTransport(
            dashboardReplies: [
                .ok(Self.previewDashboard(id: 9_001, title: "Prior authority preview")),
            ]
        )
        await store.activate(
            client: Self.previewClient(region: .usCloud, transport: initialTransport),
            scope: oldScope
        )
        guard case .loaded(let initial, _) = store.state(for: oldScope) else {
            Issue.record("The initial authority did not publish its preview.")
            return
        }
        #expect(initial.title == "Prior authority preview")

        now.addTimeInterval(300)
        let oldRefreshTransport = HeldCancelableDashboardTransport(
            responseBody: Self.previewDashboard(id: 9_001, title: "Late prior authority preview")
        )
        let oldRefresh = Task {
            await store.activate(
                client: Self.previewClient(region: .usCloud, transport: oldRefreshTransport),
                scope: oldScope
            )
        }
        await oldRefreshTransport.waitForRequest()

        guard case .idle = store.state(for: newScope) else {
            Issue.record("The new authority could see the retained prior-authority value.")
            return
        }

        let replacementTransport = HeldCancelableDashboardTransport(
            responseBody: Self.previewDashboard(id: 9_001, title: "Current authority preview")
        )
        let replacement = Task {
            await store.activate(
                client: Self.previewClient(region: .usCloud, transport: replacementTransport),
                scope: newScope
            )
        }
        await replacementTransport.waitForRequest()
        guard case .loading(let previous, let loadedAt) = store.state(for: newScope) else {
            Issue.record("The replacement authority did not own the loading state.")
            return
        }
        if previous != nil {
            Issue.record("The replacement loading state retained prior-authority content.")
        }
        #expect(loadedAt == nil)

        await replacementTransport.release()
        await replacement.value
        await oldRefreshTransport.release()
        await oldRefresh.value

        guard case .loaded(let current, _) = store.state(for: newScope) else {
            Issue.record("The replacement authority did not retain publication ownership.")
            return
        }
        #expect(current.title == "Current authority preview")
    }

    @Test("a missing client automatically invalidates and rejects a late preview")
    func missingClientAutomaticallyInvalidatesDashboardPreview() async {
        let transport = HeldCancelableDashboardTransport(
            responseBody: Self.previewDashboard(id: 9_001, title: "Late preview")
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore()
        let scope = Self.previewScope(projectID: 1, dashboardID: 9_001)
        let activation = Task { await store.activate(client: client, scope: scope) }
        await transport.waitForRequest()

        await store.activate(client: nil, scope: scope)
        guard case .idle = store.state(for: scope) else {
            Issue.record("A missing client did not clear the public preview state.")
            return
        }

        await transport.release()
        await activation.value
        guard case .idle = store.state(for: scope) else {
            Issue.record("A late response published after missing-client invalidation.")
            return
        }
    }

    @Test("a missing scope automatically invalidates and rejects a late preview")
    func missingScopeAutomaticallyInvalidatesDashboardPreview() async {
        let transport = HeldCancelableDashboardTransport(
            responseBody: Self.previewDashboard(id: 9_001, title: "Late preview")
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore()
        let scope = Self.previewScope(projectID: 1, dashboardID: 9_001)
        let activation = Task { await store.activate(client: client, scope: scope) }
        await transport.waitForRequest()

        await store.activate(client: client, scope: nil)
        guard case .idle = store.state(for: scope) else {
            Issue.record("A missing scope did not clear the public preview state.")
            return
        }

        await transport.release()
        await activation.value
        guard case .idle = store.state(for: scope) else {
            Issue.record("A late response published after missing-scope invalidation.")
            return
        }
    }

    @Test("an unavailable dashboard preview recovers on deliberate retry")
    func unavailableDashboardPreviewRecoversOnRetry() async {
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [
                .status(503, #"{"detail":"Synthetic preview failure"}"#),
                .ok(Self.previewDashboard(id: 9_001, title: "Recovered preview")),
            ]
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore()
        let scope = Self.previewScope(projectID: 1, dashboardID: 9_001)

        await store.activate(client: client, scope: scope)
        guard case .unavailable = store.state(for: scope) else {
            Issue.record("The failed preview was not exposed as unavailable.")
            return
        }

        await store.activate(client: client, scope: scope)
        guard case .loaded(let recovered, _) = store.state(for: scope) else {
            Issue.record("The unavailable preview did not recover on retry.")
            return
        }
        #expect(recovered.title == "Recovered preview")
        #expect(await transport.dashboardRequestCount == 2)
    }

    @Test("an expired preview becomes stale when its replacement fails")
    func expiredDashboardPreviewBecomesStaleAfterFailure() async {
        let loadedAt = Date(timeIntervalSince1970: 1_787_738_400)
        var now = loadedAt
        let transport = DashboardConsistencyTransport(
            dashboardReplies: [
                .ok(Self.previewDashboard(id: 9_001, title: "Retained cached preview")),
                .status(503, #"{"detail":"Synthetic cached preview failed"}"#),
            ]
        )
        let client = Self.previewClient(region: .usCloud, transport: transport)
        let store = DashboardPreviewStore(now: { now })
        let scope = Self.previewScope(projectID: 1, dashboardID: 9_001)

        await store.activate(client: client, scope: scope)
        now.addTimeInterval(300)
        await store.activate(client: client, scope: scope)

        #expect(await transport.dashboardRequestCount == 2)
        guard case .stale(let dashboard, let staleLoadedAt) = store.state else {
            Issue.record("The failed replacement discarded its expired value.")
            return
        }
        #expect(dashboard.title == "Retained cached preview")
        #expect(staleLoadedAt == loadedAt)
    }

    private static func previewDashboard(id: Int, title: String) -> Data {
        Data("{\"id\":\(id),\"name\":\"\(title)\",\"tiles\":[]}".utf8)
    }

    private static func previewScope(
        projectID: Int,
        dashboardID: Int,
        region: PostHogRegion = .usCloud,
        authSessionID: UUID = UUID(
            uuidString: "018F9000-0000-7000-8000-000000000600"
        )!
    ) -> DashboardPreviewScope {
        DashboardPreviewScope(
            authority: ResourceRequestAuthority(
                projectID: projectID,
                region: region,
                authSessionID: authSessionID
            ),
            dashboardID: dashboardID
        )
    }

    private static func previewClient(
        region: PostHogRegion,
        transport: some HTTPTransport
    ) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: region),
            transport: transport
        )
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
