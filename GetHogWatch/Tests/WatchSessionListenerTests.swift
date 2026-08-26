import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch session listener")
struct WatchSessionListenerTests {

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "GetHogWatchTests-\(UUID().uuidString)"))
    }

    private let transfer = WatchKeyTransfer(
        key: "test-key-0001",
        region: .usCloud,
        organizationID: "org-synthetic-1001",
        organizationName: "Synthetic Labs",
        projectID: 1001,
        projectName: "Synthetic Analytics",
        headlineMetricID: "720101"
    )

    @Test("applying a transfer stores the credential and selected scope")
    func applyStoresCredentialAndSelection() throws {
        let credentials = InMemoryTokenStore()
        let snapshots = WatchFixtures.tempStore()
        let defaults = try defaults()
        let coordinator = WatchCredentialMutationCoordinator()

        let applied = WatchSessionListener.apply(
            transfer,
            credentials: credentials,
            snapshots: snapshots,
            defaults: defaults,
            mutationCoordinator: coordinator,
            notify: {}
        )
        #expect(applied)

        let saved = try #require(try credentials.load())
        #expect(saved.key == "test-key-0001")
        #expect(saved.region == .usCloud)
        #expect(saved.projectID == 1001)
        #expect(defaults.string(forKey: WatchSettings.organizationIDKey) == "org-synthetic-1001")
        #expect(defaults.string(forKey: WatchSettings.organizationNameKey) == "Synthetic Labs")
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == "Synthetic Analytics")
        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == "720101")

        let handoff = WatchHandoff.current(
            credentials: credentials,
            defaults: defaults,
            snapshots: snapshots,
            mutationCoordinator: coordinator
        )
        #expect(handoff.organizationID == "org-synthetic-1001")
        #expect(handoff.projectName == "Synthetic Analytics")
    }

    @Test("a transfer with no optional scope clears stale selection")
    func applyClearsStaleSelection() throws {
        let defaults = try defaults()
        defaults.set("stale-org", forKey: WatchSettings.organizationIDKey)
        defaults.set("Stale Project", forKey: WatchSettings.projectNameKey)
        defaults.set("720999", forKey: WatchSettings.headlineMetricKey)

        let applied = WatchSessionListener.apply(
            WatchKeyTransfer(key: "test-key-0001", region: .usCloud, projectID: 1001),
            credentials: InMemoryTokenStore(),
            snapshots: WatchFixtures.tempStore(),
            defaults: defaults,
            mutationCoordinator: .init(),
            notify: {}
        )
        #expect(applied)

        #expect(defaults.string(forKey: WatchSettings.organizationIDKey) == nil)
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == nil)
        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == nil)
    }

    @Test("a changed project clears snapshot and activity before announcement")
    func changedScopeClearsProjectData() throws {
        let snapshots = WatchFixtures.tempStore()
        try snapshots.write(WatchFixtures.snapshot())
        try WatchActivity.write(WatchWidgetSample.activity, to: snapshots)
        let credentials = InMemoryTokenStore(
            credential: StoredCredential(key: "test-key-old", region: .usCloud, projectID: 42)
        )
        final class Events: @unchecked Sendable {
            var reloads = 0
            var announcements = 0
        }
        let events = Events()

        #expect(WatchSessionListener.apply(
            transfer,
            credentials: credentials,
            snapshots: snapshots,
            defaults: try defaults(),
            mutationCoordinator: .init(),
            projectDataDidChange: { events.reloads += 1 },
            notify: { events.announcements += 1 }
        ))

        #expect(snapshots.loadOrNil() == nil)
        #expect(WatchActivity.read(from: snapshots) == nil)
        #expect(events.reloads == 1)
        #expect(events.announcements == 1)
    }

    @Test("a same-project key rotation preserves project data")
    func sameScopePreservesProjectData() throws {
        let snapshots = WatchFixtures.tempStore()
        let snapshot = WatchFixtures.snapshot()
        try snapshots.write(snapshot)
        let credentials = InMemoryTokenStore(
            credential: StoredCredential(key: "test-key-old", region: .usCloud, projectID: 1001)
        )
        final class Events: @unchecked Sendable { var reloads = 0 }
        let events = Events()

        #expect(WatchSessionListener.apply(
            transfer,
            credentials: credentials,
            snapshots: snapshots,
            defaults: try defaults(),
            mutationCoordinator: .init(),
            projectDataDidChange: { events.reloads += 1 },
            notify: {}
        ))

        #expect(snapshots.loadOrNil() == snapshot)
        #expect(events.reloads == 0)
    }

    @Test("a project-data cleanup failure refuses the incoming credential")
    func cleanupFailureRefusesTransfer() throws {
        let original = StoredCredential(key: "test-key-old", region: .euCloud, projectID: 42)
        let credentials = InMemoryTokenStore(credential: original)
        final class Events: @unchecked Sendable {
            var reloads = 0
            var announcements = 0
        }
        let events = Events()

        #expect(!WatchSessionListener.apply(
            transfer,
            credentials: credentials,
            snapshots: RefusingProjectDataClearer(),
            defaults: try defaults(),
            mutationCoordinator: .init(),
            projectDataDidChange: { events.reloads += 1 },
            notify: { events.announcements += 1 }
        ))

        #expect(try credentials.load() == original)
        #expect(events.reloads == 1)
        #expect(events.announcements == 0)
    }

    @Test("an empty key leaves every store untouched")
    func emptyKeyIsRefused() throws {
        let original = StoredCredential(key: "test-key-old", region: .usCloud, projectID: 1001)
        let credentials = InMemoryTokenStore(credential: original)
        let snapshots = WatchFixtures.tempStore()
        let snapshot = WatchFixtures.snapshot()
        try snapshots.write(snapshot)

        #expect(!WatchSessionListener.apply(
            WatchKeyTransfer(key: "  ", region: .usCloud, projectID: 1001),
            credentials: credentials,
            snapshots: snapshots,
            defaults: try defaults(),
            mutationCoordinator: .init(),
            notify: {}
        ))

        #expect(try credentials.load() == original)
        #expect(snapshots.loadOrNil() == snapshot)
    }

    @Test("a malformed payload is dropped before mutation")
    func malformedPayloadIsIgnored() {
        #expect(WatchSessionListener.transfer(from: ["some.other.key": Data("{}".utf8)]) == nil)
        #expect(WatchSessionListener.transfer(
            from: [WatchKeyTransfer.userInfoKey: Data("not json".utf8)]
        ) == nil)
        #expect(WatchSessionListener.transfer(
            from: [WatchKeyTransfer.userInfoKey: "not data"]
        ) == nil)
    }

    @Test("a complete handoff announces itself; a refusal does not")
    func onlyCompleteHandoffAnnounces() throws {
        final class Announcements: @unchecked Sendable { var count = 0 }
        let announcements = Announcements()
        let coordinator = WatchCredentialMutationCoordinator()

        #expect(WatchSessionListener.apply(
            transfer,
            credentials: InMemoryTokenStore(),
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            mutationCoordinator: coordinator,
            notify: { announcements.count += 1 }
        ))
        #expect(!WatchSessionListener.apply(
            WatchKeyTransfer(key: " ", region: .usCloud, projectID: 1001),
            credentials: InMemoryTokenStore(),
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            mutationCoordinator: coordinator,
            notify: { announcements.count += 1 }
        ))

        #expect(announcements.count == 1)
        #expect(coordinator.currentRevision == 1)
        #expect(!coordinator.hasPendingMutation)
    }

    @Test("the phone payload round-trips through the kit codec")
    func transferRoundTrips() throws {
        #expect(try WatchKeyTransfer.decode(transfer.encoded()) == transfer)
        #expect(WatchKeyTransfer.userInfoKey == "app.gethog.watchKeyTransfer")
    }

    @Test("manual key entry uses transfer ingestion")
    func manualKeyEntryUsesTransferIngestion() throws {
        let credentials = InMemoryTokenStore()
        final class Announcements: @unchecked Sendable { var count = 0 }
        let announcements = Announcements()

        let saved = WatchManualKeyEntry.save(
            key: " test-key-0001 ",
            region: .euCloud,
            credentials: credentials,
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            mutationCoordinator: .init(),
            notify: { announcements.count += 1 }
        )

        #expect(saved)
        #expect(try credentials.load()?.key == "test-key-0001")
        #expect(try credentials.load()?.region == .euCloud)
        #expect(announcements.count == 1)
    }

    @Test("manual region selection resolves every supported endpoint")
    func manualRegionSelectionResolvesEverySupportedEndpoint() throws {
        #expect(WatchManualRegion.usCloud.resolve(selfHostedURL: "") == .usCloud)
        #expect(WatchManualRegion.euCloud.resolve(selfHostedURL: "") == .euCloud)
        let url = try #require(URL(string: "https://posthog.example.com"))
        #expect(WatchManualRegion.selfHosted.resolve(
            selfHostedURL: "https://posthog.example.com"
        ) == .selfHosted(url))
        #expect(WatchManualRegion.selfHosted.resolve(
            selfHostedURL: "ftp://posthog.example.com"
        ) == nil)
    }
}

private struct RefusingProjectDataClearer: ProjectScopedDataClearing {
    struct Refusal: Error {}
    func clearProjectScopedData() throws { throw Refusal() }
}
