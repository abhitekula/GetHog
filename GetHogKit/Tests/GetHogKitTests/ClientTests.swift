import Foundation
import Testing

@testable import GetHogKit

@Suite("Auth")
struct AuthTests {

    @Test("personal key provider emits a Bearer header")
    func personalKeyHeader() async throws {
        let auth = PersonalKeyAuthProvider(key: "phx_example", region: .usCloud)
        #expect(try await auth.authorizationHeader() == "Bearer phx_example")
    }

    @Test(
        "maps regions to API hosts",
        arguments: [
            (PostHogRegion.usCloud, "https://us.posthog.com"),
            (PostHogRegion.euCloud, "https://eu.posthog.com"),
        ]
    )
    func regionHosts(region: PostHogRegion, expected: String) {
        #expect(region.host.absoluteString == expected)
    }

    @Test("supports a self-hosted host, which OAuth could never reach")
    func selfHostedRegion() {
        let region = PostHogRegion.selfHosted(URL(string: "https://ph.internal.example")!)
        #expect(region.host.absoluteString == "https://ph.internal.example")
    }
}

@Suite("Identity")
struct IdentityTests {

    @Test("decodes the current user, project, and available projects")
    func decodesMe() throws {
        let me = try MeResponse.decode(from: Fixture.data("users_me.json"))

        #expect(me.userID == 710_031)
        #expect(me.email == "zadie.quell@example.net")
        #expect(me.firstName == "Zadie")
        #expect(me.displayName == "Zadie Quell")
        #expect(me.distinctID == "person-example-operator")
        #expect(me.currentProject?.id == 1001)
        #expect(me.currentProject?.name == "Starling Metrics Lab")
        #expect(me.organization?.name == "Northstar Sandbox")
        #expect(me.projects.isEmpty)
        // The fixture repeats the authoritative current-organization summary;
        // consumer-facing organization choices must still contain it once.
        #expect(me.organizations.count == 3)
        #expect(me.allOrganizations.map(\.name) == ["Northstar Sandbox", "Juniper Test Guild"])
    }
}

@Suite("PostHog client")
struct ClientTests {

    private func makeClient(
        transport: StubTransport,
        governor: RateLimitGovernor = RateLimitGovernor()
    ) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: transport,
            governor: governor
        )
    }

    @Test("attaches the auth header and builds the URL from the region")
    func attachesAuthHeader() async throws {
        let transport = StubTransport(status: 200, body: #"{"count":0,"results":[]}"#)
        let client = makeClient(transport: transport)

        let _: Page<FeatureFlag> = try await client.send(
            Endpoint(path: "/api/projects/1001/feature_flags/", category: .crud)
        )

        let request = try #require(await transport.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer phx_test")
        #expect(request.url?.absoluteString == "https://us.posthog.com/api/projects/1001/feature_flags/")
    }

    @Test("appends query items")
    func appendsQueryItems() async throws {
        let transport = StubTransport(status: 200, body: #"{"count":0,"results":[]}"#)
        let client = makeClient(transport: transport)

        let _: Page<FeatureFlag> = try await client.send(
            Endpoint(
                path: "/api/projects/1001/feature_flags/",
                query: [URLQueryItem(name: "limit", value: "50")],
                category: .crud
            )
        )

        let url = try #require(await transport.lastRequest?.url?.absoluteString)
        #expect(url.contains("limit=50"))
    }

    @Test("surfaces a 401 as unauthorized")
    func unauthorized() async throws {
        let body = #"{"type":"authentication_error","code":"not_authenticated","detail":"Authentication credentials were not provided.","attr":null}"#
        let client = makeClient(transport: StubTransport(status: 401, body: body))

        await #expect(throws: PostHogError.unauthorized) {
            let _: Page<FeatureFlag> = try await client.send(
                Endpoint(path: "/api/projects/1001/feature_flags/", category: .crud)
            )
        }
    }

    @Test("extracts the missing scope name from a 403 so onboarding can name it")
    func forbiddenNamesScope() async throws {
        let body = #"{"type":"authentication_error","code":"permission_denied","detail":"API key missing required scope 'session_recording:read'","attr":null}"#
        let client = makeClient(transport: StubTransport(status: 403, body: body))

        do {
            let _: Page<FeatureFlag> = try await client.send(
                Endpoint(path: "/api/projects/1001/session_recordings/", category: .analytics)
            )
            Issue.record("expected a forbidden error")
        } catch let error as PostHogError {
            // Matches on the scope rather than the whole error: a 403 also
            // carries PostHog's prose detail, which is what tells the four
            // different 403 walls apart, and pinning it here would make this
            // test fail every time that wording changed.
            guard case .forbidden(let scope, _) = error else {
                Issue.record("expected .forbidden, got \(error)")
                return
            }
            #expect(scope == "session_recording:read")
        }
    }

    @Test("reports a 403 without a recognisable scope as forbidden with no scope")
    func forbiddenWithoutScope() async throws {
        let client = makeClient(transport: StubTransport(status: 403, body: #"{"detail":"nope"}"#))

        do {
            let _: Page<FeatureFlag> = try await client.send(
                Endpoint(path: "/api/projects/1001/feature_flags/", category: .crud)
            )
            Issue.record("expected a forbidden error")
        } catch let error as PostHogError {
            guard case .forbidden(let scope, _) = error else {
                Issue.record("expected .forbidden, got \(error)")
                return
            }
            #expect(scope == nil)
        }
    }

    @Test("penalizes the governor for the whole category on a 429")
    func rateLimitedPenalizesGovernor() async throws {
        let governor = RateLimitGovernor(jitter: { _ in 0 })
        let transport = StubTransport(status: 429, body: "{}", headers: ["Retry-After": "42"])
        let client = makeClient(transport: transport, governor: governor)

        _ = try? await client.send(
            Endpoint(path: "/api/projects/1001/feature_flags/", category: .crud)
        ) as Page<FeatureFlag>

        // The whole category must back off, not just the failed call.
        let delay = await governor.reserve(.crud, now: Date())
        #expect(delay > 40)
    }

    @Test("decodes a successful response body")
    func decodesBody() async throws {
        let body = try Fixture.string("feature_flags.json")
        let client = makeClient(transport: StubTransport(status: 200, body: body))

        let page: Page<FeatureFlag> = try await client.send(
            Endpoint(path: "/api/projects/1001/feature_flags/", category: .crud)
        )
        #expect(page.results.first?.key == "example-navigation")
    }

    @Test("URL loading errors retain the Foundation error code")
    func urlLoadingErrorsRetainTheirCode() {
        let mapped = URLSessionTransport.postHogError(
            from: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "Synthetic offline failure"]
            )
        )

        guard case .network(let code, let description) = mapped else {
            Issue.record("Expected a URL loading error, got \(mapped)")
            return
        }
        #expect(code == NSURLErrorNotConnectedToInternet)
        #expect(description == "Synthetic offline failure")
        #expect(mapped.networkErrorCode == NSURLErrorNotConnectedToInternet)
        #expect(mapped.isRetryable)
    }
}
