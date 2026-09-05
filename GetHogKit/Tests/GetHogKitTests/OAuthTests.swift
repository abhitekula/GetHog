import Foundation
import Testing

@testable import GetHogKit

private let testDirectory = OAuthDirectory(callbackHost: "oauth.example.invalid")!

@Suite("OAuth directory")
struct OAuthDirectoryTests {

    @Test("rejects empty and malformed hosts")
    func rejectsBadHosts() {
        #expect(OAuthDirectory(callbackHost: "") == nil)
        #expect(OAuthDirectory(callbackHost: "   ") == nil)
        #expect(OAuthDirectory(callbackHost: "https://oauth.example.invalid") == nil)
        #expect(OAuthDirectory(callbackHost: "oauth.example.invalid/callback") == nil)
        #expect(OAuthDirectory(callbackHost: "OAUTH.EXAMPLE.INVALID")?.callbackHost == "oauth.example.invalid")
    }

    @Test("derives every deployment string from the one host")
    func derivesStrings() {
        #expect(testDirectory.clientID == "https://oauth.example.invalid/posthog-client")
        #expect(testDirectory.redirectURI == "https://oauth.example.invalid/oauth/callback")
        #expect(testDirectory.authorizationEndpoint.absoluteString == "https://oauth.posthog.com/oauth/authorize/")
        #expect(testDirectory.tokenEndpoint.absoluteString == "https://oauth.posthog.com/oauth/token/")
        #expect(testDirectory.revocationEndpoint.absoluteString == "https://oauth.posthog.com/oauth/revoke/")
    }

    @Test("requested scopes cover the key catalog and organization read")
    func scopesCoverCatalog() {
        let requested = Set(OAuthDirectory.requestedScopes)
        for descriptor in APIKeyScopeGuidance.coreReadScopes {
            #expect(requested.contains(descriptor.scope), "missing core read \(descriptor.scope)")
        }
        for descriptor in APIKeyScopeGuidance.optionalWriteActions(for: .fullClient) {
            #expect(requested.contains(descriptor.scope), "missing write \(descriptor.scope)")
        }
        #expect(requested.contains(AppModelOAuthOrganizationScope))
    }

    @Test("required and optional scopes partition the request")
    func scopePartitions() {
        // Locked on the consent screen: the reads the app cannot run without.
        #expect(Set(OAuthDirectory.requiredScopes) == Set(
            APIKeyScopeGuidance.coreReadScopes.map(\.scope) + [AppModelOAuthOrganizationScope]
        ))
        // Declinable on the consent screen: every write the app gates behind
        // user intent. A declined write fails only its own action.
        #expect(Set(OAuthDirectory.optionalScopes) == Set(
            APIKeyScopeGuidance.optionalWriteActions(for: .fullClient).map(\.scope)
        ))
        #expect(Set(OAuthDirectory.requestedScopes) ==
            Set(OAuthDirectory.requiredScopes + OAuthDirectory.optionalScopes))
        #expect(Set(OAuthDirectory.requiredScopes).intersection(OAuthDirectory.optionalScopes).isEmpty)
    }

    @Test("builds a code-only, S256 authorize URL")
    func authorizeURL() {
        let pkce = PKCE(verifier: "synthetic-verifier")
        let url = testDirectory.authorizationURL(state: "synthetic-state", pkce: pkce)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!
            .reduce(into: [:]) { $0[$1.name] = $1.value }
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == testDirectory.clientID)
        #expect(query["redirect_uri"] == testDirectory.redirectURI)
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "synthetic-state")
        #expect(query["scope"] == OAuthDirectory.requestedScopes.joined(separator: " "))
    }
}

/// `AppModel.organizationReadScope` lives in the app layer, which the kit
/// cannot import. Pinned here as a literal so a rename there fails this test
/// instead of silently dropping the scope from the OAuth request.
private let AppModelOAuthOrganizationScope = "organization:read"

@Suite("PKCE")
struct PKCETests {

    @Test("matches the RFC 7636 Appendix B vector")
    func rfcVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("generates a 43-character verifier")
    func generatedLength() {
        #expect(PKCE.generate().verifier.count == 43)
    }
}

@Suite("OAuth token client")
struct OAuthTokenClientTests {

