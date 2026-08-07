import Foundation
import Testing

@testable import GetHogKit

/// The envelope that carries a personal key from the phone to the wrist.
///
/// Two binaries on two devices, updated independently through two App Store
/// reviews, so every test here is about surviving disagreement: a field one end
/// has never heard of, a version the other end predates, an optional that means
/// "not chosen" rather than "chose nothing".
@Suite("Watch key transfer")
struct WatchKeyTransferTests {

    /// Shaped like nothing real. The fixture privacy scanner rejects anything
    /// wearing a `phx_` prefix, and a test that needed an exemption would be a
    /// test written wrong.
    private static let key = "test-key-0001"

    private static func watches() -> [MetricWatch] {
        [
            MetricWatch(
                id: "watch-a",
                metricID: "42",
                title: "Synthetic signups",
                condition: .above(1_000)
            ),
            MetricWatch(
                id: "watch-b",
                metricID: "43",
                title: "Synthetic errors",
                condition: .changesByPercent(25),
                isEnabled: false
            ),
        ]
    }

    private static func full(region: PostHogRegion) -> WatchKeyTransfer {
        WatchKeyTransfer(
            key: key,
            region: region,
            projectID: 42,
            projectName: "Synthetic Analytics",
            headlineMetricID: "42",
            watches: watches()
        )
    }

    @Test("round-trips every field through the codec")
    func roundTrip() throws {
        for region in [
            PostHogRegion.usCloud,
            .euCloud,
            .selfHosted(URL(string: "https://analytics.example.com")!),
        ] {
            let sent = Self.full(region: region)
            let received = try WatchKeyTransfer.decode(sent.encoded())

            #expect(received == sent)
            #expect(received.version == WatchKeyTransfer.currentVersion)
            #expect(received.key == Self.key)
            #expect(received.region == region)
            #expect(received.projectID == 42)
            #expect(received.projectName == "Synthetic Analytics")
            #expect(received.headlineMetricID == "42")
            #expect(received.watches == Self.watches())
        }
    }

    @Test("optional selections survive as nil, not as defaults")
    func optionalsStayAbsent() throws {
        // nil is "the user has not chosen", which the receiver must not invent
        // a value for — a project id defaulted to the first project would point
        // the wrist at somebody else's numbers.
        let sent = WatchKeyTransfer(key: Self.key, region: .usCloud)
        let received = try WatchKeyTransfer.decode(sent.encoded())

        #expect(received.projectID == nil)
        #expect(received.projectName == nil)
        #expect(received.headlineMetricID == nil)
        #expect(received.watches.isEmpty)
    }

    @Test("decoding tolerates fields it has never heard of")
    func toleratesUnknownFields() throws {
        let json = """
            {
              "version": 1,
              "key": "\(Self.key)",
              "region": {"usCloud": {}},
              "projectID": 42,
              "futureField": {"nested": true}
            }
            """
        let received = try WatchKeyTransfer.decode(Data(json.utf8))

        #expect(received.key == Self.key)
        #expect(received.region == .usCloud)
        #expect(received.projectID == 42)
        #expect(received.watches.isEmpty)
    }

    @Test("a newer version still yields its known fields")
    func newerVersionDecodes() throws {
        // The receiver may want to say "sent by a newer phone", so the number
        // survives rather than being clamped to what this build understands.
        let json = """
            {"version": 2, "key": "\(Self.key)", "region": {"euCloud": {}}}
            """
        let received = try WatchKeyTransfer.decode(Data(json.utf8))

        #expect(received.version == 2)
        #expect(received.region == .euCloud)
    }

    @Test("a missing version reads as the first one")
    func missingVersionIsOne() throws {
        let json = """
            {"key": "\(Self.key)", "region": {"usCloud": {}}}
            """
        #expect(try WatchKeyTransfer.decode(Data(json.utf8)).version == 1)
    }

