import Foundation
import GetHogKit
import Testing
import UIKit

@testable import GetHog

/// `GET /exports/{id}/content/` answers a 302 to third-party object storage.
///
/// The suite exists for one reason: `URLSession` follows that redirect on its own
/// and replays the original request's headers onto the new host — so the naive
/// implementation posts the user's PostHog personal API key to a storage provider
/// that never asked for it. `RedirectRefusal` is what stops it, and a guarantee
/// nothing tests is a guarantee somebody deletes.
@Suite("Render URL resolution")
struct RenderURLResolverTests {

    // A presigned link shaped like the ones PostHog hands back: the signature is
    // in the query string, which is exactly why no header needs to follow it.
    static let storageURL = "https://cdn.example.com/render.mp4"
        + "?response-content-type=video%2Fmp4"
        + "&X-Amz-Algorithm=AWS4-HMAC-SHA256"
        + "&X-Amz-Date=20260112T120000Z"
        + "&X-Amz-Expires=3600"
        + "&X-Amz-Signature=deadbeef"

    static let contentURL = URL(
        string: "https://us.posthog.com/api/projects/42/exports/700047/content/"
    )!

    private static func response(
        status: Int,
        headers: [String: String] = [:],
        url: URL = contentURL
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    // MARK: - Reading the redirect

    @Test("takes the storage URL out of the redirect rather than following it")
    func readsLocation() throws {
        let resolved = try RenderURLResolver.resolved(
            from: Self.response(status: 302, headers: ["Location": Self.storageURL]),
            requestedAt: Self.contentURL
        )
        #expect(resolved.url.host() == "cdn.example.com")
        #expect(resolved.url.absoluteString == Self.storageURL)
    }

    /// A self-hosted instance proxying its own storage is where a relative
    /// `Location` would turn up, and the spec permits one.
    @Test("resolves a relative Location against the request")
    func relativeLocation() throws {
        let resolved = try RenderURLResolver.resolved(
            from: Self.response(status: 302, headers: ["Location": "/media/render.mp4"]),
            requestedAt: Self.contentURL
        )
        #expect(resolved.url.absoluteString == "https://us.posthog.com/media/render.mp4")
    }

    @Test("refuses a redirect that says nothing about where it went")
    func missingLocation() {
        #expect(throws: RenderURLError.noLocation) {
            try RenderURLResolver.resolved(
                from: Self.response(status: 302),
                requestedAt: Self.contentURL
            )
        }
    }

