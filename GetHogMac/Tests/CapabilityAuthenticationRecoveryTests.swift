import Foundation
import GetHogKit
import Testing

@testable import GetHog

private let capabilityRecoveryIdentityJSON = """
{"email":"operator@example.com","first_name":"Ada","distinct_id":"person-synthetic",
 "team":{"id":42,"name":"Synthetic Project","api_token":"phc_synthetic","timezone":"UTC"},
 "organization":{"id":"org-synthetic","name":"Synthetic Organization",
   "teams":[{"id":42,"name":"Synthetic Project","api_token":"phc_synthetic","timezone":"UTC"}]},
 "organizations":[{"id":"org-synthetic","name":"Synthetic Organization"}]}
"""

/// Authenticates successfully, then rejects every project request. Matching the
/// identity route keeps this test about an active session whose key expires,
/// rather than the already-covered rejected-on-connect path.
private struct ActiveSessionUnauthorizedTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isIdentity = request.url?.path.contains("/users/") ?? false
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isIdentity ? 200 : 401,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = isIdentity
            ? capabilityRecoveryIdentityJSON
            : #"{"type":"authentication_error","detail":"Synthetic rejection."}"#
        return (Data(body.utf8), response)
    }
}

@MainActor
@Suite("Capability authentication recovery", .serialized)
struct CapabilityAuthenticationRecoveryTests {

    @Test("an active preflight 401 clears the rejected key and asks for replacement")
    func activeSessionUnauthorizedRequiresCredentialReplacement() async throws {
        let store = InMemoryTokenStore()
        let (snapshots, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: store,
            transport: ActiveSessionUnauthorizedTransport(),
            snapshotStore: snapshots
        )

        try await model.connect(key: "synthetic-rejected-key", region: .usCloud)

        #expect(model.phase == .onboarding)
        #expect(model.storedCredentialRecovery == .replaceCredential(.usCloud))
        #expect(model.connectionError == PostHogError.unauthorized.localizedDescription)
        #expect(try store.load() == nil)
        #expect(model.client == nil)
        #expect(model.selectedProject == nil)
        #expect(model.lockedScope(for: .dashboards) == nil)
    }

    @Test("a late 401 from an old authentication epoch cannot revoke its replacement")
    func staleUnauthorizedCannotRevokeReplacementSession() async throws {
        let (snapshots, directory) = makeSnapshotStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: DemoTransport(),
            snapshotStore: snapshots
        )
        try await model.connect(key: "synthetic-first-key", region: .usCloud)
        let rejectedScope = try #require(model.flagWriteScope)

        try await model.connect(key: "synthetic-replacement-key", region: .usCloud)
        let replacementEpoch = try #require(model.authSessionID)
        await model.invalidateRejectedCredential(ifCurrent: rejectedScope)

        #expect(model.phase == .ready)
        #expect(model.authSessionID == replacementEpoch)
        #expect(model.capabilities?.allAvailable == true)
        #expect(model.storedCredentialRecovery == nil)
        #expect(try model.store.load()?.authSessionID == replacementEpoch)
    }

    private func makeSnapshotStore() -> (SharedSnapshotStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapabilityAuthenticationRecoveryTests-\(UUID())", isDirectory: true)
        return (SharedSnapshotStore(directory: directory), directory)
    }
}
