import Foundation
import Testing

@testable import GetHog
@testable import GetHogKit

/// Replays scripted HTTP responses so session state can be tested without network.
private actor ScriptedTransport: HTTPTransport {
    private var responses: [(Int, String)]
    private(set) var requestPaths: [String] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestPaths.append(request.url?.path ?? "")
        let (status, body) = responses.count == 1 ? responses[0] : responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// Holds one foreground snapshot refresh after it has captured its client and
/// project, while allowing a replacement session's requests to continue.
private actor HeldSnapshotTransport: HTTPTransport {
    private let base = DemoTransport()
    private var shouldHoldDashboardList = false
    private var isHoldingDashboardList = false
    private var dashboardListCount = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func holdNextDashboardList() {
        shouldHoldDashboardList = true
    }

    func waitUntilHeld() async {
        if isHoldingDashboardList { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func waitUntilDashboardListCount(_ count: Int) async {
        if dashboardListCount >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isDashboardList = request.httpMethod == "GET"
            && request.url?.path(percentEncoded: false).hasSuffix("/dashboards/") == true
        if isDashboardList {
            dashboardListCount += 1
            let ready = countWaiters.filter { dashboardListCount >= $0.count }
            countWaiters.removeAll { dashboardListCount >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
        if shouldHoldDashboardList, isDashboardList {
            shouldHoldDashboardList = false
            isHoldingDashboardList = true
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { releaseContinuation = $0 }
            isHoldingDashboardList = false
        }
        return try await base.send(request)
    }
}

/// Records only method and decoded path, never the Authorization header. These
/// tests need to prove whether a pending hand-off spent a PATCH without ever
/// retaining the synthetic credential used to authenticate the request.
private actor RecordingDemoTransport: HTTPTransport {
    private let base = DemoTransport()
    private var requests: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path(percentEncoded: false) ?? ""
        requests.append("\(method) \(path)")
        return try await base.send(request)
    }

    func count(method: String, path: String) -> Int {
        requests.filter { $0 == "\(method) \(path)" }.count
    }
}

private actor ForegroundCacheTransport: HTTPTransport {
    private let base = DemoTransport()
    private var dashboardDetailCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        if path == "/api/projects/1001/dashboards/9001/" {
            dashboardDetailCount += 1
            let body = """
            {"id":9001,"name":"Session \(dashboardDetailCount) dashboard","tiles":[]}
            """
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        return try await base.send(request)
    }

    func count() -> Int { dashboardDetailCount }
}

private actor HeldForegroundCacheTransport: HTTPTransport {
    private let base = DemoTransport()
    private var hasHeldDashboard = false
    private var dashboardDetailCount = 0
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        guard path == "/api/projects/1001/dashboards/9001/" else {
            return try await base.send(request)
        }

        dashboardDetailCount += 1
        guard dashboardDetailCount == 1 else {
            let body = """
            {"id":9001,"name":"Session \(dashboardDetailCount) dashboard","tiles":[]}
            """
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        hasHeldDashboard = true
        let waiters = arrivals
        arrivals.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
        let body = #"{"id":9001,"name":"Revoked dashboard","tiles":[]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func waitUntilHeld() async {
        if hasHeldDashboard { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func releaseHeldDashboard() {
        release?.resume()
        release = nil
    }

    func count() -> Int { dashboardDetailCount }
}

private actor HeldReplacementAuthenticationTransport: HTTPTransport {
    private let base = DemoTransport()
    private var authenticationCount = 0
    private var dashboardDetailCount = 0
    private var replacementAuthenticationHeld = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        if path == "/api/users/@me/" {
            authenticationCount += 1
            if authenticationCount == 2 {
                replacementAuthenticationHeld = true
                let waiters = arrivalWaiters
                arrivalWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { release = $0 }
            }
        }

        if path == "/api/projects/1001/dashboards/9001/" {
            dashboardDetailCount += 1
            let body = #"{"id":9001,"name":"Replacement dashboard","tiles":[]}"#
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        return try await base.send(request)
    }

    func waitUntilReplacementAuthenticationHeld() async {
        if replacementAuthenticationHeld { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func releaseReplacementAuthentication() {
        release?.resume()
        release = nil
    }

    func dashboardCount() -> Int { dashboardDetailCount }
}

private actor CacheGenerationBoundaryGate {
    private var hasArrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func wait() async {
        hasArrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilHeld() async {
        if hasArrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func releaseBoundary() {
        release?.resume()
        release = nil
    }
}

private let meJSON = """
{"email":"a@example.com","first_name":"Ada","distinct_id":"d1",
 "team":{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"},
 "organization":{"id":"org1","name":"Acme",
   "teams":[{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"},
            {"id":43,"name":"Staging","api_token":"phc_y","timezone":"UTC"}]},
 "organizations":[{"id":"org1","name":"Acme"}]}
"""

/// Serialized because the selected project is persisted to
/// `UserDefaults.standard` — that is the whole point of it, so a relaunch and an
/// out-of-process intent agree on which project is live — and these tests
/// therefore share one piece of global state. Run in parallel, a test that
/// switches projects can be in flight while another is asserting which project a
/// fresh connection restores.
@Suite("AppModel session", .serialized)
@MainActor
struct AppModelTests {

    private struct SeededProjectRecords {
        let snapshot: SharedSnapshot
        let flagWrite: PendingFlagWrite
        let open: PendingOpen
    }

    private func makeSnapshotStore() -> (SharedSnapshotStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)", isDirectory: true)
        return (SharedSnapshotStore(directory: directory), directory)
    }

    private func seedProjectRecords(
        in store: SharedSnapshotStore,
        projectID: Int
    ) throws -> SeededProjectRecords {
        let snapshot = SharedSnapshot(
            projectID: projectID,
            projectName: "Synthetic Workspace",
            metrics: [],
            flags: [],
            projectRegion: .usCloud,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let flagWrite = PendingFlagWrite(
            flagID: 71,
            key: "synthetic-rollout",
            desiredActive: true,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let open = PendingOpen(
            metricID: "synthetic-metric",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try store.write(snapshot)
        try store.enqueue(flagWrite)
        try store.enqueue(open)

        return SeededProjectRecords(
            snapshot: snapshot,
            flagWrite: flagWrite,
            open: open
        )
    }

    @Test("starts in onboarding when no credential is stored")
    func noCredentialMeansOnboarding() async {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        await model.bootstrap()
        #expect(model.phase == .onboarding)
    }

    @Test("connecting loads identity, projects and a selected project")
    func connectPopulatesSession() async throws {
        let store = InMemoryTokenStore()
        let model = AppModel(
            store: store,
            transport: ScriptedTransport([(200, meJSON)])
        )

        try await model.connect(key: "phx_abc", region: .usCloud)

        #expect(model.phase == .ready)
        #expect(model.me?.email == "a@example.com")
        #expect(model.projects.count == 2)
        #expect(model.selectedProject?.id == 42)
        // The key must be persisted so the next launch skips onboarding.
        #expect(try store.load()?.key == "phx_abc")
    }

    @Test("the foreground response cache follows the persisted authentication epoch")
    func foregroundCacheIsFencedByAuthenticationEpoch() async throws {
        let cache = ResponseCache(
            subdirectory: "AppModelForegroundCacheTests-\(UUID().uuidString)"
        )
        let transport = ForegroundCacheTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            cache: cache
        )
        let endpoint = PostHogAPI.dashboard(projectID: 1_001, dashboardID: 9_001)

        try await model.connect(key: "synthetic-first-session", region: .usCloud)
        let firstClient = try #require(model.client)
        let first: Dashboard = try await firstClient.sendCached(endpoint, ttl: 300)
        let reused: Dashboard = try await firstClient.sendCached(endpoint, ttl: 300)
        #expect(first.title == "Session 1 dashboard")
        #expect(reused.title == first.title)

        try await model.connect(key: "synthetic-replacement-session", region: .usCloud)
        let replacementClient = try #require(model.client)
        let replacement: Dashboard = try await replacementClient.sendCached(endpoint, ttl: 300)

        #expect(replacement.title == "Session 2 dashboard")
        #expect(await transport.count() == 2)
        await cache.clear()
    }

    @Test("sign out revokes an in-flight client's cache publication before clearing")
    func signOutRevokesHeldCachePublication() async throws {
        let cache = ResponseCache(
            subdirectory: "AppModelSignOutCacheTests-\(UUID().uuidString)"
        )
        let transport = HeldForegroundCacheTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            cache: cache
        )
        try await model.connect(key: "synthetic-first-session", region: .usCloud)
        let oldClient = try #require(model.client)
        let oldNamespace = try #require(model.authSessionID).uuidString
        let endpoint = PostHogAPI.dashboard(projectID: 1_001, dashboardID: 9_001)
        await cache.store(Data("sentinel".utf8), for: "synthetic-sign-out-sentinel")

        let staleRequest = Task {
            try await oldClient.sendCached(endpoint, ttl: 300) as Dashboard
        }
        await transport.waitUntilHeld()

        await model.signOut()
        #expect(await cache.totalSizeBytes() == 0)

        await transport.releaseHeldDashboard()
        _ = try? await staleRequest.value

        let probeTransport = ForegroundCacheTransport()
        let probe = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic-probe-session", region: .usCloud),
            transport: probeTransport,
            responseCache: cache,
            responseCacheNamespace: oldNamespace
        )
        let recovered: Dashboard = try await probe.sendCached(endpoint, ttl: 300)

        #expect(recovered.title == "Session 1 dashboard")
        #expect(await probeTransport.count() == 1)
        await cache.clear()
    }

    @Test("sign out revokes cache publications from every prior credential epoch")
    func signOutRevokesAllPriorCachePublications() async throws {
        let cache = ResponseCache(
            subdirectory: "AppModelAllPriorLeaseTests-\(UUID().uuidString)"
        )
        let transport = HeldForegroundCacheTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            cache: cache
        )
        let endpoint = PostHogAPI.dashboard(projectID: 1_001, dashboardID: 9_001)

        try await model.connect(key: "synthetic-session-a", region: .usCloud)
        let clientA = try #require(model.client)
        let namespaceA = try #require(model.authSessionID).uuidString
        let staleRequestA = Task {
            try await clientA.sendCached(endpoint, ttl: 300) as Dashboard
        }
        await transport.waitUntilHeld()

        try await model.connect(key: "synthetic-session-b", region: .usCloud)
        await model.signOut()

        await transport.releaseHeldDashboard()
        _ = try? await staleRequestA.value

        let probeTransport = ForegroundCacheTransport()
        let probe = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic-probe-session", region: .usCloud),
            transport: probeTransport,
            responseCache: cache,
            responseCacheNamespace: namespaceA
        )
        let recovered: Dashboard = try await probe.sendCached(endpoint, ttl: 300)

        #expect(recovered.title == "Session 1 dashboard")
        #expect(await probeTransport.count() == 1)
        await cache.clear()
    }

    @Test("a replacement session survives an older unauthorized cache teardown")
    func replacementSurvivesUnauthorizedCacheTeardown() async throws {
        let boundary = CacheGenerationBoundaryGate()
        let cache = ResponseCache(
            subdirectory: "AppModelReplacementDuringTeardownTests-\(UUID().uuidString)",
            beforePublicationCommit: {},
            beforeGenerationClear: { await boundary.wait() }
        )
        let transport = HeldForegroundCacheTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            cache: cache
        )
        let endpoint = PostHogAPI.dashboard(projectID: 1_001, dashboardID: 9_001)

        try await model.connect(key: "synthetic-session-a", region: .usCloud)
        let scopeA = try #require(model.flagWriteScope)
        let clientA = try #require(model.client)
        let namespaceA = try #require(model.authSessionID).uuidString
        let staleRequestA = Task {
            try await clientA.sendCached(endpoint, ttl: 300) as Dashboard
        }
        await transport.waitUntilHeld()

        let teardownA = Task {
            await model.invalidateRejectedCredential(ifCurrent: scopeA)
        }
        await boundary.waitUntilHeld()

        try await model.connect(key: "synthetic-session-b", region: .usCloud)
        let scopeB = try #require(model.flagWriteScope)
        let clientB = try #require(model.client)

        await boundary.releaseBoundary()
        await teardownA.value

        #expect(model.phase == .ready)
        #expect(model.flagWriteScope == scopeB)
        #expect(model.client === clientB)
        #expect(model.connectionError == nil)
        #expect(model.storedCredentialRecovery == nil)

        await transport.releaseHeldDashboard()
        _ = try? await staleRequestA.value

        let firstB: Dashboard = try await clientB.sendCached(endpoint, ttl: 300)
        let reusedB: Dashboard = try await clientB.sendCached(endpoint, ttl: 300)
        #expect(firstB.title == "Session 2 dashboard")
        #expect(reusedB.title == firstB.title)
        #expect(await transport.count() == 2)

        let probeTransport = ForegroundCacheTransport()
        let probeA = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic-probe-session", region: .usCloud),
            transport: probeTransport,
            responseCache: cache,
            responseCacheNamespace: namespaceA
        )
        let recoveredA: Dashboard = try await probeA.sendCached(endpoint, ttl: 300)
        #expect(recoveredA.title == "Session 1 dashboard")
        #expect(await probeTransport.count() == 1)
        await cache.clear()
    }

    @Test("a replacement session survives an older user-initiated sign out")
    func replacementSurvivesUserInitiatedSignOut() async throws {
        let boundary = CacheGenerationBoundaryGate()
        let cache = ResponseCache(
            subdirectory: "AppModelReplacementDuringSignOutTests-\(UUID().uuidString)",
            beforePublicationCommit: {},
            beforeGenerationClear: { await boundary.wait() }
        )
        let transport = ForegroundCacheTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            cache: cache
        )

        try await model.connect(key: "synthetic-session-a", region: .usCloud)
        let signOutA = Task { await model.signOut() }
        await boundary.waitUntilHeld()

        try await model.connect(key: "synthetic-session-b", region: .usCloud)
        let scopeB = try #require(model.flagWriteScope)
        let clientB = try #require(model.client)

        await boundary.releaseBoundary()
        await signOutA.value

        #expect(model.phase == .ready)
        #expect(model.flagWriteScope == scopeB)
        #expect(model.client === clientB)

        let endpoint = PostHogAPI.dashboard(projectID: 1_001, dashboardID: 9_001)
        let firstB: Dashboard = try await clientB.sendCached(endpoint, ttl: 300)
        let reusedB: Dashboard = try await clientB.sendCached(endpoint, ttl: 300)
        #expect(firstB.title == "Session 1 dashboard")
        #expect(reusedB.title == firstB.title)
        #expect(await transport.count() == 1)
        await cache.clear()
    }

    @Test("replacement authentication finishing after an older teardown publishes a current cache lease")
    func replacementAuthenticationAfterOlderTeardownPublishesCurrentCacheLease() async throws {
        let cache = ResponseCache(
            subdirectory: "AppModelReplacementAfterTeardownTests-\(UUID().uuidString)"
        )
        let transport = HeldReplacementAuthenticationTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            cache: cache
        )
        let endpoint = PostHogAPI.dashboard(projectID: 1_001, dashboardID: 9_001)

        try await model.connect(key: "synthetic-session-a", region: .usCloud)
        let scopeA = try #require(model.flagWriteScope)
        await cache.store(Data("sentinel".utf8), for: "synthetic-inverse-order-sentinel")

        let replacementAuthentication = Task {
            try await model.connect(key: "synthetic-session-b", region: .usCloud)
        }
        await transport.waitUntilReplacementAuthenticationHeld()

        await model.invalidateRejectedCredential(ifCurrent: scopeA)
        #expect(model.phase == .onboarding)
        #expect(await cache.totalSizeBytes() == 0)

        await transport.releaseReplacementAuthentication()
        try await replacementAuthentication.value

        let clientB = try #require(model.client)
        let scopeB = try #require(model.flagWriteScope)
        #expect(model.phase == .ready)
        #expect(scopeB.authSessionID != scopeA.authSessionID)

        let first: Dashboard = try await clientB.sendCached(endpoint, ttl: 300)
        let reused: Dashboard = try await clientB.sendCached(endpoint, ttl: 300)
        #expect(first.title == "Replacement dashboard")
        #expect(reused.title == first.title)
        #expect(await transport.dashboardCount() == 1)
        await cache.clear()
    }

    @Test("a rejected key does not persist a credential")
    func rejectedKeyIsNotStored() async throws {
        let store = InMemoryTokenStore()
        let body = #"{"type":"authentication_error","code":"not_authenticated","detail":"nope"}"#
        let model = AppModel(store: store, transport: ScriptedTransport([(401, body)]))

        await #expect(throws: (any Error).self) {
            try await model.connect(key: "phx_bad", region: .usCloud)
        }
        #expect(model.phase != .ready)
        #expect(try store.load() == nil)
    }

    @Test("a stored credential that no longer works falls back to onboarding with a reason")
    func staleCredentialExplainsItself() async {
        let store = InMemoryTokenStore(
            credential: StoredCredential(key: "phx_stale", region: .euCloud)
        )
        let model = AppModel(store: store, transport: ScriptedTransport([(401, "{}")]))

        await model.bootstrap()

        // Landing on an empty dashboard with no explanation would be worse than
        // sending the user back to onboarding.
        #expect(model.phase == .onboarding)
        #expect(model.connectionError != nil)
        #expect(model.storedCredentialRecovery == .replaceCredential(.euCloud))
        #expect((try? store.load()) == nil)
    }

    @Test("a transient stored-credential failure keeps the credential and can retry")
    func transientStoredCredentialFailureCanRetry() async throws {
        let credential = StoredCredential(key: "phx_retry", region: .usCloud)
        let store = InMemoryTokenStore(credential: credential)
        let transport = ScriptedTransport([
            (503, #"{"detail":"Synthetic maintenance window"}"#),
            (200, meJSON),
        ])
        let model = AppModel(store: store, transport: transport)

        await model.bootstrap()

        #expect(model.phase == .onboarding)
        #expect(model.storedCredentialRecovery == .retryable)
        #expect(try store.load() == credential)

        await model.retryStoredCredential()

        #expect(model.phase == .ready)
        #expect(model.storedCredentialRecovery == nil)
        let loaded = try store.load()
        let migrated = try #require(loaded)
        #expect(migrated.key == credential.key)
        #expect(migrated.region == credential.region)
        #expect(migrated.authSessionID != nil)
        #expect(model.flagWriteScope?.authSessionID == migrated.authSessionID)
    }

    @Test("a successful legacy bootstrap durably migrates its authentication epoch")
    func legacyCredentialMigratesAfterAuthentication() async throws {
        let legacy = StoredCredential(key: "synthetic-legacy-key", region: .usCloud)
        let store = InMemoryTokenStore(credential: legacy)
        let (snapshots, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: store,
            transport: DemoTransport(),
            snapshotStore: snapshots
        )

        await model.bootstrap()

        #expect(model.phase == .ready)
        let loaded = try store.load()
        let migrated = try #require(loaded)
        let epoch = try #require(migrated.authSessionID)
        #expect(migrated.key == legacy.key)
        #expect(migrated.region == legacy.region)
        #expect(model.flagWriteScope?.authSessionID == epoch)
    }

    @Test("onboarding offers retry for a transient failure and replacement for a rejected key")
    func onboardingRecoveryActionsMatchCredentialState() {
        let retry = OnboardingRecoveryPresentation(
            recovery: .retryable,
            message: "Synthetic service interruption"
        )
        let replace = OnboardingRecoveryPresentation(
            recovery: .replaceCredential(.euCloud),
            message: "Synthetic key rejection"
        )

        #expect(retry.title == "Couldn't reconnect")
        #expect(retry.primaryActionTitle == "Try again")
        #expect(retry.primaryAction == .retryStoredCredential)
        #expect(retry.message == "Synthetic service interruption")

        #expect(replace.title == "Saved key rejected")
        #expect(replace.primaryActionTitle == "Enter a new key")
        #expect(replace.primaryAction == .replaceCredential(.euCloud))
        #expect(replace.message == "Synthetic key rejection")
    }

    @Test("signing out clears the credential and the session")
    func signOutClearsEverything() async throws {
        let (snapshots, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryTokenStore()
        let model = AppModel(
            store: store,
            transport: ScriptedTransport([(200, meJSON)]),
            snapshotStore: snapshots
        )
        try await model.connect(key: "phx_abc", region: .usCloud)
        // Seed after authentication. A legacy snapshot has no credential epoch
        // and is correctly cleared during connection; this test is about the
        // separate sign-out boundary.
        let seeded = try seedProjectRecords(in: snapshots, projectID: 42)
        #expect(snapshots.loadOrNil() != nil)
        #expect(snapshots.pendingFlagWrite() == seeded.flagWrite)
        #expect(snapshots.pendingOpen() == seeded.open)

        await model.signOut()

        #expect(model.phase == .onboarding)
        #expect(model.me == nil)
        #expect(model.projects.isEmpty)
        #expect(try store.load() == nil)
        #expect(snapshots.loadOrNil() == nil)
        #expect(snapshots.pendingFlagWrite() == nil)
        #expect(snapshots.pendingOpen() == nil)
    }

    @Test("a snapshot refresh held across sign out cannot republish project data")
    func staleSnapshotRefreshCannotUndoSignOut() async throws {
        let (snapshots, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = HeldSnapshotTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshots
        )
        try await model.connect(key: "synthetic-first-session", region: .usCloud)
        #expect(snapshots.loadOrNil() != nil)

        // `selectedProject` starts one publication and `activate` awaits a
        // second. Drain both so the hold below belongs to this explicit refresh
        // rather than to bootstrap work whose task happened to start late.
        await transport.waitUntilDashboardListCount(2)
        await transport.holdNextDashboardList()
        let staleRefresh = Task { await model.publishWidgetSnapshot() }
        await transport.waitUntilHeld()

        await model.signOut()
        #expect(snapshots.loadOrNil() == nil)

        await transport.release()
        #expect(await staleRefresh.value == false)
        #expect(snapshots.loadOrNil() == nil)
    }

    @Test("a prior auth epoch cannot overwrite a same-project replacement session")
    func staleSnapshotRefreshCannotAdoptReplacementAuthEpoch() async throws {
        let (snapshots, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = HeldSnapshotTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshots
        )
        try await model.connect(key: "synthetic-first-session", region: .usCloud)
        let firstScope = try #require(model.flagWriteScope)

        await transport.waitUntilDashboardListCount(2)
        await transport.holdNextDashboardList()
        let staleRefresh = Task { await model.publishWidgetSnapshot() }
        await transport.waitUntilHeld()

        try await model.connect(key: "synthetic-replacement-session", region: .usCloud)
        let replacementScope = try #require(model.flagWriteScope)
        #expect(replacementScope.authSessionID != firstScope.authSessionID)
        let replacementSnapshot = try #require(snapshots.loadOrNil())
        #expect(replacementSnapshot.authSessionID == replacementScope.authSessionID)

        await transport.release()
        #expect(await staleRefresh.value == false)
        #expect(snapshots.loadOrNil() == replacementSnapshot)
    }

    @Test("entering the demo becomes ready without persisting a credential")
    func enterDemoIsEphemeral() async throws {
        let store = InMemoryTokenStore()
        // A transport that would fail any request, proving demo entry never
        // routes through the transport the model was built with.
        let model = AppModel(store: store, transport: ScriptedTransport([(500, "{}")]))

        await model.enterDemo()

        #expect(model.phase == .ready)
        #expect(model.isDemo)
        // Nothing may be persisted: the demo credential is the literal string
        // "demo", and a store that kept it would greet the next launch with it.
        #expect(try store.load() == nil)
    }

    @Test("signing out of the demo restores the transport the model was built with")
    func signOutLeavesDemo() async throws {
        let store = InMemoryTokenStore()
        let model = AppModel(store: store, transport: ScriptedTransport([(200, meJSON)]))

        await model.enterDemo()
        await model.signOut()

        #expect(model.phase == .onboarding)
        #expect(!model.isDemo)

        // The next connection must reach the injected transport again, not the
        // demo fixtures the session just left.
        try await model.connect(key: "phx_abc", region: .usCloud)
        #expect(model.phase == .ready)
        #expect(try store.load()?.key == "phx_abc")
    }

    @Test("signing out of a runtime demo preserves real shared project records")
    func runtimeDemoSignOutPreservesSharedProjectRecords() async throws {
        let (snapshots, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Deliberately differ from the demo's 1001/US scope. Entering an
        // ephemeral demo must not take ownership of real project records.
        let seeded = try seedProjectRecords(in: snapshots, projectID: 42)
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(500, "{}")]),
            snapshotStore: snapshots
        )

        await model.enterDemo()
        #expect(snapshots.loadOrNil() == seeded.snapshot)
        await model.signOut()

        #expect(snapshots.loadOrNil() == seeded.snapshot)
        #expect(snapshots.pendingFlagWrite() == seeded.flagWrite)
        #expect(snapshots.pendingOpen() == seeded.open)
    }

    @Test("self-hosted regions are preserved, since OAuth can never reach them")
    func selfHostedRegionSurvives() async throws {
        let store = InMemoryTokenStore()
        let host = URL(string: "https://ph.internal.example")!
        let model = AppModel(store: store, transport: ScriptedTransport([(200, meJSON)]))

        try await model.connect(key: "phx_abc", region: .selfHosted(host))

        #expect(try store.load()?.region == .selfHosted(host))
        #expect(model.client?.host == host)
    }

    // MARK: - Widget flag-write provenance

    @Test("a cold process reuses the saved epoch and completes the widget hand-off")
    func coldProcessCompletesAuthenticatedWidgetHandoff() async throws {
        let (snapshotStore, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryTokenStore()
        let transport = RecordingDemoTransport()
        let initial = AppModel(
            store: store,
            transport: transport,
            snapshotStore: snapshotStore
        )
        try await initial.connect(key: "synthetic-widget-key", region: .usCloud)
        let initialScope = try #require(initial.flagWriteScope)
        let flagID = 710_301
        let quickToggleScope = FlagQuickToggle.Scope(
            projectID: initialScope.projectID,
            region: try #require(initialScope.projectRegion)
        )
        FlagQuickToggle.setAllowed(true, flagID: flagID, scope: quickToggleScope)
        defer { FlagQuickToggle.setAllowed(false, flagID: flagID, scope: quickToggleScope) }
        try snapshotStore.enqueue(PendingFlagWrite(
            flagID: flagID,
            key: "example-navigation",
            desiredActive: false,
            projectID: initialScope.projectID,
            projectRegion: initialScope.projectRegion,
            authSessionID: initialScope.authSessionID
        ))

        // This is deliberately a new AppModel: a widget launches the app into a
        // fresh process, where an in-memory UUID cannot prove the old snapshot.
        let relaunched = AppModel(
            store: store,
            transport: transport,
            snapshotStore: snapshotStore
        )
        await relaunched.bootstrap()
        let relaunchedScope = try #require(relaunched.flagWriteScope)
        #expect(relaunchedScope.authSessionID == initialScope.authSessionID)

        await relaunched.consumePendingIntentWork()

        let path = "/api/projects/\(initialScope.projectID)/feature_flags/\(flagID)/"
        #expect(await transport.count(method: "PATCH", path: path) == 1)
        #expect(snapshotStore.pendingFlagWrite() == nil)
    }

    @Test("a replacement credential rejects the prior epoch's widget hand-off")
    func replacementCredentialRejectsPriorWidgetHandoff() async throws {
        let (snapshotStore, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryTokenStore()
        let transport = RecordingDemoTransport()
        let initial = AppModel(
            store: store,
            transport: transport,
            snapshotStore: snapshotStore
        )
        try await initial.connect(key: "synthetic-first-widget-key", region: .usCloud)
        let initialScope = try #require(initial.flagWriteScope)
        let flagID = 710_301
        let quickToggleScope = FlagQuickToggle.Scope(
            projectID: initialScope.projectID,
            region: try #require(initialScope.projectRegion)
        )
        FlagQuickToggle.setAllowed(true, flagID: flagID, scope: quickToggleScope)
        defer { FlagQuickToggle.setAllowed(false, flagID: flagID, scope: quickToggleScope) }
        let staleHandoff = PendingFlagWrite(
            flagID: flagID,
            key: "example-navigation",
            desiredActive: true,
            projectID: initialScope.projectID,
            projectRegion: initialScope.projectRegion,
            authSessionID: initialScope.authSessionID
        )

        let replacement = AppModel(
            store: store,
            transport: transport,
            snapshotStore: snapshotStore
        )
        try await replacement.connect(
            key: "synthetic-replacement-widget-key",
            region: .usCloud
        )
        let replacementScope = try #require(replacement.flagWriteScope)
        #expect(replacementScope.authSessionID != initialScope.authSessionID)

        // Model the extension finishing after replacement activation cleared
        // the old cache. The app must reject the record by its epoch, not merely
        // benefit from having cleared a record that arrived earlier.
        try snapshotStore.enqueue(staleHandoff)
        await replacement.consumePendingIntentWork()

        let path = "/api/projects/\(initialScope.projectID)/feature_flags/\(flagID)/"
        #expect(await transport.count(method: "PATCH", path: path) == 0)
        #expect(snapshotStore.pendingFlagWrite() == nil)
    }

    @Test("a pending widget write applies only in the authenticated snapshot scope")
    func pendingWidgetWriteUsesRecordedScope() async throws {
        let (snapshotStore, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ScriptedTransport([(200, meJSON), (200, "{}")])
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshotStore
        )
        try await model.connect(key: "synthetic-widget-scope-key", region: .usCloud)
        let scope = try #require(model.flagWriteScope)
        let flagID = 71_401
        let quickToggleScope = FlagQuickToggle.Scope(
            projectID: scope.projectID,
            region: try #require(scope.projectRegion)
        )
        FlagQuickToggle.setAllowed(true, flagID: flagID, scope: quickToggleScope)
        defer { FlagQuickToggle.setAllowed(false, flagID: flagID, scope: quickToggleScope) }

        try snapshotStore.enqueue(PendingFlagWrite(
            flagID: flagID,
            key: "synthetic-widget-rollout",
            desiredActive: true,
            projectID: scope.projectID,
            projectRegion: scope.projectRegion,
            authSessionID: scope.authSessionID
        ))

        await model.consumePendingIntentWork()

        let writes = await transport.requestPaths.filter {
            $0 == "/api/projects/\(scope.projectID)/feature_flags/\(flagID)"
        }
        #expect(writes.count == 1)
        #expect(snapshotStore.pendingFlagWrite() == nil)
    }

    @Test("widget flag write names the catalog fallback when a 403 omits its scope")
    func widgetFlagWriteUsesFeatureFlagScopeFallback() async throws {
        let transport = ScriptedTransport([
            (200, meJSON),
            (403, #"{"detail":"Synthetic permission refusal"}"#),
        ])
        let model = AppModel(store: InMemoryTokenStore(), transport: transport)
        try await model.connect(key: "synthetic-widget-scope-key", region: .usCloud)

        let outcome = await model.setFlag(id: 71_403, active: true)
        let message: String
        switch outcome {
        case .changed:
            Issue.record("The synthetic 403 was reported as a successful flag write.")
            return
        case .failed(let failure):
            message = failure
        }

        #expect(message.contains("feature_flag:write"))
    }

    @Test("stale and legacy pending widget writes are discarded without a PATCH")
    func pendingWidgetWriteRejectsUnprovenScope() async throws {
        let (snapshotStore, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ScriptedTransport([(200, meJSON), (200, "{}")])
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshotStore
        )
        try await model.connect(key: "synthetic-widget-scope-key", region: .usCloud)
        let scope = try #require(model.flagWriteScope)
        let flagID = 71_402
        let quickToggleScope = FlagQuickToggle.Scope(
            projectID: scope.projectID,
            region: try #require(scope.projectRegion)
        )
        FlagQuickToggle.setAllowed(true, flagID: flagID, scope: quickToggleScope)
        defer { FlagQuickToggle.setAllowed(false, flagID: flagID, scope: quickToggleScope) }

        let untrusted = [
            PendingFlagWrite(
                flagID: flagID,
                key: "synthetic-widget-rollout",
                desiredActive: true
            ),
            PendingFlagWrite(
                flagID: flagID,
                key: "synthetic-widget-rollout",
                desiredActive: true,
                projectID: scope.projectID + 1,
                projectRegion: scope.projectRegion,
                authSessionID: scope.authSessionID
            ),
            PendingFlagWrite(
                flagID: flagID,
                key: "synthetic-widget-rollout",
                desiredActive: true,
                projectID: scope.projectID,
                projectRegion: .euCloud,
                authSessionID: scope.authSessionID
            ),
            PendingFlagWrite(
                flagID: flagID,
                key: "synthetic-widget-rollout",
                desiredActive: true,
                projectID: scope.projectID,
                projectRegion: scope.projectRegion,
                authSessionID: UUID()
            ),
        ]

        for pending in untrusted {
            try snapshotStore.enqueue(pending)
            await model.consumePendingIntentWork()
            #expect(snapshotStore.pendingFlagWrite() == nil)
        }

        let writes = await transport.requestPaths.filter {
            $0 == "/api/projects/\(scope.projectID)/feature_flags/\(flagID)"
        }
        #expect(writes.isEmpty)
    }

    // MARK: - Links naming another project

    @Test("a link for another accessible project switches to it")
    func linkSwitchesProject() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        try await model.connect(key: "phx_abc", region: .usCloud)
        let current = try #require(model.selectedProject)
        let other = try #require(model.projects.first { $0.id != current.id })

        #expect(model.selectProject(id: other.id) == .switched(name: other.name))
        #expect(model.selectedProject?.id == other.id)

        // Left as it was found: the selection outlives this model in shared
        // defaults, and the next test connects expecting the same project a
        // real relaunch would restore.
        #expect(model.selectProject(id: current.id) == .switched(name: current.name))
    }

    @Test("a link for the project already on screen moves nothing")
    func linkForCurrentProject() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        try await model.connect(key: "phx_abc", region: .usCloud)
        let current = try #require(model.selectedProject?.id)

        #expect(model.selectProject(id: current) == .current)
        #expect(model.selectedProject?.id == current)
    }

    @Test("a link for a project this key cannot see is refused, not redirected")
    func linkForInaccessibleProject() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        try await model.connect(key: "phx_abc", region: .usCloud)

        // The failure this guards against: resolving the link's object id
        // against whichever project happened to be selected, which would put
        // one project's numbers on screen under another project's name.
        #expect(model.selectProject(id: 999) == .inaccessible)
        #expect(model.selectedProject?.id == 42)
    }
}

// MARK: - Reducing a tile to a widget metric

/// Pins `SharedSnapshot.Metric.init?(tile:dashboardID:)` — the kit's reduction
/// of one dashboard tile to the value the widgets, Smart Stack and metric
/// alerts all read — from the app's side.
///
/// The app carried its own copy of this rule until it was retired in favour of
/// the kit's. This suite was written against that copy and is kept, re-pointed,
/// rather than deleted: the kit's own "Dashboard tile reduced to a snapshot
/// metric" suite pins the same initialiser from inside the package, and these
/// pin that the *app* is calling it and getting these answers. A reduction with
/// one implementation and two callers is worth checking at both.
///
/// The reduction was `private static` and had no test at all, and that is
/// exactly how a permanent false decline reached the Lock Screen: the funnel
/// branch filled `SharedSnapshot.Metric.previous` — documented as "the
/// comparison-period value, nil means not known" — with the funnel's *step-1
/// count*. `SharedSnapshotTests` already pinned how `previous` is turned into a
/// delta, so the arithmetic was covered and the *input* was not, and a covered
/// derivation over a poisoned input is still wrong on screen.
///
/// Tiles are built by decoding JSON rather than by a memberwise initialiser
/// because `Tile` and `Insight` only have `Decodable` ones — which is the
/// better test anyway: it drives the real decoder, so a change to how PostHog's
/// funnel payload is read breaks these rather than passing them by coincidence
/// of a hand-built value.
/// `@MainActor` because `AppModel` is, so its statics are too — matching
/// `AppModelTests` above. Unlike that suite this one holds no shared state, so
/// it does not need `.serialized`.
@Suite("Dashboard tile to widget metric")
@MainActor
struct TileMetricTests {

    private static func tile(_ json: String) throws -> Tile {
        try JSONDecoder().decode(Tile.self, from: Data(json.utf8))
    }

    /// A two-step funnel, 5,000 → 750. The numbers from the audit, so the
    /// −85% this used to report is what fails if the fix is reverted.
    private static let funnelJSON = """
        {"id": 1, "insight": {"id": 77, "name": "Signup funnel",
          "query": {"source": {"kind": "FunnelsQuery"}},
          "result": [{"name": "Visited", "count": 5000, "order": 0},
                     {"name": "Signed up", "count": 750, "order": 1}]}}
        """

    @Test("a funnel headline carries no comparison, because a funnel has none")
    func funnelHasNoBaseline() throws {
        let metric = try #require(
            SharedSnapshot.Metric(tile: Self.tile(Self.funnelJSON), dashboardID: 9)
        )

        // The last step is the headline, and that part was always right.
        #expect(metric.value == 750)

        // The whole defect, in one assertion. `previous` was `5000` — step 1 of
        // the same funnel, a different axis entirely. A funnel is monotonically
        // non-increasing and its steps arrive step-1-first, so this was
        // negative with a guaranteed sign and a large magnitude, forever.
        #expect(metric.previous == nil)
        #expect(metric.delta == nil)
        #expect(metric.deltaFraction == nil)

        // What the widget and VoiceOver actually branch on. `.down` here used
        // to produce "−85%" beside a down arrow and "down 85%" read aloud.
        #expect(metric.direction == .unknown)

        // `sparkline` documents "oldest to newest"; a funnel's step profile is
        // not a time axis, and `MetricWidget.legend` labels its ends
        // "low"/"high" next to a legend item named `prev`.
        #expect(metric.sparkline.isEmpty)
    }

    /// The branch the funnel one should have matched all along.
    @Test("a big number carries no comparison either")
    func bigNumberHasNoBaseline() throws {
        let tile = try Self.tile("""
            {"id": 2, "insight": {"id": 78, "name": "Total signups",
              "query": {"source": {"kind": "TrendsQuery",
                        "trendsFilter": {"display": "BoldNumber"}}},
              "result": [{"label": "signups", "aggregated_value": 1234}]}}
            """)

        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))
        #expect(metric.value == 1234)
        #expect(metric.previous == nil)
        #expect(metric.direction == .unknown)
    }

    /// The one branch entitled to a baseline, kept as the contrast case: a
    /// trends series *is* a time axis, so its second-to-last point really is
    /// the comparison period and `.down` really means down.
    @Test("a time series does carry a real comparison")
    func timeSeriesKeepsItsBaseline() throws {
        let tile = try Self.tile("""
            {"id": 3, "insight": {"id": 79, "name": "Daily signups",
              "query": {"source": {"kind": "TrendsQuery"}},
              "result": [{"label": "signups", "data": [10, 20, 15],
                          "days": ["2026-01-01", "2026-01-02", "2026-01-03"]}]}}
            """)

        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))
        #expect(metric.value == 15)
        #expect(metric.previous == 20)
        #expect(metric.direction == .down)
        #expect(metric.sparkline == [10, 20, 15])
    }

    /// Retention, paths and stickiness have no single headline figure and are
    /// deliberately not offered as widget metrics. Pinned so a future display
    /// type cannot fall into the funnel branch's old habit of inventing one.
    @Test("a shape with no single headline figure is offered no metric")
    func unsupportedShapesAreNotOffered() throws {
        let tile = try Self.tile("""
            {"id": 4, "insight": {"id": 80, "name": "Retention",
              "query": {"source": {"kind": "RetentionQuery"}},
              "result": [{"date": "2026-01-01", "label": "Day 0",
                          "values": [{"count": 10}, {"count": 4}]}]}}
            """)

        #expect(SharedSnapshot.Metric(tile: tile, dashboardID: 9) == nil)
    }
}