    /// A 200 is not a success here. It means the instance is serving the file
    /// itself, and streaming that would mean attaching the API key to every range
    /// request `AVPlayer` makes — the exact thing this code path prevents.
    @Test("treats a directly-served body as unplayable, not as a win")
    func servedDirectly() {
        #expect(throws: RenderURLError.servedDirectly(status: 200)) {
            try RenderURLResolver.resolved(
                from: Self.response(status: 200, headers: ["Content-Type": "video/mp4"]),
                requestedAt: Self.contentURL
            )
        }
    }

    @Test("reports a missing file as the status PostHog gave")
    func notFound() {
        #expect(throws: RenderURLError.http(status: 404)) {
            try RenderURLResolver.resolved(
                from: Self.response(status: 404),
                requestedAt: Self.contentURL
            )
        }
    }

    // MARK: - Expiry

    @Test("reads the presigned window off the URL")
    func presignedExpiry() throws {
        let url = try #require(URL(string: Self.storageURL))
        let expiry = try #require(RenderURLResolver.presignedExpiry(of: url))
        // The URL is signed for one hour.
        let signed = try #require(PostHogDate.parse("2026-01-12T12:00:00Z"))
        #expect(abs(expiry.timeIntervalSince(signed) - 3600) < 1)
    }

    @Test("reads Google's spelling of the same parameters")
    func googleExpiry() throws {
        let url = try #require(URL(
            string: "https://cdn.example.com/r.mp4?X-Goog-Date=20260112T120000Z&X-Goog-Expires=900"
        ))
        let expiry = try #require(RenderURLResolver.presignedExpiry(of: url))
        let signed = try #require(PostHogDate.parse("2026-01-12T12:00:00Z"))
        #expect(abs(expiry.timeIntervalSince(signed) - 900) < 1)
    }

    @Test("has no opinion about a URL that carries no signature")
    func unsignedURL() throws {
        let url = try #require(URL(string: "https://cdn.example.com/render.mp4"))
        #expect(RenderURLResolver.presignedExpiry(of: url) == nil)
    }

    /// An unrecognised expiry counts as unusable. Re-resolving costs one
    /// redirect; guessing wrong costs the viewer a video that dies mid-play.
    @Test("re-resolves rather than trusting a link it cannot date")
    func unknownExpiryIsNotReused() {
        let link = ResolvedRenderURL(url: Self.contentURL, expiresAt: nil)
        #expect(!link.isUsable(asOf: Date()))
    }

    @Test("stops trusting a link before it expires, not after")
    func expiryMargin() {
        let now = Date()
        let link = ResolvedRenderURL(url: Self.contentURL, expiresAt: now.addingTimeInterval(3600))
        #expect(link.isUsable(asOf: now))
        // Thirty seconds left is not enough to start a video with.
        #expect(!link.isUsable(asOf: now.addingTimeInterval(3600 - 30)))
        #expect(!link.isUsable(asOf: now.addingTimeInterval(3601)))
    }

    // MARK: - The redirect itself

    /// The unit-level guarantee: whatever `URLSession` proposes, the answer is no.
    @Test("refuses a redirect even when the proposed request carries the key")
    func delegateRefuses() async throws {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: Self.contentURL)
        defer { task.cancel(); session.invalidateAndCancel() }

        // Shaped the way `URLSession` builds it: the original request's headers,
        // copied onto a request for a completely different host.
        var proposed = URLRequest(url: try #require(URL(string: Self.storageURL)))
        proposed.setValue("Bearer phx_secret", forHTTPHeaderField: "Authorization")

        let answer = await RedirectRefusal().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: Self.response(status: 302),
            newRequest: proposed
        )
        #expect(answer == nil)
    }

    /// End to end, through the real URL loading system.
    ///
    /// The assertion that matters is the count: one request leaves this app, and
    /// it goes to PostHog. The storage host is never contacted at all, so there is
    /// no request for a credential to ride along on.
    @Test("issues exactly one request, to PostHog, and never reaches storage")
    func resolvesWithoutContactingStorage() async throws {
        RedirectStub.log.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        let session = URLSession(
            configuration: configuration,
            delegate: RedirectRefusal(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let resolved = try await RenderURLResolver(session: session).resolve(
            credential: StoredCredential(key: "phx_secret", region: .usCloud),
            projectID: 42,
            exportID: 6_304_294
        )

        #expect(resolved.url.host() == "cdn.example.com")

        let requests = RedirectStub.log.all
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host() == "us.posthog.com")
        // Sent where it belongs, and nowhere else.
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer phx_secret")
        #expect(requests.allSatisfy { $0.url?.host() != "cdn.example.com" })
    }

    /// The control for the test above.
    ///
    /// Same stub, same request, no redirect policy — and the loading system walks
    /// straight onto the storage host, carrying whatever the first request
    /// carried. Without this, "one request" above could be passing because the
    /// stub never redirects at all, and the guarantee would be untested.
    @Test("without the policy, the key would be replayed onto the storage host")
    func defaultSessionLeaksTheCredential() async throws {
        RedirectStub.log.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: Self.contentURL)
        request.setValue("Bearer phx_secret", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)

        let storageRequests = RedirectStub.log.all.filter { $0.url?.host() == "cdn.example.com" }
        #expect(!storageRequests.isEmpty, "the stub must actually redirect, or the guarantee is untested")
        #expect(storageRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer phx_secret")
    }
}

// MARK: - Stub

/// Records every request the URL loading system actually issues.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func reset() { lock.withLock { requests.removeAll() } }
    var all: [URLRequest] { lock.withLock { requests } }
}

/// Answers PostHog's content endpoint with the 302 the real one sends.
///
/// The redirect is signalled through `wasRedirectedTo:` rather than delivered as a
/// plain 302 body, because that is the path that makes the URL loading system ask
/// its delegate what to do — which is the behaviour under test.
///
/// The header copy below models `URLSession`, it does not observe it. On a live
/// redirect the loading system builds the follow-up request from the original and
/// carries `Authorization` across; through a `URLProtocol` it uses the request the
/// protocol hands it verbatim — verified by capturing what the delegate is
/// offered, which is exactly this object. So the harness has to do the copying for
/// the leak to be reproducible at all.
private final class RedirectStub: URLProtocol {
    static let log = RequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.record(request)
        guard let url = request.url else { return }

        if url.host == "cdn.example.com" {
            // Only reachable when a redirect was followed.
            finish(status: 200, headers: ["Content-Type": "video/mp4"], url: url)
            return
        }

        let redirectResponse = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": RenderURLResolverTests.storageURL]
        )!
        var target = URLRequest(url: URL(string: RenderURLResolverTests.storageURL)!)
        target.allHTTPHeaderFields = request.allHTTPHeaderFields
        client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: redirectResponse)
        // Delivered as well, so a refused redirect completes the task with the
        // 302 instead of leaving it hanging on a load that never ends.
        client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func finish(status: Int, headers: [String: String], url: URL) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - What the screen shows

