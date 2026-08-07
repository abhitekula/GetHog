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
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001,
            projectName: "Example App",
            metrics: [],
            flags: [],
            projectRegion: region,
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
        #expect(snapshot.projectRegion == .usCloud)
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
        let seeded = demoModel()
        try await seeded.connect(key: "demo", region: .usCloud)
        let good = try #require(SharedSnapshotStore.shared.loadOrNil())
        #expect(!good.metrics.isEmpty)

        // A fresh process, as a background launch really is: a credential, a
        // snapshot on disk, and no session yet.
        let woken = AppModel(
            store: InMemoryTokenStore(credential: StoredCredential(key: "demo", region: .usCloud)),
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
