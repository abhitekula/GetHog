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

    private struct StringValue: Codable, Equatable, Sendable {
        let value: String
    }

    private struct IntValue: Codable, Equatable, Sendable {
        let value: Int
    }

    private actor LateResponseTransport: HTTPTransport {
        private let body: Data
        private var requestCount = 0
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?

        init(body: String) {
            self.body = Data(body.utf8)
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requestCount += 1
            if requestCount == 1 {
                let waiters = arrivals
                arrivals.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { release = $0 }
            }
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        func waitForFirstRequest() async {
            if requestCount > 0 { return }
            await withCheckedContinuation { arrivals.append($0) }
        }

        func releaseFirstRequest() {
            release?.resume()
            release = nil
        }

        func count() -> Int { requestCount }
    }

    private func makeClient(
        transport: StubTransport,
        governor: RateLimitGovernor = RateLimitGovernor(),
        cache: ResponseCache? = nil,
        cacheNamespace: String? = nil,
        region: PostHogRegion = .usCloud
    ) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: region),
            transport: transport,
            governor: governor,
            responseCache: cache,
            responseCacheNamespace: cacheNamespace
        )
    }

    private func withTemporaryCache<T: Sendable>(
        _ body: (ResponseCache) async throws -> T
    ) async rethrows -> T {
        let cache = ResponseCache(subdirectory: "GetHogClientTests-\(UUID().uuidString)")
        do {
            let value = try await body(cache)
            await cache.clear()
            return value
        } catch {
            await cache.clear()
            throw error
        }
    }

    @Test("a completed cache-aware GET is decoded twice with one transport request")
    func completedGetUsesResponseCache() async throws {
        try await withTemporaryCache { cache in
            let transport = StubTransport(status: 200, body: #"{"value":"cached"}"#)
            let client = makeClient(
                transport: transport,
                cache: cache,
                cacheNamespace: "synthetic-auth-epoch-a"
            )
            let endpoint = Endpoint(
                path: "/api/projects/1001/dashboards/725001/",
                query: [URLQueryItem(name: "refresh", value: "force_cache")],
                category: .analytics
            )

            let first: StringValue = try await client.sendCached(endpoint, ttl: 300)
            let second: StringValue = try await client.sendCached(endpoint, ttl: 300)

            #expect(first == StringValue(value: "cached"))
            #expect(second == first)
            #expect(await transport.requestCount == 1)
        }
    }

    @Test("cache identity fences authentication epoch and the full absolute URL")
    func cacheIdentityFencesAuthorityAndURL() async throws {
        try await withTemporaryCache { cache in
            let firstTransport = StubTransport(status: 200, body: #"{"value":"first"}"#)
            let firstClient = makeClient(
                transport: firstTransport,
                cache: cache,
                cacheNamespace: "synthetic-auth-epoch-a"
            )
            let firstEndpoint = Endpoint(
                path: "/api/projects/1001/dashboards/725001/",
                query: [URLQueryItem(name: "refresh", value: "force_cache")],
                category: .analytics
            )
            let _: StringValue = try await firstClient.sendCached(firstEndpoint, ttl: 300)

            let changedURL: StringValue = try await firstClient.sendCached(
                Endpoint(
                    path: "/api/projects/1002/insights/720002/",
                    query: [URLQueryItem(name: "refresh", value: "force_cache")],
                    category: .analytics
                ),
                ttl: 300
            )
            #expect(changedURL.value == "first")
            #expect(await firstTransport.requestCount == 2)

            let replacementTransport = StubTransport(
                status: 200,
                body: #"{"value":"replacement"}"#
            )
            let replacementClient = makeClient(
                transport: replacementTransport,
                cache: cache,
                cacheNamespace: "synthetic-auth-epoch-b"
            )
            let replacement: StringValue = try await replacementClient.sendCached(
                firstEndpoint,
                ttl: 300
            )
            #expect(replacement.value == "replacement")
            #expect(await replacementTransport.requestCount == 1)

            let euTransport = StubTransport(status: 200, body: #"{"value":"eu"}"#)
            let euClient = makeClient(
                transport: euTransport,
                cache: cache,
                cacheNamespace: "synthetic-auth-epoch-a",
                region: .euCloud
            )
            let eu: StringValue = try await euClient.sendCached(firstEndpoint, ttl: 300)
            #expect(eu.value == "eu")
            #expect(await euTransport.requestCount == 1)
        }
    }

    @Test("an immediately expired cache-aware GET returns to transport")
    func expiredGetReturnsToTransport() async throws {
        try await withTemporaryCache { cache in
            let transport = StubTransport(status: 200, body: #"{"value":"fresh"}"#)
            let client = makeClient(
                transport: transport,
                cache: cache,
                cacheNamespace: "synthetic-auth-epoch-a"
            )
            let endpoint = Endpoint(path: "/api/projects/1001/insights/720001/", category: .analytics)

            let _: StringValue = try await client.sendCached(endpoint, ttl: 0)
            let _: StringValue = try await client.sendCached(endpoint, ttl: 0)

            #expect(await transport.requestCount == 2)
        }
    }

    @Test("cache-aware sends never cache writes or requests with bodies")
    func writesBypassResponseCache() async throws {
        try await withTemporaryCache { cache in
            let transport = StubTransport(status: 200, body: #"{"value":"written"}"#)
            let client = makeClient(
                transport: transport,
                cache: cache,
                cacheNamespace: "synthetic-auth-epoch-a"
            )
            let endpoint = Endpoint(
                path: "/api/projects/1001/annotations/",
                method: "POST",
                body: Data(#"{"content":"Synthetic note"}"#.utf8),
                category: .crud
            )

            let _: StringValue = try await client.sendCached(endpoint, ttl: 300)
            let _: StringValue = try await client.sendCached(endpoint, ttl: 300)

            #expect(await transport.requestCount == 2)
        }
    }

    @Test("a cached payload that no longer decodes is evicted and refetched")
    func malformedCachedPayloadIsRefetched() async throws {
        try await withTemporaryCache { cache in
            let first = HTTPURLResponse(
                url: URL(string: "https://us.posthog.com/")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let transport = StubTransport(responses: [
                (Data(#"{"value":"old-shape"}"#.utf8), first),
                (Data(#"{"value":7}"#.utf8), first),
            ])
            let client = makeClient(
                transport: transport,
                cache: cache,
                cacheNamespace: "synthetic-auth-epoch-a"
            )
            let endpoint = Endpoint(path: "/api/projects/1001/insights/720001/", category: .analytics)

            let old: StringValue = try await client.sendCached(endpoint, ttl: 300)
            let replacement: IntValue = try await client.sendCached(endpoint, ttl: 300)

            #expect(old.value == "old-shape")
            #expect(replacement.value == 7)
            #expect(await transport.requestCount == 2)
        }
    }

    @Test("a cancelled late response cannot populate the response cache")
    func cancelledLateResponseIsNotCached() async throws {
        try await withTemporaryCache { cache in
            let transport = LateResponseTransport(body: #"{"value":"late"}"#)
            let client = PostHogClient(
                auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
                transport: transport,
                responseCache: cache,
                responseCacheNamespace: "synthetic-auth-epoch-a"
            )
            let endpoint = Endpoint(path: "/api/projects/1001/dashboards/725001/", category: .analytics)
            let cancelled = Task {
                try await client.sendCached(endpoint, ttl: 300) as StringValue
            }
            await transport.waitForFirstRequest()

            cancelled.cancel()
            await transport.releaseFirstRequest()
            await #expect(throws: CancellationError.self) {
                _ = try await cancelled.value
            }

            let recovered: StringValue = try await client.sendCached(endpoint, ttl: 300)
            #expect(recovered.value == "late")
            #expect(await transport.count() == 2)
        }
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
