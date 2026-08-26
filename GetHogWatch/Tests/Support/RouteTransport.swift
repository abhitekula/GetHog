import Foundation
import GetHogKit
@testable import GetHogWatch

/// A transport that answers by **marker** rather than by call order.
///
/// A refresh spends five requests and the model fires them in a fixed order
/// today, but a test that encoded that order would fail the first time the
/// order changed for a reason nobody cares about. Routing on the path — and on
/// a substring of the body, which is how two `/query/` nodes are told apart —
/// keeps the fixtures pinned to the *request* instead.
///
/// An actor because the recording has to survive concurrent sends without a
/// lock of its own.
actor RouteTransport: HTTPTransport {

    struct Route: Sendable {
        let pathContains: String
        let bodyContains: String?
        let body: String
        let status: Int

        init(
            pathContains: String,
            bodyContains: String? = nil,
            body: String,
            status: Int = 200
        ) {
            self.pathContains = pathContains
            self.bodyContains = bodyContains
            self.body = body
            self.status = status
        }
    }

    private let routes: [Route]
    private let unmatchedError: PostHogError?
    private(set) var requests: [URLRequest] = []

    init(routes: [Route], unmatchedError: PostHogError? = nil) {
        self.routes = routes
        self.unmatchedError = unmatchedError
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path(percentEncoded: false) ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard let route = routes.first(where: {
            path.contains($0.pathContains) && ($0.bodyContains.map(body.contains) ?? true)
        }) else {
            if let unmatchedError { throw unmatchedError }
            throw PostHogError.transport("no route for \(path)")
        }
        return (
            Data(route.body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: route.status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    /// Every request's path and query, as one string per request — enough to
    /// assert what was asked for without a test reaching into `URLRequest`.
    func requestedPaths() -> [String] {
        requests.map { request in
            let url = request.url
            let path = url?.path(percentEncoded: false) ?? ""
            let query = url?.query.map { "?\($0)" } ?? ""
            return path + query
        }
    }

    func requestBodies() -> [String] {
        requests.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }
}

/// A transport that refuses everything — the offline case, which the model has
/// a specific and load-bearing answer for.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PostHogError.network(
            code: NSURLErrorNotConnectedToInternet,
            description: "Synthetic offline failure"
        )
    }
}

/// A non-URL failure, so the Watch tests prove that only Foundation's -1009
/// branch earns iPhone-offline guidance.
struct UnavailableTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PostHogError.transport("synthetic unavailable failure")
    }
}

/// Holds the old project's first request until a replacement hand-off has
/// completed its own refresh. The model test can then release the stale
/// response and prove it is ignored rather than racing the adopted project.
actor HandoffRaceTransport: HTTPTransport {
    private let backing = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
    private var heldRequest: CheckedContinuation<Void, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private var isHoldingOldRequest = false

    func waitUntilOldRequestIsHeld() async {
        guard !isHoldingOldRequest else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiter = continuation
        }
    }

    func releaseOldRequest() {
        heldRequest?.resume()
        heldRequest = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        if path.contains("/api/projects/1001/dashboards/") && path.hasSuffix("/dashboards/") {
            await withCheckedContinuation { continuation in
                heldRequest = continuation
                isHoldingOldRequest = true
                suspensionWaiter?.resume()
                suspensionWaiter = nil
            }
        }
        return try await backing.send(request)
    }
}

