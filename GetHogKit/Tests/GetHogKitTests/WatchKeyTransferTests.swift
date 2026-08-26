import Foundation
import Testing

@testable import GetHogKit

@Suite("Watch key transfer")
struct WatchKeyTransferTests {
    private static let key = "test-key-0001"

    private static func full(region: PostHogRegion) -> WatchKeyTransfer {
        WatchKeyTransfer(
            key: key,
            region: region,
            organizationID: "org-synthetic-1001",
            organizationName: "Synthetic Labs",
            projectID: 42,
            projectName: "Synthetic Analytics",
            headlineMetricID: "42"
        )
    }

    @Test("round-trips every current field through the codec")
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
            #expect(received.organizationID == "org-synthetic-1001")
            #expect(received.organizationName == "Synthetic Labs")
            #expect(received.projectID == 42)
            #expect(received.projectName == "Synthetic Analytics")
            #expect(received.headlineMetricID == "42")
        }
    }

    @Test("optional selections survive as nil")
    func optionalsStayAbsent() throws {
        let received = try WatchKeyTransfer.decode(
            WatchKeyTransfer(key: Self.key, region: .usCloud).encoded()
        )

        #expect(received.projectID == nil)
        #expect(received.projectName == nil)
        #expect(received.organizationID == nil)
        #expect(received.organizationName == nil)
        #expect(received.headlineMetricID == nil)
    }

    @Test("legacy threshold fields are ignored and are not re-encoded")
    func legacyThresholdsAreIgnored() throws {
        let json = """
            {
              "version": 2,
              "key": "\(Self.key)",
              "region": {"usCloud": {}},
              "projectID": 42,
              "watches": [{"condition": {"futureCase": {"_0": 5}}}],
              "watchesDegraded": true
            }
            """
        let received = try WatchKeyTransfer.decode(Data(json.utf8))
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: received.encoded()) as? [String: Any]
        )

        #expect(received.projectID == 42)
        #expect(reencoded["watches"] == nil)
        #expect(reencoded["watchesDegraded"] == nil)
    }

    @Test("a newer version still yields its known fields")
    func newerVersionDecodes() throws {
        let json = """
            {"version": 3, "key": "\(Self.key)", "region": {"euCloud": {}},
             "futureField": {"nested": true}}
            """
        let received = try WatchKeyTransfer.decode(Data(json.utf8))

        #expect(received.version == 3)
        #expect(received.region == .euCloud)
    }

    @Test("version one and missing-version payloads remain compatible")
    func oldVersionsDecode() throws {
        let versionOne = """
            {"version": 1, "key": "\(Self.key)", "region": {"usCloud": {}},
             "projectID": 42, "projectName": "Synthetic Analytics"}
            """
        let missing = """
            {"key": "\(Self.key)", "region": {"usCloud": {}}}
            """

        #expect(try WatchKeyTransfer.decode(Data(versionOne.utf8)).projectID == 42)
        #expect(try WatchKeyTransfer.decode(Data(missing.utf8)).version == 1)
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

    @Test("ingestion writes a trimmed credential and returns only selections")
    func ingestWritesCredential() throws {
        let store = InMemoryTokenStore()
        let transfer = WatchKeyTransfer(
            key: "  \(Self.key)\n",
            region: .euCloud,
            organizationID: "org-synthetic-1001",
            organizationName: "Synthetic Labs",
            projectID: 42,
            projectName: "Synthetic Analytics",
            headlineMetricID: "42"
        )
        let selection = try transfer.ingest(into: store)

        #expect(try store.load() == StoredCredential(
            key: Self.key,
            region: .euCloud,
            projectID: 42
        ))
        #expect(selection == WatchKeyTransfer.Selection(
            organizationID: "org-synthetic-1001",
            organizationName: "Synthetic Labs",
            projectID: 42,
            projectName: "Synthetic Analytics",
            headlineMetricID: "42"
        ))
    }

    @Test("an empty key is refused before the store is touched")
    func emptyKeyIsRefused() throws {
        for raw in ["", "   ", "\n\t "] {
            let store = InMemoryTokenStore()
            #expect(throws: WatchKeyTransfer.Failure.emptyKey) {
                try WatchKeyTransfer(key: raw, region: .usCloud).ingest(into: store)
            }
            #expect(try store.load() == nil)
        }
    }

    @Test("both ends name the payload identically")
    func userInfoKeyIsShared() {
        #expect(WatchKeyTransfer.userInfoKey == "app.gethog.watchKeyTransfer")
    }
}
