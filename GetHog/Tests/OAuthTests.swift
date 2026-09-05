import Foundation
import Testing

@testable import GetHog
@testable import GetHogKit

private let oauthTestDirectory = OAuthDirectory(callbackHost: "oauth.example.com")!

private let oauthMeJSON = """
{"email":"oauth@example.com","first_name":"OAuth","distinct_id":"oauth1",
 "team":{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"},
 "organization":{"id":"org1","name":"Acme",
   "teams":[{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"}]},
 "organizations":[{"id":"org1","name":"Acme"}]}
"""

private let oauthTokenJSON = """
{"access_token":"pha_synthetic","token_type":"Bearer","expires_in":3600,
 "refresh_token":"phr_synthetic","scope":"dashboard:read insight:read"}
"""

/// Replays scripted HTTP responses so session state can be tested without network.
private actor OAuthScriptedTransport: HTTPTransport {
    private var responses: [(Int, String)]
    private(set) var requestPaths: [String] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestPaths.append(request.url?.path ?? "")
        let (status, body) = responses.count == 1 ? responses[0] : responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

@Suite("OAuth callback")
@MainActor
struct OAuthCallbackTests {

    @Test("parses a code and state off the callback")
    func parsesCode() throws {
        let url = URL(string: "https://oauth.example.com/oauth/callback?code=authcode&state=st")!
        let callback = try #require(OAuthCallback.parse(url))
        #expect(callback.outcome == .code("authcode"))
        #expect(callback.state == "st")
    }

    @Test("parses a denial, and rejects non-callbacks")
    func parsesDenialAndRejects() {
        let denied = URL(string: "https://oauth.example.com/oauth/callback?error=access_denied&state=st")!
        #expect(OAuthCallback.parse(denied)?.outcome == .denied("access_denied"))
        #expect(OAuthCallback.parse(URL(string: "gethog://dashboard/1")!) == nil)
        #expect(OAuthCallback.parse(URL(string: "https://oauth.example.com/other?code=x")!) == nil)
    }

    @Test("matches callbacks by host and path only")
    func matchesCallbacks() {
        let callback = URL(string: "https://oauth.example.com/oauth/callback?code=x")!
        #expect(OAuthCallback.isOAuthCallback(callback, directory: oauthTestDirectory))
        #expect(!OAuthCallback.isOAuthCallback(
            URL(string: "https://other.example.com/oauth/callback?code=x")!,
            directory: oauthTestDirectory
        ))
        #expect(!OAuthCallback.isOAuthCallback(
            URL(string: "gethog://dashboard/1")!,
            directory: oauthTestDirectory
        ))
    }

    @Test("delivers before and after subscription, first writer wins")
    func inboxSemantics() async {
        OAuthCallbackInbox.reset()
        OAuthCallbackInbox.deliver(OAuthCallback(outcome: .code("first"), state: "s", source: .universalLink))
        OAuthCallbackInbox.deliver(OAuthCallback(outcome: .code("second"), state: "s", source: .sessionCompletion))
        let callback = await OAuthCallbackInbox.next(matching: "s")
        #expect(callback.outcome == .code("first"))
        #expect(callback.source == .universalLink)

        OAuthCallbackInbox.reset()
        async let waiter = OAuthCallbackInbox.next(matching: "late")
        OAuthCallbackInbox.deliver(OAuthCallback(outcome: .cancelled, state: "late", source: .sessionCompletion))
        #expect(await waiter.outcome == .cancelled)
        OAuthCallbackInbox.reset()
    }

    @Test("routes browsing activities for the configured directory only")
    func routesActivities() async {
        OAuthCallbackInbox.reset()
        func activity(url: URL?, type: String = NSUserActivityTypeBrowsingWeb) -> NSUserActivity {
            let activity = NSUserActivity(activityType: type)
            activity.webpageURL = url
            return activity
        }

        let callback = URL(string: "https://oauth.example.com/oauth/callback?code=c&state=s")!
        #expect(OAuthActivityRouter.route(activity(url: callback), directory: oauthTestDirectory))
        #expect(await OAuthCallbackInbox.next(matching: "s").outcome == .code("c"))

        #expect(!OAuthActivityRouter.route(activity(url: callback), directory: nil))
        #expect(!OAuthActivityRouter.route(
            activity(url: URL(string: "https://oauth.example.com/other")!),
            directory: oauthTestDirectory
        ))
        #expect(!OAuthActivityRouter.route(
            activity(url: callback, type: "app.gethog.browsing"),
            directory: oauthTestDirectory
        ))
        OAuthCallbackInbox.reset()
    }
}