@Suite("Render states")
struct RenderStateTests {

    static let now = PostHogDate.parse("2026-01-12T12:00:00Z")!

    private static func export(_ json: String) throws -> RecordingExport {
        try JSONDecoder().decode(RecordingExport.self, from: Data(json.utf8))
    }

    /// The distinction the screen is built around. A failed render never becomes
    /// playable and an expired one was never broken, so they must not arrive at
    /// the same glyph, the same tint, or the same offer.
    @Test("keeps failed and expired apart in every encoding the row uses")
    func failedAndExpiredAreDistinct() {
        let failed = RecordingExportState.failed(reason: "RuntimeError: render timed out")
        let expired = RecordingExportState.expired

        #expect(failed.glyph != expired.glyph)
        #expect(failed.tint != expired.tint)
        #expect(!failed.isPlayable)
        #expect(!expired.isPlayable)
    }

    @Test("offers playback for exactly one state")
    func onlyReadyIsPlayable() {
        #expect(RecordingExportState.ready.isPlayable)
        #expect(!RecordingExportState.pending.isPlayable)
        #expect(!RecordingExportState.failed(reason: "boom").isPlayable)
        #expect(!RecordingExportState.expired.isPlayable)
    }

    /// Each glyph is its own, so a row is recognisable before its pill is read —
    /// which is what "never colour alone" means on a list this long.
    @Test("gives every state a glyph of its own")
    func glyphsAreUnique() {
        let glyphs = [
            RecordingExportState.ready,
            .pending,
            .failed(reason: "boom"),
            .expired,
        ].map(\.glyph)
        #expect(Set(glyphs).count == glyphs.count)
    }

    /// A symbol name with a typo in it renders as nothing at all — no build
    /// error, no runtime crash, just a row whose second encoding of its state has
    /// quietly vanished. That is the one failure mode of "never colour alone"
    /// that nobody notices until a screenshot.
    @Test("every symbol this screen names actually resolves")
    func symbolsResolve() {
        let symbols = [
            RecordingExportState.ready,
            .pending,
            .failed(reason: "boom"),
            .expired,
        ].map(\.glyph) + [
            AppTab.renders.systemImage,
            "film", "play.rectangle", "hourglass", "waveform.path.ecg",
            "forward.end.alt", "wifi.exclamationmark",
            "rectangle.stack", "rectangle.stack.badge.minus",
            "line.3.horizontal.decrease.circle", "arrow.up.forward.square",
        ]
        for symbol in symbols {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol) is not an SF Symbol")
        }
    }

    @Test("filters by the state a render is actually in")
    func filterMatchesState() throws {
        let ready = try Self.export("""
            {"id": 1, "export_format": "video/mp4", "has_content": true,
             "expires_after": "2026-01-13T12:00:00Z"}
            """)
        let expired = try Self.export("""
            {"id": 2, "export_format": "video/mp4", "has_content": true,
             "expires_after": "2026-01-11T12:00:00Z"}
            """)
        let failed = try Self.export("""
            {"id": 3, "export_format": "video/mp4", "has_content": false,
             "exception": "RuntimeError: Playwright render timed out after 300s"}
            """)
        let pending = try Self.export("""
            {"id": 4, "export_format": "video/mp4", "has_content": false}
            """)

        let states = [ready, expired, failed, pending].map { $0.state(asOf: Self.now) }

        #expect(states.filter { RenderFilter.ready.matches($0) }.count == 1)
        #expect(states.filter { RenderFilter.expired.matches($0) }.count == 1)
        #expect(states.filter { RenderFilter.failed.matches($0) }.count == 1)
        #expect(states.filter { RenderFilter.rendering.matches($0) }.count == 1)
        #expect(states.filter { RenderFilter.all.matches($0) }.count == 4)
    }
}

@Suite("Synthetic replay playback")
struct RenderPlaybackTests {
    @Test("the demo recording boots from the canonical synthetic timeline")
    @MainActor
    func syntheticReplayBoots() async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
        let page: Page<SessionRecording> = try await client.send(
            PostHogAPI.sessionRecordings(projectID: 1_001)
        )
        let recording = try #require(
            page.results.first { $0.id == "018f1000-0000-7000-8000-000000000001" }
        )

        let loader = ReplayLoader()
        await loader.start(client: client, projectID: 1_001, recording: recording)

        #expect(loader.availability == .ready)
        #expect(loader.canBoot)
        #expect(loader.pendingCount == 7)
        #expect(loader.replayStart == Date(timeIntervalSince1970: 1_768_478_400))
    }
}
