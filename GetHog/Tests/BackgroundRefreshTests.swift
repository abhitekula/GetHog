import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// Always fails, to stand in for a wake that got a radio but no answer.
private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PostHogError.transport("offline")
    }
}

/// Keeps the authored demo payloads but removes the user's explicit dashboard
/// choice from the collection response. The detail route remains real, so the
/// snapshot publisher must both render the first dashboard and label that
/// choice as a fallback.
private struct UnpinnedDemoTransport: HTTPTransport {
    private let base = DemoTransport()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(request)
        let path = request.url?.path ?? ""
        guard path.hasSuffix("/dashboards/") || path.hasSuffix("/dashboards") else {
            return (data, response)
        }

        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var dashboards = try #require(root["results"] as? [[String: Any]])
        for index in dashboards.indices {
            dashboards[index]["pinned"] = false
        }
        root["results"] = dashboards
        return (try JSONSerialization.data(withJSONObject: root), response)
    }
}

/// The refresh a `BGAppRefreshTask` performs, invoked directly.
///
/// The cadence itself is pure and tested in `BackgroundRefreshPolicyTests`;
/// what is checked here is the part that touches the App Group — that a wake
/// spends requests only when it should, and never damages what the widgets are
/// already showing.
///
/// Serialized because every case reads and writes the one shared snapshot file.
@Suite("Background refresh", .serialized)
@MainActor
struct BackgroundRefreshTests {

    private func withStoredProjectID(
        _ projectID: Int,
        operation: () async throws -> Void
    ) async rethrows {
        let key = IntentDependencies.selectedProjectKey
        let shared = IntentDependencies.sharedDefaults
        let priorShared = shared?.object(forKey: key)
        let standard = UserDefaults.standard
        let priorStandard = standard.object(forKey: key)
        defer {
            if let priorShared {
                shared?.set(priorShared, forKey: key)
            } else {
                shared?.removeObject(forKey: key)
            }
            if let priorStandard {
                standard.set(priorStandard, forKey: key)
            } else {
                standard.removeObject(forKey: key)
            }
        }

        IntentDependencies.persistSelectedProject(projectID)
        try await operation()
    }

    @Test("the scheduler uses the GetHog task identifier")
    func taskIdentifier() {
        #expect(BackgroundRefresh.taskIdentifier == "app.gethog.refresh.snapshot")
    }

    /// Far enough ahead that the coalescing guard lets the refresh through.
    private var due: Date {
        Date().addingTimeInterval(BackgroundRefreshPolicy.minimumInterval + 60)
    }

    private func demoModel(snapshotStore: SharedSnapshotStore = .shared) -> AppModel {
        AppModel(
            store: InMemoryTokenStore(),
            transport: DemoTransport(),
            snapshotStore: snapshotStore
        )
    }

    private func makeSnapshotStore() throws -> (SharedSnapshotStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundRefreshTests-\(UUID().uuidString)", isDirectory: true)
        return (SharedSnapshotStore(directory: directory), directory)
    }

