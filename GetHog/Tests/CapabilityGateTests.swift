import Foundation
import GetHogKit
import Testing

@testable import GetHog

private let meJSON = """
{"email":"a@example.com","first_name":"Ada","distinct_id":"d1",
 "team":{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"},
 "organization":{"id":"org1","name":"Acme",
   "teams":[{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"}]},
 "organizations":[{"id":"org1","name":"Acme"}]}
"""

/// Authenticates, then fails every other call with `status`.
///
/// Order-independent on purpose: the preflight's probes and the widget snapshot
/// interleave, and a test about permissions should not be coupled to how many
/// requests happen to precede them.
private struct FailingProbeTransport: HTTPTransport {
    let status: Int
    let body: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Matched on the collection rather than the exact path: `@me` survives
        // URL building percent-encoded, and this test is not about that.
        let isIdentity = request.url?.absoluteString.contains("/users/") ?? false
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isIdentity ? 200 : status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data((isIdentity ? meJSON : body).utf8), response)
    }
}

/// What the app is allowed to conclude from a permission probe.
///
/// Reported: same key, same build, one launch apart — the Sessions tab listed
/// sessions normally, then the whole tab was replaced by "Session inspector is
/// locked / Your PostHog API key is missing a scope. / Add it to your key in
/// PostHog, then re-check." The key was fine. The app told the user to go and
/// edit a working credential on the strength of a transient 500.
@Suite("Capability gate", .serialized)
@MainActor
struct CapabilityGateTests {

    @Test("a transient probe failure does not lock a capability")
    func transientFailureDoesNotLock() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: FailingProbeTransport(
                status: 500,
                body: #"{"type":"server_error","code":"error","detail":"A server error occurred."}"#
            )
        )
        try await model.connect(key: "phx_abc", region: .usCloud)

        // The screen opens and its own request produces the real error, which is
        // a better error than a guess about the user's key.
        #expect(model.isAvailable(.sessions))
        #expect(model.isAvailable(.events))
    }

    @Test("a transient probe failure never asks the user to edit their key")
    func transientFailureNamesNoScope() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: FailingProbeTransport(
                status: 500,
                body: #"{"type":"server_error","code":"error","detail":"A server error occurred."}"#
            )
        )
        try await model.connect(key: "phx_abc", region: .usCloud)

        // `LockedCapabilityView` prints this string as an instruction. There is
        // no evidence behind it here, so there must be no string.
        #expect(model.lockedScope(for: .sessions) == nil)
    }

    @Test("the probe's own error is kept rather than replaced by a scope claim")
    func keepsTheProbeError() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: FailingProbeTransport(
                status: 500,
                body: #"{"type":"server_error","code":"error","detail":"A server error occurred."}"#
            )
        )
        try await model.connect(key: "phx_abc", region: .usCloud)

        #expect(model.probeFailure(for: .sessions) != nil)
    }

    @Test("a real refusal still locks and still names the scope to add")
    func refusalLocks() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: FailingProbeTransport(
                status: 403,
                body: """
                    {"type":"authentication_error","code":"permission_denied",
                     "detail":"This action requires the session_recording:read scope."}
                    """
            )
        )
        try await model.connect(key: "phx_abc", region: .usCloud)

        // The feature the preflight exists for must keep working: a wrong scope
        // is still the most predictable support burden this app has.
        #expect(!model.isAvailable(.sessions))
        #expect(model.lockedScope(for: .sessions) == "session_recording:read")
        #expect(model.probeFailure(for: .sessions) == nil)
    }
}
