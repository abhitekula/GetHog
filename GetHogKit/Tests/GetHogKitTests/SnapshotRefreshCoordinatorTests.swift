import Foundation
import Testing

@testable import GetHogKit

@Suite("Snapshot refresh coordinator", .serialized)
struct SnapshotRefreshCoordinatorTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let authSessionID = UUID(uuidString: "018f9000-0000-7000-8000-000000000600")!

    private func makeStore() throws -> (SharedSnapshotStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotRefreshCoordinatorTests-synthetic", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        return (SharedSnapshotStore(directory: directory), directory)
    }

    private func scope(
        projectID: Int = 1001,
        region: PostHogRegion = .usCloud
    ) -> SnapshotRefreshScope {
        SnapshotRefreshScope(
            projectID: projectID,
            projectName: "Example App",
            region: region,
            authSessionID: authSessionID
        )
    }

    private func snapshot(
        projectID: Int = 1001,
        region: PostHogRegion = .usCloud,
        capturedAt: Date
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: projectID,
            projectName: "Example App",
            metrics: [
                .init(
                    id: "old",
                    title: "Old value",
                    value: 1,
                    unit: nil,
                    previous: nil,
                    sparkline: [],
                    dashboardID: 1
                )
            ],
            flags: [],
            projectRegion: region,
            authSessionID: authSessionID,
            capturedAt: capturedAt
        )
    }

    private func client(transport: any HTTPTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic-key", region: .usCloud),
            transport: transport,
            governor: RateLimitGovernor(jitter: { _ in 0 })
        )
    }

    @Test("manual refresh fetches even when the existing snapshot is one second old")
    func manualRefreshBypassesFreshness() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.write(snapshot(capturedAt: now.addingTimeInterval(-1)))
        let transport = SnapshotFixtureTransport()
        let coordinator = SnapshotRefreshCoordinator(store: store)

        let result = await coordinator.refresh(
            trigger: .manualWidget,
            client: client(transport: transport),
            scope: scope(),
            now: now,
            quickToggleAllowed: { $0 == 710301 },
            isAuthorized: { true }
        )

        guard case .refreshed(let refreshed, let pinned) = result else {
            Issue.record("Expected a refreshed snapshot, got \(result); paths: \(await transport.paths)")
            return
        }
        #expect(refreshed.capturedAt == now)
        #expect(refreshed.metrics.isEmpty == false)
        #expect(refreshed.flags.first(where: { $0.id == 710301 })?.quickToggleAllowed == true)
        #expect(pinned?.id == 725101)
        #expect(await transport.paths == [
            "/api/projects/1001/dashboards",
            "/api/projects/1001/dashboards/725101",
            "/api/projects/1001/feature_flags",
            "/api/projects/1001/ingestion_warnings_v2",
            "/api/projects/1001/quota_limits",
        ])
    }

    @Test("automatic refresh returns a fresh snapshot without contacting PostHog")
    func automaticRefreshUsesFreshSnapshot() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = snapshot(capturedAt: now.addingTimeInterval(-60))
        try store.write(existing)
        let transport = SnapshotFixtureTransport()
        let coordinator = SnapshotRefreshCoordinator(store: store)

        let result = await coordinator.refresh(
            trigger: .automaticWidget,
            client: client(transport: transport),
            scope: scope(),
            now: now,
            quickToggleAllowed: { _ in false },
            isAuthorized: { true }
        )

        #expect(result == .current(existing))
        #expect(await transport.paths.isEmpty)
    }

    @Test("a foreground caller waits for the matching refresh already in flight")
    func foregroundRefreshCoalescesAfterPublication() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = SnapshotRefreshCoordinator(store: store)
        let lease = try #require(coordinator.leases.acquire(
            scope: scope(), trigger: .foreground, now: now
        ))
        let refreshed = snapshot(capturedAt: now)
        let publication = Task {
            try await Task.sleep(for: .milliseconds(50))
            try store.write(refreshed)
            coordinator.leases.release(token: lease.token)
        }
        let transport = SnapshotFixtureTransport()

        let result = await coordinator.refresh(
            trigger: .foreground,
            client: client(transport: transport),
            scope: scope(),
            now: now,
            quickToggleAllowed: { _ in false },
            isAuthorized: { true }
        )
        try await publication.value

        #expect(result == .coalesced(refreshed))
        #expect(await transport.paths.isEmpty)
    }

    @Test("a failed refresh preserves the last good snapshot and timestamp")
    func failurePreservesLastGoodSnapshot() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = snapshot(capturedAt: now.addingTimeInterval(-3_600))
        try store.write(existing)
        let coordinator = SnapshotRefreshCoordinator(store: store)

        let result = await coordinator.refresh(
            trigger: .manualWidget,
            client: client(transport: OfflineSnapshotTransport()),
            scope: scope(),
            now: now,
            quickToggleAllowed: { _ in false },
            isAuthorized: { true }
        )

        #expect(result == .failed(.offline, retained: existing))
        #expect(store.loadOrNil() == existing)
        #expect(store.snapshotRefreshStatus() == SnapshotRefreshStatus(
            attemptedAt: now,
            failure: .offline
        ))
    }

    @Test("a successful refresh clears the previous failure state")
    func successClearsFailureState() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.write(snapshot(capturedAt: now.addingTimeInterval(-3_600)))
        try store.writeSnapshotRefreshStatus(SnapshotRefreshStatus(
            attemptedAt: now.addingTimeInterval(-60),
            failure: .offline
        ))
        let coordinator = SnapshotRefreshCoordinator(store: store)

        _ = await coordinator.refresh(
            trigger: .manualWidget,
            client: client(transport: SnapshotFixtureTransport()),
            scope: scope(),
            now: now,
            quickToggleAllowed: { _ in false },
            isAuthorized: { true }
        )

        #expect(store.snapshotRefreshStatus() == SnapshotRefreshStatus(
            attemptedAt: now,
            failure: nil
        ))
    }

    @Test("authority lost after a request prevents snapshot publication")
    func lostAuthorityPreventsPublication() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = snapshot(capturedAt: now.addingTimeInterval(-3_600))
        try store.write(existing)
        let authority = SnapshotAuthoritySequence([true, false])
        let transport = SnapshotFixtureTransport()
        let coordinator = SnapshotRefreshCoordinator(store: store)

        let result = await coordinator.refresh(
            trigger: .manualWidget,
            client: client(transport: transport),
            scope: scope(),
            now: now,
            quickToggleAllowed: { _ in false },
            isAuthorized: { await authority.next() }
        )

        #expect(result == .superseded)
        #expect(store.loadOrNil() == existing)
        #expect(await transport.paths.count == 1)
    }

    @Test("a previous snapshot from another region is cleared even when replacement fetch fails")
    func wrongScopeSnapshotIsNotRetained() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.write(snapshot(region: .euCloud, capturedAt: now.addingTimeInterval(-3_600)))
        let coordinator = SnapshotRefreshCoordinator(store: store)

        _ = await coordinator.refresh(
            trigger: .manualWidget,
            client: client(transport: OfflineSnapshotTransport()),
            scope: scope(region: .usCloud),
            now: now,
            quickToggleAllowed: { _ in false },
            isAuthorized: { true }
        )

        #expect(store.loadOrNil() == nil)
    }
}

private actor SnapshotFixtureTransport: HTTPTransport {
    private(set) var paths: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        paths.append(path)
        let fixture: String
        switch path {
        case "/api/projects/1001/dashboards": fixture = "dashboards_list.json"
        case "/api/projects/1001/dashboards/725101": fixture = "dashboard_detail_raw.json"
        case "/api/projects/1001/feature_flags": fixture = "feature_flags.json"
        case "/api/projects/1001/ingestion_warnings_v2": fixture = "ingestion_warnings_v2.json"
        case "/api/projects/1001/quota_limits": fixture = "quota_limits.json"
        default: throw PostHogError.transport("Unexpected synthetic path: \(path)")
        }
        return (
            try Fixture.data(fixture),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private struct OfflineSnapshotTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PostHogError.network(code: -1009, description: "The Internet connection appears to be offline.")
    }
}

private actor SnapshotAuthoritySequence {
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        values.isEmpty ? false : values.removeFirst()
    }
}