/// Answers the token exchange with a reads-only grant, identity and reads
/// from fixtures, and refuses flag writes the way PostHog does when the
/// consent screen's optional scopes were declined.
private actor ScopeDeniedTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let status: Int
        let body: String
        if path.hasPrefix("/oauth/token") {
            status = 200
            body = """
            {"access_token":"pha_synthetic","token_type":"Bearer","expires_in":604800,
             "refresh_token":"phr_synthetic",
             "scope":"dashboard:read insight:read query:read session_recording:read feature_flag:read project:read organization:read"}
            """
        } else if request.httpMethod == "PATCH" {
            status = 403
            body = """
            {"type":"authentication_error","code":"permission_denied",
             "detail":"You do not have the feature_flag:write scope."}
            """
        } else {
            status = 200
            body = oauthMeJSON
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Suite("OAuth session")
@MainActor
struct OAuthSessionTests {

    @Test("connectWithOAuth exchanges, probes the region, and persists the grant")
    func connects() async throws {
        let transport = OAuthScriptedTransport([(200, oauthTokenJSON), (200, oauthMeJSON)])
        let store = InMemoryTokenStore()
        let model = AppModel(store: store, transport: transport)

        try await model.connectWithOAuth(
            directory: oauthTestDirectory,
            code: "synthetic-code",
            verifier: "synthetic-verifier"
        )

        #expect(model.phase == .ready)
        #expect(model.oauthDirectory == oauthTestDirectory)
        let saved = try #require(try store.load())
        #expect(saved.isOAuth)
        #expect(saved.key == "pha_synthetic")
        #expect(saved.refreshToken == "phr_synthetic")
        #expect(saved.region == .usCloud)
        let paths = await transport.requestPaths
        #expect(paths.contains("/oauth/token"))
    }

    @Test("a declared region skips the probe")
    func declaredRegionSkipsProbe() async throws {
        let regionalToken = """
        {"access_token":"pha_synthetic","token_type":"Bearer","expires_in":604800,
         "refresh_token":"phr_synthetic","scope":"dashboard:read",
         "posthog_region":"eu","posthog_base_url":"https://eu.posthog.com"}
        """
        let transport = OAuthScriptedTransport([(200, regionalToken), (200, oauthMeJSON)])
        let store = InMemoryTokenStore()
        let model = AppModel(store: store, transport: transport)

        try await model.connectWithOAuth(
            directory: oauthTestDirectory,
            code: "synthetic-code",
            verifier: "synthetic-verifier"
        )

        #expect(try store.load()?.region == .euCloud)
        // One identity call (activation) instead of two: no probe was needed.
        let identityCalls = await transport.requestPaths.filter { $0 == "/api/users/@me" }
        #expect(identityCalls.count == 1)
    }

    @Test("a US 401 falls through to the EU region")
    func fallsThroughToEU() async throws {
        let transport = OAuthScriptedTransport([
            (200, oauthTokenJSON),
            (401, "{}"),
            (200, oauthMeJSON),
        ])
        let store = InMemoryTokenStore()
        let model = AppModel(store: store, transport: transport)

        try await model.connectWithOAuth(
            directory: oauthTestDirectory,
            code: "synthetic-code",
            verifier: "synthetic-verifier"
        )

        #expect(model.phase == .ready)
        #expect(try store.load()?.region == .euCloud)
    }

    @Test("a dead code surfaces unauthorized without a session")
    func deadCode() async {
        let transport = OAuthScriptedTransport([
            (400, #"{"error":"invalid_grant"}"#),
        ])
        let store = InMemoryTokenStore()
        let model = AppModel(store: store, transport: transport)

        await #expect(throws: PostHogError.unauthorized) {
            try await model.connectWithOAuth(
                directory: oauthTestDirectory,
                code: "dead",
                verifier: "dead"
            )
        }
        #expect(model.phase != .ready)
        #expect((try? store.load()) == nil)
    }

    @Test("sign-out revokes the grant before clearing")
    func signOutRevokes() async throws {
        let transport = OAuthScriptedTransport([(200, oauthTokenJSON), (200, oauthMeJSON)])
        let model = AppModel(store: InMemoryTokenStore(), transport: transport)
        try await model.connectWithOAuth(
            directory: oauthTestDirectory,
            code: "synthetic-code",
            verifier: "synthetic-verifier"
        )

        await model.signOut()

        let paths = await transport.requestPaths
        #expect(paths.contains("/oauth/revoke"))
        #expect(model.oauthDirectory == nil)
        #expect(model.phase == .onboarding)
    }

    @Test("a reads-only grant keeps reads working and locks only the write")
    func narrowedGrantDegradesGracefully() async throws {
        let model = AppModel(store: InMemoryTokenStore(), transport: ScopeDeniedTransport())
        try await model.connectWithOAuth(
            directory: oauthTestDirectory,
            code: "synthetic-code",
            verifier: "synthetic-verifier"
        )

        // Reads authenticated: the session is ready on a narrowed grant.
        #expect(model.phase == .ready)
        #expect(model.me?.email == "oauth@example.com")

        // The declined write fails with the Settings remedy, not key editing.
        let outcome = await model.setFlag(id: 1, active: true)
        guard case .failed(let message) = outcome else {
            Issue.record("expected the declined write to fail")
            return
        }
        #expect(message.contains("feature_flag:write"))
        #expect(message.contains("Settings"))
        #expect(!message.contains("API key"))
    }
}