/// Fails one selected request, then delegates every later request to the full
/// synthetic route table. This makes a retryable *partial* refresh cost the
/// normal five requests while still leaving four sections successful.
actor FailFirstWatchRequestTransport: HTTPTransport {
    private let backing = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
    private let pathContains: String
    private let bodyContains: String?
    private var hasFailed = false
    private(set) var requestCount = 0

    init(pathContains: String, bodyContains: String? = nil) {
        self.pathContains = pathContains
        self.bodyContains = bodyContains
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let path = request.url?.path(percentEncoded: false) ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !hasFailed,
           path.contains(pathContains),
           bodyContains.map(body.contains) ?? true {
            hasFailed = true
            return (
                Data(#"{"detail":"Synthetic retryable failure."}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        return try await backing.send(request)
    }
}

/// Suspends the first request so a test can start a second refresh against the
/// same model generation before either operation completes.
actor HeldFirstWatchRequestTransport: HTTPTransport {
    private let backing = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
    private var heldRequest: CheckedContinuation<Void, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private var isHoldingFirstRequest = false
    private(set) var requestCount = 0

    func waitUntilFirstRequestIsHeld() async {
        guard !isHoldingFirstRequest else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiter = continuation
        }
    }

    func releaseFirstRequest() {
        heldRequest?.resume()
        heldRequest = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 1 {
            await withCheckedContinuation { continuation in
                heldRequest = continuation
                isHoldingFirstRequest = true
                suspensionWaiter?.resume()
                suspensionWaiter = nil
            }
        }
        return try await backing.send(request)
    }
}

/// Fails the first refresh's Flags request, then suspends request one of the
/// retry generation. The test can inspect published carried state while both
/// retry callers await the same five-request operation.
actor HeldRetryWatchRequestTransport: HTTPTransport {
    private let backing = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
    private var heldRetry: CheckedContinuation<Void, Never>?
    private var isHoldingRetry = false
    private var retryReleased = false
    private var hasFailedInitialFlags = false
    private(set) var requestCount = 0

    /// Bounded so a regression that never starts retry request one reports a
    /// failed expectation instead of suspending the entire test target.
    func waitUntilRetryIsHeld() async -> Bool {
        for _ in 0..<500 {
            if isHoldingRetry { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isHoldingRetry
    }

    func releaseRetry() {
        retryReleased = true
        heldRetry?.resume()
        heldRetry = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 6, !retryReleased {
            isHoldingRetry = true
            await withCheckedContinuation { continuation in
                heldRetry = continuation
            }
        }

        let path = request.url?.path(percentEncoded: false) ?? ""
        if !hasFailedInitialFlags, path.contains("/feature_flags/") {
            hasFailedInitialFlags = true
            return (
                Data(#"{"detail":"Synthetic retryable failure."}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        return try await backing.send(request)
    }
}

/// A lock-backed clock because `WatchModel`'s injected clock is `@Sendable`
/// and the tolerance test must advance it without weakening strict concurrency.
final class LockedWatchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) {
        self.instant = instant
    }

    func now() -> Date {
        lock.withLock { instant }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { instant = instant.addingTimeInterval(interval) }
    }
}

/// A credential store that freezes one load after capturing its value.
///
/// The `/me` persistence race test uses this to hold the old credential load,
/// then starts a phone hand-off. The hand-off announces its revision before it
/// waits for the outer lock, so the test can positively observe both intent and
/// blocked state before releasing the old response to make its atomic choice.
final class HeldCredentialLoadStore: CredentialStoring, @unchecked Sendable {
    private let stateLock = NSLock()
    private var credential: StoredCredential?
    private var shouldHoldNextLoad = false
    private let heldLoadCaptured = DispatchSemaphore(value: 0)
    private let releaseHeldLoad = DispatchSemaphore(value: 0)
    private let handoffIntentAnnounced = DispatchSemaphore(value: 0)
    private var announcedRevision: UInt64?
    private var synchronizationTimedOut = false

    init(credential: StoredCredential?) {
        self.credential = credential
    }

    func holdNextLoad() {
        stateLock.withLock { shouldHoldNextLoad = true }
    }

    var didSynchronizationTimeout: Bool {
        stateLock.withLock { synchronizationTimedOut }
    }

    func waitUntilHeldLoadIsCaptured(timeout: TimeInterval = 5) throws {
        guard heldLoadCaptured.wait(timeout: .now() + timeout) == .success else {
            // Always release the producer even when the observation failed, so
            // a regression records a bounded failure instead of hanging the
            // rest of the target behind this test.
            releaseLoad()
            throw WatchTestSynchronizationError.heldLoadNotCaptured
        }
    }

    func releaseLoad() {
        releaseHeldLoad.signal()
    }

    func recordHandoffIntent(revision: UInt64) {
        stateLock.withLock { announcedRevision = revision }
        handoffIntentAnnounced.signal()
    }

    func waitUntilHandoffIntentIsAnnounced(timeout: TimeInterval = 5) throws -> UInt64 {
        guard handoffIntentAnnounced.wait(timeout: .now() + timeout) == .success,
              let revision = stateLock.withLock({ announcedRevision }) else {
            releaseLoad()
            throw WatchTestSynchronizationError.intentNotAnnounced
        }
        return revision
    }

    func currentCredential() -> StoredCredential? {
        stateLock.withLock { credential }
    }

    func load() throws -> StoredCredential? {
        let (captured, shouldHold) = stateLock.withLock {
            let shouldHold = shouldHoldNextLoad
            shouldHoldNextLoad = false
            return (credential, shouldHold)
        }
        if shouldHold {
            heldLoadCaptured.signal()
            if releaseHeldLoad.wait(timeout: .now() + 5) == .timedOut {
                stateLock.withLock { synchronizationTimedOut = true }
            }
        }
        return captured
    }

    func save(_ credential: StoredCredential) throws {
        stateLock.withLock { self.credential = credential }
    }

    func clear() throws {
        stateLock.withLock { credential = nil }
    }
}

/// A keychain stand-in whose read fails rather than returning an empty slot.
/// Identity bootstrap must treat both outcomes as unverified stored state and
/// keep quarantined project files out of the active widget container.
final class ThrowingCredentialLoadStore: CredentialStoring, @unchecked Sendable {
    enum Failure: Error { case syntheticReadFailure }

    func load() throws -> StoredCredential? {
        throw Failure.syntheticReadFailure
    }

    func save(_ credential: StoredCredential) throws {}
    func clear() throws {}
}

/// Pauses an apply after it has registered pending intent but before it can
/// enter credential serialization. The inverse race test can then start an old
/// model refresh in the exact window that previously captured the new revision
/// and incorrectly treated the old client as current.
final class PausedMutationIntent: @unchecked Sendable {
    private let lock = NSLock()
    private let announced = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var revision: UInt64?
    private var synchronizationTimedOut = false

    var didSynchronizationTimeout: Bool {
        lock.withLock { synchronizationTimedOut }
    }

    func pause(revision: UInt64) {
        lock.withLock { self.revision = revision }
        announced.signal()
        if release.wait(timeout: .now() + 5) == .timedOut {
            lock.withLock { synchronizationTimedOut = true }
        }
    }

    func waitUntilAnnounced(timeout: TimeInterval = 5) throws -> UInt64 {
        guard announced.wait(timeout: .now() + timeout) == .success,
              let revision = lock.withLock({ revision }) else {
            resume()
            throw WatchTestSynchronizationError.intentNotAnnounced
        }
        return revision
    }

    func resume() {
        release.signal()
    }
}

enum WatchTestSynchronizationError: Error {
    case heldLoadNotCaptured
    case intentNotAnnounced
}

/// Synthetic fixtures, valid against the kit's real decoders. Every id, name
/// and number here is invented; nothing is copied from a PostHog response.
enum WatchFixtures {

    /// A fixed instant, so a capture time can be asserted exactly.
    static let now = Date(timeIntervalSince1970: 1_754_000_000)

    static let credential = StoredCredential(
        key: "test-key-0001", region: .usCloud, projectID: 1001
    )

    static let dashboards = #"""
        {"count":1,"next":null,"previous":null,
         "results":[{"id":9001,"name":"Example wrist board","pinned":true}]}
        """#

    /// Two reducible tiles: a trends line (501) and a bold number (502).
    static let dashboard = #"""
        {"id":9001,"name":"Example wrist board","pinned":true,"tiles":[
          {"id":1,"insight":{"id":501,"name":"Example signups",
            "query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
            "result":[{"label":"signups","count":6,"data":[1,2,3],
              "days":["2026-01-16","2026-01-17","2026-01-18"]}]}},
          {"id":2,"insight":{"id":502,"name":"Example total",
            "query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery",
              "trendsFilter":{"display":"BoldNumber"}}},
            "result":[{"label":"total","count":0,"data":[],"aggregated_value":393}]}}
        ]}
        """#

    static let flags = #"""
        {"count":3,"next":null,"previous":null,"results":[
          {"id":1,"key":"example-a","active":true},
          {"id":2,"key":"example-b","active":false},
          {"id":3,"key":"example-dead","active":true,"deleted":true}]}
        """#

    /// The identity bootstrap used by a manually entered or DEBUG-only key.
    /// The real decoder reads the current project from `team`.
    static func me(
        projectID: Int,
        name: String = "Synthetic Analytics"
    ) -> String {
        #"{"team":{"id":\#(projectID),"name":"\#(name)"}}"#
    }

    static let errors = #"""
        {"results":[
          {"id":"i1","name":"ExampleFault","status":"active",
           "aggregations":{"occurrences":29}},
          {"id":"i2","name":"QuietFault","status":"resolved",
           "aggregations":{"occurrences":99}}]}
        """#

    /// A `QueryResponse` shaped exactly as `recentEventLines` asks for it:
    /// four columns, no `properties`.
    static func events(_ count: Int) -> String {
        let rows = (0..<count).map { index in
            """
            ["example-row-\(String(format: "%04d", index))",\
            "example_event_\(index)",\
            "2026-01-18T12:00:00.000Z",\
            "person-example-\(index)"]
            """
        }
        return """
            {"columns":["uuid","event","timestamp","distinct_id"],
             "results":[\(rows.joined(separator: ","))]}
            """
    }

    /// The five routes a full refresh needs, in one place so a test that cares
    /// about one of them does not have to spell the other four.
    static func fullRefreshRoutes(
        dashboards: String = WatchFixtures.dashboards,
        dashboard: String = WatchFixtures.dashboard,
        flags: String = WatchFixtures.flags,
        errors: String = WatchFixtures.errors,
        events: String = WatchFixtures.events(3),
        extra: [RouteTransport.Route] = []
    ) -> [RouteTransport.Route] {
        extra + [
            .init(pathContains: "/dashboards/9001/", body: dashboard),
            .init(pathContains: "/dashboards/", body: dashboards),
            .init(pathContains: "/feature_flags/", body: flags),
            .init(pathContains: "/query/", bodyContains: "ErrorTrackingQuery", body: errors),
            .init(pathContains: "/query/", bodyContains: "HogQLQuery", body: events),
        ]
    }

    /// A store in its own temporary directory, so no test can read another's
    /// snapshot and none of them can reach the real App Group container.
    static func tempStore() -> SharedSnapshotStore {
        SharedSnapshotStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("GetHogWatchTests-\(UUID().uuidString)", isDirectory: true),
            isSharedContainer: false
        )
    }

    @MainActor
    static func model(
        transport: any HTTPTransport,
        store: SharedSnapshotStore,
        headline: String? = nil,
        authenticate: @escaping @Sendable (String) async -> Bool = { _ in true },
        snapshotDidChange: @escaping () -> Void = {},
        mutationCoordinator: WatchCredentialMutationCoordinator = .init(),
        now: @escaping @Sendable () -> Date = { WatchFixtures.now }
    ) -> WatchModel {
        WatchModel(
            credential: credential,
            projectName: "Synthetic Analytics",
            headlineMetricID: headline,
            transport: transport,
            store: store,
            mutationCoordinator: mutationCoordinator,
            authenticate: authenticate,
            snapshotDidChange: snapshotDidChange,
            now: now
        )
    }

    /// A snapshot to pre-seed a store with, when a test is about what happens
    /// to data that was already there.
    static func snapshot(
        metrics: [SharedSnapshot.Metric] = [
            SharedSnapshot.Metric(
                id: "501", title: "Example signups", value: 3, unit: nil,
                previous: 2, sparkline: [1, 2, 3], dashboardID: 9001
            ),
        ],
        flags: [SharedSnapshot.Flag] = [],
        projectRegion: PostHogRegion? = .usCloud,
        capturedAt: Date = WatchFixtures.now
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001,
            projectName: "Synthetic Analytics",
            metrics: metrics,
            flags: flags,
            projectRegion: projectRegion,
            capturedAt: capturedAt
        )
    }
}