    private func tokenJSON(
        access: String = "pha_synthetic",
        refresh: String? = "phr_synthetic",
        expires: Int? = 3600
    ) -> String {
        var json = #"{"access_token": "\#(access)", "token_type": "Bearer""#
        if let refresh { json += #", "refresh_token": "\#(refresh)""# }
        if let expires { json += #", "expires_in": \#(expires)"# }
        json += #", "scope": "dashboard:read insight:read", "scoped_teams": [1001], "scoped_organizations": ["org-synthetic"], "future_field": true}"#
        return json
    }

    private func response(status: Int, body: String) -> (Data, HTTPURLResponse) {
        (
            Data(body.utf8),
            HTTPURLResponse(
                url: URL(string: "https://oauth.posthog.com/")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    @Test("exchange posts a form body and decodes tolerantly")
    func exchange() async throws {
        let transport = StubTransport(responses: [response(status: 200, body: tokenJSON())])
        let client = OAuthTokenClient(directory: testDirectory, transport: transport)
        let tokens = try await client.exchange(code: "synthetic-code", verifier: "synthetic-verifier")

        #expect(tokens.accessToken == "pha_synthetic")
        #expect(tokens.refreshToken == "phr_synthetic")
        #expect(tokens.expiresIn == 3600)
        #expect(tokens.scopedTeams == [1001])
        #expect(tokens.scopedOrganizations == ["org-synthetic"])

        let request = try #require(await transport.lastRequest)
        #expect(request.url == testDirectory.tokenEndpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=synthetic-code"))
        #expect(body.contains("code_verifier=synthetic-verifier"))
        #expect(body.contains("client_id="))
        #expect(body.contains("redirect_uri="))
    }

    @Test("form encoding escapes reserved characters")
    func formEscapes() {
        #expect(OAuthTokenClient.formEscape("a+b&c=d/e") == "a%2Bb%26c%3Dd%2Fe")
        #expect(OAuthTokenClient.formEscape("dashboard:read insight:read") == "dashboard%3Aread%20insight%3Aread")
    }

    @Test("decodes the live token shape including region fields")
    func liveShape() throws {
        let body = """
        {"access_token":"pha_synthetic","expires_in":604800,"token_type":"Bearer",
         "scope":"dashboard:read insight:read","refresh_token":"phr_synthetic",
         "scoped_teams":[],"scoped_organizations":[],
         "posthog_region":"us","posthog_base_url":"https://us.posthog.com"}
        """
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(body.utf8))
        #expect(response.expiresIn == 604800)
        #expect(response.scopedTeams == [])
        #expect(response.posthogRegion == "us")
        #expect(response.resolvedRegion == .usCloud)
    }

    @Test("resolves regions from code, base URL, or neither")
    func regionResolution() {
        #expect(OAuthTokenResponse(accessToken: "x", posthogRegion: "EU").resolvedRegion == .euCloud)
        #expect(OAuthTokenResponse(accessToken: "x", posthogBaseURL: "https://eu.posthog.com").resolvedRegion == .euCloud)
        #expect(OAuthTokenResponse(accessToken: "x", posthogRegion: "us", posthogBaseURL: "https://eu.posthog.com").resolvedRegion == .usCloud)
        #expect(OAuthTokenResponse(accessToken: "x").resolvedRegion == nil)
        #expect(OAuthTokenResponse(accessToken: "x", posthogRegion: "aq").resolvedRegion == nil)
    }

    @Test("invalid_grant becomes unauthorized")
    func invalidGrant() async {
        let transport = StubTransport(responses: [
            response(status: 400, body: #"{"error": "invalid_grant", "error_description": "expired"}"#),
        ])
        let client = OAuthTokenClient(directory: testDirectory, transport: transport)
        await #expect(throws: PostHogError.unauthorized) {
            try await client.exchange(code: "dead", verifier: "dead")
        }
    }

    @Test("other failures keep their status and description")
    func otherFailure() async {
        let transport = StubTransport(responses: [
            response(status: 429, body: #"{"error": "temporarily_unavailable", "error_description": "back off"}"#),
        ])
        let client = OAuthTokenClient(directory: testDirectory, transport: transport)
        do {
            _ = try await client.exchange(code: "x", verifier: "y")
            Issue.record("expected a throw")
        } catch let error as PostHogError {
            #expect(error == .http(status: 429, detail: "back off"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("revoke posts the token and throws on refusal")
    func revoke() async throws {
        let transport = StubTransport(responses: [response(status: 200, body: "{}")])
        let client = OAuthTokenClient(directory: testDirectory, transport: transport)
        try await client.revoke("pha_synthetic")
        let request = try #require(await transport.lastRequest)
        #expect(request.url == testDirectory.revocationEndpoint)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == "token=pha_synthetic")
    }
}

@Suite("OAuth watch transfer")
struct OAuthWatchTransferTests {

    @Test("grant fields round-trip and ingest preserves the grant")
    func grantRoundTrips() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let sent = WatchKeyTransfer(
            key: "pha_synthetic",
            region: .usCloud,
            projectID: 1001,
            refreshToken: "phr_synthetic",
            accessTokenExpiry: expiry,
            grantedScopes: ["dashboard:read"]
        )
        let received = try WatchKeyTransfer.decode(sent.encoded())
        #expect(received == sent)

        let store = InMemoryTokenStore()
        _ = try received.ingest(into: store)
        let saved = try #require(try store.load())
        #expect(saved.isOAuth)
        #expect(saved.key == "pha_synthetic")
        #expect(saved.refreshToken == "phr_synthetic")
        #expect(saved.accessTokenExpiry == expiry)
    }

    @Test("pre-OAuth payloads still ingest as personal keys")
    func legacyTransfer() throws {
        let received = try WatchKeyTransfer.decode(
            Data(#"{"version":2,"key":"phx_legacy","region":{"usCloud":{}}}"#.utf8)
        )
        #expect(received.refreshToken == nil)
        let store = InMemoryTokenStore()
        _ = try received.ingest(into: store)
        #expect(try store.load()?.isOAuth == false)
    }
}

@Suite("OAuth provider")
struct OAuthAuthProviderTests {

    private func credential(
        access: String = "pha_current",
        expiry: Date? = Date().addingTimeInterval(3600)
    ) -> StoredCredential {
        StoredCredential(
            key: access,
            region: .usCloud,
            projectID: 1001,
            authSessionID: UUID(),
            refreshToken: "phr_synthetic",
            accessTokenExpiry: expiry,
            grantedScopes: ["dashboard:read"]
        )
    }

    private func tokenResponse(access: String, refresh: String = "phr_next") -> (Data, HTTPURLResponse) {
        (
            Data(#"{"access_token": "\#(access)", "refresh_token": "\#(refresh)", "expires_in": 3600}"#.utf8),
            HTTPURLResponse(
                url: URL(string: "https://oauth.posthog.com/")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    @Test("serves a fresh token without network")
    func freshToken() async throws {
        let transport = StubTransport(status: 500)
        let store = InMemoryTokenStore()
        let provider = OAuthAuthProvider(
            credential: credential(),
            directory: testDirectory,
            store: store,
            transport: transport
        )
        #expect(try await provider.authorizationHeader() == "Bearer pha_current")
        #expect(await transport.requestCount == 0)
    }

    @Test("refreshes an expired token once for concurrent callers and persists")
    func singleFlightRefresh() async throws {
        let transport = StubTransport(responses: [tokenResponse(access: "pha_next")])
        let store = InMemoryTokenStore()
        let provider = OAuthAuthProvider(
            credential: credential(expiry: Date().addingTimeInterval(-10)),
            directory: testDirectory,
            store: store,
            transport: transport
        )
        async let first = provider.authorizationHeader()
        async let second = provider.authorizationHeader()
        let headers = try await [first, second]
        #expect(headers == ["Bearer pha_next", "Bearer pha_next"])
        #expect(await transport.requestCount == 1)
        #expect(try store.load()?.key == "pha_next")
        #expect(try store.load()?.refreshToken == "phr_next")
        #expect(try store.load()?.projectID == 1001)
    }

    @Test("a dead grant surfaces as unauthorized")
    func deadGrant() async {
        let transport = StubTransport(responses: [(
            Data(#"{"error": "invalid_grant"}"#.utf8),
            HTTPURLResponse(
                url: URL(string: "https://oauth.posthog.com/")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
        )])
        let provider = OAuthAuthProvider(
            credential: credential(expiry: Date().addingTimeInterval(-10)),
            directory: testDirectory,
            store: InMemoryTokenStore(),
            transport: transport
        )
        await #expect(throws: PostHogError.unauthorized) {
            try await provider.authorizationHeader()
        }
    }

    @Test("pre-OAuth payloads decode with OAuth fields absent")
    func legacyPayload() throws {
        struct PreOAuthCredential: Encodable {
            let key: String
            let region: PostHogRegion
            let projectID: Int?
            let authSessionID: UUID?
        }
        let encoded = try JSONEncoder().encode(PreOAuthCredential(
            key: "phx_legacy",
            region: .usCloud,
            projectID: 1001,
            authSessionID: nil
        ))
        let decoded = try JSONDecoder().decode(StoredCredential.self, from: encoded)
        #expect(!decoded.isOAuth)
        #expect(decoded.refreshToken == nil)
        #expect(decoded.accessTokenExpiry == nil)
        #expect(decoded.grantedScopes == nil)
    }
}
