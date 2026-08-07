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

    @Test("applying a transfer persists the thresholds and the two non-secrets")
    func applyPersistsSelections() throws {
        let snapshots = WatchFixtures.tempStore()
        let defaults = try defaults()

        WatchSessionListener.apply(
            transfer,
            credentials: InMemoryTokenStore(),
            snapshots: snapshots,
            defaults: defaults,
            notify: {}
        )

        #expect(snapshots.metricWatches().count == 1)
        #expect(snapshots.metricWatches().first?.id == "example-watch-1")
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == "Synthetic Analytics")
        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == "720101")
        #expect(defaults.bool(forKey: WatchSettings.watchesDegradedKey) == false)
    }

    @Test("a transfer with no headline clears the one that was there")
    func applyClearsAStaleHeadline() throws {
        let defaults = try defaults()
        defaults.set("720999", forKey: WatchSettings.headlineMetricKey)

        WatchSessionListener.apply(
            WatchKeyTransfer(key: "test-key-0001", region: .usCloud, projectID: 1001),
            credentials: InMemoryTokenStore(),
            snapshots: WatchFixtures.tempStore(),
            defaults: defaults,
            notify: {}
        )

        #expect(defaults.string(forKey: WatchSettings.headlineMetricKey) == nil)
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
}