    @Test("a version below the floor is refused")
    func versionBelowFloorIsRefused() {
        let json = """
            {"version": 0, "key": "\(Self.key)", "region": {"usCloud": {}}}
            """
        #expect(throws: WatchKeyTransfer.Failure.unsupportedVersion(0)) {
            try WatchKeyTransfer.decode(Data(json.utf8))
        }
    }

    @Test("a payload with no key cannot decode at all")
    func keyIsRequired() {
        let json = #"{"version": 1, "region": {"usCloud": {}}}"#
        #expect(throws: (any Error).self) {
            try WatchKeyTransfer.decode(Data(json.utf8))
        }
    }

    @Test("ingestion writes the credential through the store seam and returns the selections")
    func ingestWritesCredential() throws {
        let store = InMemoryTokenStore()
        let selection = try Self.full(region: .euCloud).ingest(into: store)

        let stored = try #require(try store.load())
        #expect(stored == StoredCredential(key: Self.key, region: .euCloud, projectID: 42))

        // Everything the caller is handed back, and no key anywhere in it —
        // the type has no such property by construction.
        #expect(selection == WatchKeyTransfer.Selection(
            projectID: 42,
            projectName: "Synthetic Analytics",
            headlineMetricID: "42",
            watches: Self.watches()
        ))
    }

    @Test("a surrounding-whitespace key is trimmed before it is stored")
    func ingestTrimsKey() throws {
        let store = InMemoryTokenStore()
        let transfer = WatchKeyTransfer(key: "  \(Self.key)\n", region: .usCloud)
        try transfer.ingest(into: store)

        // `PersonalKeyAuthProvider` trims too; a key stored untrimmed would
        // build the header `Bearer  test-key-0001\n` and 401 forever.
        #expect(try store.load()?.key == Self.key)
    }

    @Test("an empty or whitespace key is refused before the store is touched")
    func emptyKeyIsRefused() throws {
        for raw in ["", "   ", "\n\t "] {
            let store = InMemoryTokenStore()
            #expect(throws: WatchKeyTransfer.Failure.emptyKey) {
                try WatchKeyTransfer(key: raw, region: .usCloud).ingest(into: store)
            }
            #expect(try store.load() == nil)
        }
    }

    @Test("a store failure propagates rather than reporting success")
    func storeFailurePropagates() {
        struct Refusing: CredentialStoring {
            struct Denied: Error {}
            func load() throws -> StoredCredential? { nil }
            func save(_ credential: StoredCredential) throws { throw Denied() }
            func clear() throws {}
        }

        #expect(throws: Refusing.Denied.self) {
            try WatchKeyTransfer(key: Self.key, region: .usCloud).ingest(into: Refusing())
        }
    }

    // MARK: - Telling an absent watch list from an unreadable one

    /// A `Condition` case this build has no idea about — what a newer phone
    /// adding, say, `.outsideRange(…)` would put on the wire. Its enclosing
    /// array decode throws, which is the whole point.
    private static let unreadableWatchesJSON = """
        {"key": "\(key)", "region": {"usCloud": {}}, "watches":
          [{"id": "w1", "metricID": "42", "title": "Example signups",
            "condition": {"risesFasterThan": {"_0": 5}}, "isEnabled": true}]}
        """

    @Test("an absent watch list is not a degraded one")
    func absentWatchesAreNotDegraded() throws {
        // Nothing was dropped: the phone sent no watches because there are
        // none, or because it is an older build that never sent any. An empty
        // Health screen is the truth here.
        let json = #"{"key": "test-key-0001", "region": {"usCloud": {}}}"#
        let received = try WatchKeyTransfer.decode(Data(json.utf8))

        #expect(received.watches.isEmpty)
        #expect(received.watchesDegraded == false)
    }

    @Test("an explicitly null watch list is not a degraded one either")
    func nullWatchesAreNotDegraded() throws {
        let json = #"{"key": "test-key-0001", "region": {"usCloud": {}}, "watches": null}"#
        let received = try WatchKeyTransfer.decode(Data(json.utf8))

        #expect(received.watches.isEmpty)
        #expect(received.watchesDegraded == false)
    }

    @Test("an empty watch list the phone really sent is not a degraded one")
    func emptyWatchesAreNotDegraded() throws {
        let json = #"{"key": "test-key-0001", "region": {"usCloud": {}}, "watches": []}"#
        let received = try WatchKeyTransfer.decode(Data(json.utf8))

        #expect(received.watches.isEmpty)
        #expect(received.watchesDegraded == false)
    }

    @Test("a watch list this build cannot read says so instead of reading as empty")
    func unreadableWatchesAreDegraded() throws {
        // The failure this flag exists for. Without it the wrist shows a
        // healthy, empty Health screen to a user who has five alerts armed —
        // indistinguishable from having none, and silent forever.
        let received = try WatchKeyTransfer.decode(Data(Self.unreadableWatchesJSON.utf8))

        #expect(received.key == Self.key)
        #expect(received.watches.isEmpty)
        #expect(received.watchesDegraded)
    }

    @Test("a readable watch list is never flagged as degraded")
    func readableWatchesAreNotDegraded() throws {
        let received = try WatchKeyTransfer.decode(Self.full(region: .usCloud).encoded())

        #expect(received.watches == Self.watches())
        #expect(received.watchesDegraded == false)
    }

    @Test("the degradation flag is an observation, not a field on the wire")
    func degradedFlagIsNotEncoded() throws {
        // A sender cannot claim it, and a receiver cannot be told it: the flag
        // is what *this* decode found, so it must not survive an encode.
        let encoded = try Self.full(region: .usCloud).encoded()
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["watchesDegraded"] == nil)

        // And re-encoding a degraded value drops the flag rather than
        // propagating a claim the next hop cannot verify.
        let degraded = try WatchKeyTransfer.decode(Data(Self.unreadableWatchesJSON.utf8))
        #expect(degraded.watchesDegraded)
        let reEncoded = try #require(
            try JSONSerialization.jsonObject(with: degraded.encoded()) as? [String: Any]
        )
        #expect(reEncoded["watchesDegraded"] == nil)
    }

    @Test("ingestion hands the degradation on so the wrist can say what it lost")
    func ingestCarriesDegradation() throws {
        let store = InMemoryTokenStore()
        let selection = try WatchKeyTransfer
            .decode(Data(Self.unreadableWatchesJSON.utf8))
            .ingest(into: store)

        // The key still lands — dropping it would punish the user for a field
        // they never touched.
        #expect(try store.load()?.key == Self.key)
        #expect(selection.watches.isEmpty)
        #expect(selection.watchesDegraded)

        // And the ordinary path says nothing was lost.
        #expect(try Self.full(region: .usCloud)
            .ingest(into: InMemoryTokenStore()).watchesDegraded == false)
    }

    @Test("a selection built without naming degradation is not degraded")
    func selectionDefaultsToUndegraded() {
        // The parameter is defaulted so call sites written before the flag
        // existed still compile and still mean what they meant.
        let selection = WatchKeyTransfer.Selection(
            projectID: 42,
            projectName: "Synthetic Analytics",
            headlineMetricID: "42",
            watches: []
        )
        #expect(selection.watchesDegraded == false)
    }

    @Test("both ends of the transport name the payload identically")
    func userInfoKeyIsShared() {
        // The kit owns no transport, so the one thing a sender and a receiver
        // can still disagree about is the dictionary key. It is a constant here
        // so neither end can spell it.
        #expect(WatchKeyTransfer.userInfoKey == "app.gethog.watchKeyTransfer")
    }

    @Test("the watches ride along so the wrist evaluates thresholds without a request")
    func watchesTravelWithTheKey() throws {
        // The whole point of carrying them: the watch's Health surface compares
        // the snapshot it already reads against these rules locally. A wrist
        // that had to fetch its own watch list would spend a request on data
        // the phone had in hand at hand-off time.
        let received = try WatchKeyTransfer.decode(Self.full(region: .usCloud).encoded())
        let evaluation = MetricWatchEvaluator.evaluate(
            snapshot: SharedSnapshot(
                projectID: 42,
                projectName: "Synthetic Analytics",
                metrics: [
                    SharedSnapshot.Metric(
                        id: "42",
                        title: "Synthetic signups",
                        value: 1_500,
                        unit: nil,
                        previous: nil,
                        sparkline: [],
                        dashboardID: nil
                    )
                ],
                flags: [],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            watches: received.watches,
            breaching: []
        )
        #expect(evaluation.alerts.map(\.watchID) == ["watch-a"])
    }
}
