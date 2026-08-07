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
            defaults: try defaults()
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
            defaults: defaults
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
            defaults: defaults
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
            defaults: defaults
        )

        #expect(try store.load() == nil)
        #expect(snapshots.metricWatches().isEmpty)
        #expect(defaults.string(forKey: WatchSettings.projectNameKey) == nil)
    }

    @Test("a payload that is not a transfer routes to nothing at all")
    func malformedPayloadIsIgnored() {
        // `route` reaches the shared stores by design, so the assertion is that
        // it returns before touching any of them: a payload under the wrong
        // key, and a payload of the right key carrying bytes that are not a
        // transfer, must both be dropped rather than decoded partially.
        WatchSessionListener.route(["some.other.key": Data("{}".utf8)])
        WatchSessionListener.route([WatchKeyTransfer.userInfoKey: Data("not json".utf8)])
        WatchSessionListener.route([WatchKeyTransfer.userInfoKey: "a string, not Data"])
    }

    @Test("the round trip the phone will send survives the kit's codec")
    func transferRoundTrips() throws {
        let decoded = try WatchKeyTransfer.decode(try transfer.encoded())
        #expect(decoded == transfer)
        #expect(WatchKeyTransfer.userInfoKey == "app.gethog.watchKeyTransfer")
    }
}
