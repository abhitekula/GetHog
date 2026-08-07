import Dispatch
import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch session listener")
struct WatchSessionListenerTests {

    /// A defaults suite per test, so one test's headline id can never be read
    /// as another's — and so nothing here touches the app's real preferences.
    private func defaults() throws -> UserDefaults {
        let name = "GetHogWatchTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    private let transfer = WatchKeyTransfer(
        key: "test-key-0001",
        region: .usCloud,
        organizationID: "org-synthetic-1001",
        organizationName: "Synthetic Labs",
        projectID: 1001,
        projectName: "Synthetic Analytics",
        headlineMetricID: "720101",
        watches: [
            MetricWatch(
                id: "example-watch-1", metricID: "720101",
                title: "Example signups", condition: .above(40)
            ),
        ]
    )

    @Test("applying a transfer stores the credential the wrist will authenticate with")
    func applyStoresTheCredential() throws {
        let store = InMemoryTokenStore()

        WatchSessionListener.apply(
            transfer,
            credentials: store,
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            notify: {}
        )

        let saved = try #require(try store.load())
        #expect(saved.key == "test-key-0001")
        #expect(saved.region == .usCloud)
        #expect(saved.projectID == 1001)
    }

    @Test("applying a transfer persists the thresholds and selected scope")
    func applyPersistsSelections() throws {
        let snapshots = WatchFixtures.tempStore()
        let defaults = try defaults()
        let credentials = InMemoryTokenStore()

        WatchSessionListener.apply(
            transfer,
            credentials: credentials,
            snapshots: snapshots,
            defaults: defaults,
            notify: {}
        )

        #expect(snapshots.metricWatches().count == 1)
        #expect(snapshots.metricWatches().first?.id == "example-watch-1")
        #expect(defaults.string(forKey: WatchSettings.organizationIDKey) == "org-synthetic-1001")
        #expect(defaults.string(forKey: WatchSettings.organizationNameKey) == "Synthetic Labs")
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == "Synthetic Analytics")
        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == "720101")
        #expect(defaults.bool(forKey: WatchSettings.watchesDegradedKey) == false)

        let handoff = WatchHandoff.current(
            credentials: credentials, defaults: defaults, snapshots: snapshots
        )
        #expect(handoff.organizationID == "org-synthetic-1001")
        #expect(handoff.organizationName == "Synthetic Labs")
    }

    @Test("a transfer with no headline clears the one that was there")
    func applyClearsAStaleHeadline() throws {
        let defaults = try defaults()
        defaults.set("720999", forKey: WatchSettings.headlineMetricKey)
        defaults.set("org-stale", forKey: WatchSettings.organizationIDKey)
        defaults.set("Stale Organization", forKey: WatchSettings.organizationNameKey)

        WatchSessionListener.apply(
            WatchKeyTransfer(key: "test-key-0001", region: .usCloud, projectID: 1001),
            credentials: InMemoryTokenStore(),
            snapshots: WatchFixtures.tempStore(),
            defaults: defaults,
            notify: {}
        )

        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == nil)
        #expect(defaults.string(forKey: WatchSettings.organizationIDKey) == nil)
        #expect(defaults.string(forKey: WatchSettings.organizationNameKey) == nil)
    }

    @Test("a failed threshold write restores the credential and publishes no partial selection")
    func failedSnapshotWriteRollsBack() throws {
        let original = StoredCredential(
            key: "test-key-original", region: .euCloud, projectID: 42
        )
        let credentials = InMemoryTokenStore(credential: original)
        let defaults = try defaults()
        defaults.set("org-original", forKey: WatchSettings.organizationIDKey)
        defaults.set("Original Organization", forKey: WatchSettings.organizationNameKey)
        defaults.set("Original Project", forKey: WatchSettings.projectNameKey)
        defaults.set("metric-original", forKey: WatchSettings.headlineMetricKey)
        defaults.set(true, forKey: WatchSettings.watchesDegradedKey)
        let notifications = ManualEntryNotifications()

        let applied = WatchSessionListener.apply(
            transfer,
            credentials: credentials,
            snapshots: RefusingMetricWatchWriter(),
            defaults: defaults,
            notify: { notifications.count += 1 }
        )

        #expect(!applied)
        #expect(try credentials.load() == original)
        #expect(defaults.string(forKey: WatchSettings.organizationIDKey) == "org-original")
        #expect(defaults.string(forKey: WatchSettings.organizationNameKey) == "Original Organization")
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == "Original Project")
        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == "metric-original")
        #expect(defaults.bool(forKey: WatchSettings.watchesDegradedKey))
        #expect(notifications.count == 0)
    }

    @Test("overlapping applies publish one whole scope at a time")
    func overlappingAppliesRemainCoherent() throws {
        let credentials = InMemoryTokenStore()
        let defaults = try defaults()
        let snapshots = PausingMetricWatchWriter()
        let results = ConcurrentApplyResults()

        let first = WatchKeyTransfer(
            key: "test-key-overlap-a",
            region: .usCloud,
            organizationID: "org-synthetic-a",
            organizationName: "Synthetic A",
            projectID: 1001,
            projectName: "Synthetic Project A",
            headlineMetricID: "metric-a",
            watches: [
                MetricWatch(
                    id: "watch-a", metricID: "metric-a",
                    title: "Synthetic metric A", condition: .above(10)
                ),
            ]
        )
        let second = WatchKeyTransfer(
            key: "test-key-overlap-b",
            region: .euCloud,
            organizationID: "org-synthetic-b",
            organizationName: "Synthetic B",
            projectID: 42,
            projectName: "Synthetic Project B",
            headlineMetricID: "metric-b",
            watches: [
                MetricWatch(
                    id: "watch-b", metricID: "metric-b",
                    title: "Synthetic metric B", condition: .below(20)
                ),
            ]
        )

        let applies = DispatchGroup()
        applies.enter()
        DispatchQueue.global().async {
            results.append(WatchSessionListener.apply(
                first, credentials: credentials, snapshots: snapshots,
                defaults: defaults, notify: {}
            ))
            applies.leave()
        }
        #expect(snapshots.firstWriteEntered.wait(timeout: .now() + 2) == .success)

        let secondFinished = DispatchSemaphore(value: 0)
        applies.enter()
        DispatchQueue.global().async {
            results.append(WatchSessionListener.apply(
                second, credentials: credentials, snapshots: snapshots,
                defaults: defaults, notify: {}
            ))
            secondFinished.signal()
            applies.leave()
        }

        // Without one transaction lock, B completes while A is paused and A
        // then overwrites only the snapshot/default half. With serialization,
        // B cannot finish until A is released and commits wholly after it.
        let secondInterleaved = secondFinished.wait(timeout: .now() + 1) == .success
        snapshots.releaseFirstWrite.signal()
        #expect(applies.wait(timeout: .now() + 2) == .success)

        #expect(!secondInterleaved)
        #expect(results.values == [true, true])
        #expect(try credentials.load() == StoredCredential(
            key: "test-key-overlap-b", region: .euCloud, projectID: 42
        ))
        #expect(snapshots.watches.map(\.id) == ["watch-b"])
        #expect(defaults.string(forKey: WatchSettings.organizationIDKey) == "org-synthetic-b")
        #expect(defaults.string(forKey: WatchSettings.organizationNameKey) == "Synthetic B")
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == "Synthetic Project B")
        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == "metric-b")
    }

    @Test("a key that ingestion refuses leaves every store untouched")
    func refusedIngestionWritesNothing() throws {
        let snapshots = WatchFixtures.tempStore()
        let defaults = try defaults()
        let store = InMemoryTokenStore()

        WatchSessionListener.apply(
            WatchKeyTransfer(
                key: "   ", region: .usCloud, projectID: 1001,
                projectName: "Synthetic Analytics"
            ),
            credentials: store,
            snapshots: snapshots,
            defaults: defaults,
            notify: {}
        )

        #expect(try store.load() == nil)
        #expect(snapshots.metricWatches().isEmpty)
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == nil)
    }

    @Test("a payload that is not a transfer is dropped before anything is written")
    func malformedPayloadIsIgnored() {
        // The decode half, so the assertion is a value rather than the absence
        // of a side effect: a payload under the wrong key, one carrying bytes
        // that are not JSON, and one whose value is not `Data` at all.
        #expect(WatchSessionListener.transfer(from: ["some.other.key": Data("{}".utf8)]) == nil)
        #expect(
            WatchSessionListener.transfer(
                from: [WatchKeyTransfer.userInfoKey: Data("not json".utf8)]
            ) == nil
        )
        #expect(
            WatchSessionListener.transfer(
                from: [WatchKeyTransfer.userInfoKey: "a string, not Data"]
            ) == nil
        )
    }

    @Test("a complete hand-off announces itself; a refused one does not")
    func onlyACompleteHandoffAnnounces() throws {
        final class Announcements: @unchecked Sendable {
            var count = 0
        }
        let announced = Announcements()

        WatchSessionListener.apply(
            transfer,
            credentials: InMemoryTokenStore(),
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            notify: { announced.count += 1 }
        )
        #expect(announced.count == 1)

        // An empty key is refused before the store is touched, so nothing is
        // announced either — a running model told to refetch would go looking
        // for a credential that was never saved.
        WatchSessionListener.apply(
            WatchKeyTransfer(key: " ", region: .usCloud, projectID: 1001),
            credentials: InMemoryTokenStore(),
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            notify: { announced.count += 1 }
        )
        #expect(announced.count == 1)
    }

    /// The whole `watchesDegraded == true` wire, one hop at a time.
    ///
    /// Every hop is a place the flag could be dropped silently, and the
    /// consequence of dropping it is the one thing this flag exists to
    /// prevent: an empty Health list that reads as a clean bill of health when
    /// the user's thresholds were in fact lost.
    @Test("a watch list this build cannot read travels from the wire to the page")
    func degradedWatchListReachesTheView() throws {
        // A `Condition` case this build has no spelling for — what a newer
        // phone would send. Everything else in the payload is readable.
        let payload = Data(#"""
            {"version":1,"key":"test-key-0001","region":{"usCloud":{}},
             "projectID":1001,"projectName":"Synthetic Analytics",
             "headlineMetricID":"720101",
             "watches":[{"id":"example-watch-1","metricID":"720101",
               "title":"Example signups","isEnabled":true,
               "condition":{"crossesSideways":{"_0":40}}}]}
            """#.utf8)

        // 1. The wire.
        let transfer = try #require(
            WatchSessionListener.transfer(from: [WatchKeyTransfer.userInfoKey: payload])
        )
        #expect(transfer.watchesDegraded)
        #expect(transfer.watches.isEmpty)
        // The key still landed, which is the point of degrading rather than
        // refusing the whole payload.
        #expect(transfer.key == "test-key-0001")

        // 2. The stores.
        let credentials = InMemoryTokenStore()
        let snapshots = WatchFixtures.tempStore()
        let defaults = try defaults()
        WatchSessionListener.apply(
            transfer, credentials: credentials, snapshots: snapshots,
            defaults: defaults, notify: {}
        )
        #expect(defaults.bool(forKey: WatchSettings.watchesDegradedKey))

        // 3. The re-read a launch or an adoption performs.
        let handoff = WatchHandoff.current(
            credentials: credentials, defaults: defaults, snapshots: snapshots
        )
        #expect(handoff.watchesDegraded)
        #expect(handoff.watches.isEmpty)

        // 4. The page's own choice of sentence.
        let copy = WatchHealthCopy.emptyWatches(degraded: handoff.watchesDegraded)
        #expect(copy != WatchHealthCopy.emptyWatches(degraded: false))
        guard case .degraded(let headline, _) = copy else {
            Issue.record("a degraded hand-off must not render the ordinary empty state")
            return
        }
        #expect(headline == "Thresholds didn't transfer")
    }

    @Test("a readable watch list is not reported as degraded")
    func readableWatchListIsNotDegraded() throws {
        let credentials = InMemoryTokenStore()
        let snapshots = WatchFixtures.tempStore()
        let defaults = try defaults()

        WatchSessionListener.apply(
            transfer, credentials: credentials, snapshots: snapshots,
            defaults: defaults, notify: {}
        )

        let handoff = WatchHandoff.current(
            credentials: credentials, defaults: defaults, snapshots: snapshots
        )
        #expect(handoff.watchesDegraded == false)
        #expect(handoff.watches.count == 1)
        if case .none = WatchHealthCopy.emptyWatches(degraded: handoff.watchesDegraded) {} else {
            Issue.record("an ordinary hand-off must render the ordinary empty state")
        }
    }

    @Test("the round trip the phone will send survives the kit's codec")
    func transferRoundTrips() throws {
        let decoded = try WatchKeyTransfer.decode(try transfer.encoded())
        #expect(decoded == transfer)
        #expect(WatchKeyTransfer.userInfoKey == "app.gethog.watchKeyTransfer")
    }

    @Test("manual key entry uses the same transfer ingestion as the phone")
    func manualKeyEntryUsesTransferIngestion() throws {
        let credentials = InMemoryTokenStore()
        let notifications = ManualEntryNotifications()

        let saved = WatchManualKeyEntry.save(
            key: " test-key-0001 ",
            region: .euCloud,
            credentials: credentials,
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            notify: { notifications.count += 1 }
        )

        #expect(saved)
        let credential = try #require(try credentials.load())
        #expect(credential.key == "test-key-0001")
        #expect(credential.region == .euCloud)
        #expect(credential.projectID == nil)
        #expect(notifications.count == 1)
    }

    @Test("blank manual key entry leaves the existing credential untouched")
    func blankManualKeyEntryIsRefused() throws {
        let credentials = InMemoryTokenStore(
            credential: StoredCredential(key: "test-key-0001", region: .usCloud, projectID: 1001)
        )
        let notifications = ManualEntryNotifications()

        let saved = WatchManualKeyEntry.save(
            key: "   ",
            region: .usCloud,
            credentials: credentials,
            snapshots: WatchFixtures.tempStore(),
            defaults: try defaults(),
            notify: { notifications.count += 1 }
        )

        #expect(!saved)
        #expect(try credentials.load()?.key == "test-key-0001")
        #expect(try credentials.load()?.projectID == 1001)
        #expect(notifications.count == 0)
    }

    @Test("manual region selection resolves every supported endpoint")
    func manualRegionSelectionResolvesEverySupportedEndpoint() throws {
        #expect(WatchManualRegion.usCloud.resolve(selfHostedURL: "") == PostHogRegion.usCloud)
        #expect(WatchManualRegion.euCloud.resolve(selfHostedURL: "") == PostHogRegion.euCloud)

        let selfHostedURL = try #require(URL(string: "https://posthog.example.com"))
        #expect(
            WatchManualRegion.selfHosted.resolve(
                selfHostedURL: "https://posthog.example.com"
            ) == PostHogRegion.selfHosted(selfHostedURL)
        )
        #expect(WatchManualRegion.selfHosted.resolve(selfHostedURL: "ftp://posthog.example.com") == nil)
    }
}

private final class ManualEntryNotifications: @unchecked Sendable {
    var count = 0
}

private struct RefusingMetricWatchWriter: MetricWatchWriting {
    struct Refused: Error {}

    func writeMetricWatches(_ watches: [MetricWatch]) throws {
        throw Refused()
    }
}

private final class PausingMetricWatchWriter: MetricWatchWriting, @unchecked Sendable {
    let firstWriteEntered = DispatchSemaphore(value: 0)
    let releaseFirstWrite = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var writeCount = 0
    private var storedWatches: [MetricWatch] = []

    var watches: [MetricWatch] {
        lock.withLock { storedWatches }
    }

    func writeMetricWatches(_ watches: [MetricWatch]) throws {
        let isFirst = lock.withLock {
            writeCount += 1
            return writeCount == 1
        }
        if isFirst {
            firstWriteEntered.signal()
            releaseFirstWrite.wait()
        }
        lock.withLock { storedWatches = watches }
    }
}

private final class ConcurrentApplyResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Bool] = []

    var values: [Bool] {
        lock.withLock { storedValues }
    }

    func append(_ value: Bool) {
        lock.withLock { storedValues.append(value) }
    }
}