    private func snapshot(
        region: PostHogRegion?,
        authSessionID: UUID? = nil,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001,
            projectName: "Example App",
            metrics: [],
            flags: [],
            projectRegion: region,
            authSessionID: authSessionID,
            capturedAt: capturedAt
        )
    }

    @Test("does nothing without a stored credential")
    func noCredentialMeansNoRefresh() async {
        let model = AppModel(store: InMemoryTokenStore(), transport: OfflineTransport())

        #expect(await model.performBackgroundRefresh(now: due) == false)
    }

    @Test("a due wake publishes a snapshot the widgets can render")
    func dueWakePublishes() async throws {
        let model = demoModel()
        try await model.connect(key: "demo", region: .usCloud)

        #expect(await model.performBackgroundRefresh(now: due))

        let snapshot = try #require(SharedSnapshotStore.shared.loadOrNil())
        #expect(!snapshot.metrics.isEmpty)
        #expect(!snapshot.flags.isEmpty)
        // Reduced from tiles, so every metric has to carry something drawable.
        #expect(snapshot.metrics.allSatisfy { !$0.title.isEmpty })
        #expect(snapshot.metricSource == .pinnedDashboard)
        #expect(snapshot.projectRegion == .usCloud)
    }

    @Test("a dashboard fallback is published without claiming it was pinned")
    func dueWakeLabelsDashboardFallback() async throws {
        let (snapshots, directory) = try makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = UnpinnedDemoTransport()
        let probe = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: transport
        )
        let summaries: Page<DashboardSummary> = try await probe.send(
            PostHogAPI.dashboards(projectID: 1001, limit: 50)
        )
        let pinnedIDs = summaries.results.filter { $0.pinned }.map(\.id)
        #expect(pinnedIDs.isEmpty)

        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshots
        )
        try await model.connect(key: "demo", region: .usCloud)

        #expect(await model.performBackgroundRefresh(now: due))
        let snapshot = try #require(snapshots.loadOrNil())
        #expect(!snapshot.metrics.isEmpty)
        #expect(snapshot.metricSource == .deterministicFallback)
    }

    @Test("a cold background launch publishes the credential's durable epoch")
    func coldBackgroundLaunchPreservesAuthenticationEpoch() async throws {
        let (snapshots, directory) = try makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let epoch = UUID(uuidString: "018f9000-0000-7000-8000-000000000506")!
        try snapshots.write(snapshot(
            region: .usCloud,
            authSessionID: epoch,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let credential = StoredCredential(
            key: "synthetic-background-key",
            region: .usCloud,
            projectID: 1001,
            authSessionID: epoch
        )
        let model = AppModel(
            store: InMemoryTokenStore(credential: credential),
            transport: DemoTransport(),
            snapshotStore: snapshots
        )

        try await withStoredProjectID(1001) {
            #expect(await model.performBackgroundRefresh(now: due))

            let published = try #require(snapshots.loadOrNil())
            #expect(published.projectID == 1001)
            #expect(published.projectRegion == .usCloud)
            #expect(published.authSessionID == epoch)
        }
    }

    @Test("a recent cold snapshot is cleared when shared selection names another project")
    func recentColdSnapshotRejectsPriorSelectedProject() async throws {
        let (snapshots, directory) = try makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let epoch = UUID(uuidString: "018f9000-0000-7000-8000-000000000507")!
        try snapshots.write(snapshot(
            region: .usCloud,
            authSessionID: epoch,
            capturedAt: now.addingTimeInterval(-60)
        ))
        let model = AppModel(
            store: InMemoryTokenStore(credential: StoredCredential(
                key: "synthetic-recent-project-switch-key",
                region: .usCloud,
                authSessionID: epoch
            )),
            transport: OfflineTransport(),
            snapshotStore: snapshots
        )

        try await withStoredProjectID(1002) {
            #expect(await model.performBackgroundRefresh(now: now) == false)
            #expect(snapshots.loadOrNil() == nil)
        }
    }

    @Test("a due cold snapshot refreshes the shared selection instead of its prior project")
    func dueColdSnapshotRefreshesCurrentSelectedProject() async throws {
        let (snapshots, directory) = try makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let epoch = UUID(uuidString: "018f9000-0000-7000-8000-000000000508")!
        try snapshots.write(snapshot(
            region: .usCloud,
            authSessionID: epoch,
            capturedAt: now.addingTimeInterval(
                -BackgroundRefreshPolicy.minimumInterval - 60
            )
        ))
        let model = AppModel(
            store: InMemoryTokenStore(credential: StoredCredential(
                key: "synthetic-due-project-switch-key",
                region: .usCloud,
                authSessionID: epoch
            )),
            transport: DemoTransport(),
            snapshotStore: snapshots
        )

        try await withStoredProjectID(1002) {
            #expect(await model.performBackgroundRefresh(now: now))
            let published = try #require(snapshots.loadOrNil())
            #expect(published.projectID == 1002)
            #expect(published.projectName == "Project 1002")
            #expect(published.projectRegion == .usCloud)
            #expect(published.authSessionID == epoch)
            #expect(!published.metrics.isEmpty)
        }
    }

    @Test("a same-id snapshot from another region is cleared before an offline wake")
    func regionChangeFailsClosedBeforeRefresh() async throws {
        let (snapshots, directory) = try makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try snapshots.write(snapshot(region: .usCloud, capturedAt: Date()))

        let model = AppModel(
            store: InMemoryTokenStore(
                credential: StoredCredential(key: "synthetic-eu-key", region: .euCloud, projectID: 1001)
            ),
            transport: OfflineTransport(),
            snapshotStore: snapshots
        )

        #expect(await model.performBackgroundRefresh(now: Date()) == false)
        #expect(snapshots.loadOrNil() == nil)
    }

    @Test("sign out clears the shared snapshot")
    func signOutClearsSnapshot() throws {
        let (snapshots, directory) = try makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try snapshots.write(snapshot(region: .usCloud))
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: OfflineTransport(),
            snapshotStore: snapshots
        )

        model.signOut()

        #expect(snapshots.loadOrNil() == nil)
    }

    @Test("a wake landing just after a foreground sync spends nothing")
    func coalescesWithRecentForegroundSync() async throws {
        let model = demoModel()
        try await model.connect(key: "demo", region: .usCloud)
        let published = try #require(SharedSnapshotStore.shared.loadOrNil())

        // Reported as a success: there was nothing to do, and telling iOS the
        // wake failed would cost the app future ones.
        #expect(await model.performBackgroundRefresh(now: Date()))

        // A fetch would have rewritten the file with a new timestamp.
        #expect(SharedSnapshotStore.shared.loadOrNil()?.capturedAt == published.capturedAt)
    }

    @Test("a wake with no network leaves the widgets' data alone")
    func failedWakeDoesNotClobberTheSnapshot() async throws {
        let credentials = InMemoryTokenStore()
        let seeded = AppModel(
            store: credentials,
            transport: DemoTransport()
        )
        try await seeded.connect(key: "demo", region: .usCloud)
        let good = try #require(SharedSnapshotStore.shared.loadOrNil())
        #expect(!good.metrics.isEmpty)

        // A fresh process, as a background launch really is: a credential, a
        // snapshot on disk, and no session yet.
        let woken = AppModel(
            store: credentials,
            transport: OfflineTransport()
        )

        #expect(await woken.performBackgroundRefresh(now: due) == false)

        // Stale numbers with an honest age beat an empty widget claiming to be
        // current.
        #expect(SharedSnapshotStore.shared.loadOrNil() == good)
    }

    @Test("a published snapshot carries both health sections the widget renders")
    func publishesHealthSections() async throws {
        let model = demoModel()
        try await model.connect(key: "demo", region: .usCloud)

        let snapshot = try #require(SharedSnapshotStore.shared.loadOrNil())
        let ingestion = try #require(snapshot.ingestion)
        let quota = try #require(snapshot.quota)

        // Authored from the public response shapes so the widget renders the
        // same structural variants deterministically.
        #expect(ingestion.errorCount == 1)
        #expect(ingestion.topTitle == "Cannot merge already identified")
        #expect(ingestion.hasTrend)
        #expect(quota.topTitle == "Signals credits")
        #expect(quota.topState == .watch)
        #expect(snapshot.healthVerdict == .critical)
        // Written in the same pass, so neither section needs its own age stated.
        #expect(snapshot.isCarriedForward(ingestion.capturedAt) == false)
        #expect(snapshot.isCarriedForward(quota.capturedAt) == false)
    }

    @Test("a refresh carries quota forward instead of re-buying it every wake")
    func quotaIsCarriedForward() async throws {
        let model = demoModel()
        try await model.connect(key: "demo", region: .usCloud)
        let first = try #require(SharedSnapshotStore.shared.loadOrNil()?.quota)

        // A second publish, minutes later. Quota is a monthly allowance and this
        // is a request against somebody's production budget, so the wake must
        // reuse the digest it already has rather than pay for the same number.
        await model.publishWidgetSnapshot()
        let second = try #require(SharedSnapshotStore.shared.loadOrNil()?.quota)

        #expect(second.capturedAt == first.capturedAt)
    }
}
