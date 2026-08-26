import Foundation
import GetHogKit
import Testing

@testable import GetHog

private actor SessionsSummaryEnrichmentTransport: HTTPTransport {
    enum SummaryReply {
        case success
        case failure
    }

    private let summaryReply: SummaryReply
    private let demo = DemoTransport()
    private var summaryQueryCount = 0

    init(summaryReply: SummaryReply) {
        self.summaryReply = summaryReply
    }

    func queryCount() -> Int { summaryQueryCount }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        if path.hasSuffix("/query/"), request.httpMethod == "POST" {
            let body = request.httpBody ?? Data()
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let sql = (json?["query"] as? [String: Any])?["query"] as? String ?? ""
            if sql.contains("$recording_observed") {
                summaryQueryCount += 1
                switch summaryReply {
                case .success:
                    return reply(
                        request,
                        status: 200,
                        json: #"{"columns":["session_id","title","summary","intent","outcome","friction_points","confidence","model","completed_at"],"results":[["018f1000-0000-7000-8000-000000000001","Reviewed the fictional dashboard","The user opened the dashboard and refreshed its widgets.","Review current dashboard metrics.","The widgets refreshed successfully.","[\"slow widget refresh\"]",0.9,"gemini-3-flash-preview","2026-08-26T10:00:12Z"]]}"#
                    )
                case .failure:
                    return reply(
                        request,
                        status: 503,
                        json: #"{"detail":"Synthetic enrichment outage"}"#
                    )
                }
            }
        }
        return try await demo.send(request)
    }

    private func reply(
        _ request: URLRequest,
        status: Int,
        json: String
    ) -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private actor RefreshingSessionsSummaryTransport: HTTPTransport {
    private let demo = DemoTransport()
    private var summaryQueryCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        if path.hasSuffix("/query/"), request.httpMethod == "POST" {
            let body = request.httpBody ?? Data()
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let sql = (json?["query"] as? [String: Any])?["query"] as? String ?? ""
            if sql.contains("$recording_observed") {
                summaryQueryCount += 1
                if summaryQueryCount == 1 {
                    return reply(
                        request,
                        status: 200,
                        json: #"{"columns":["session_id","title","summary","intent","outcome","friction_points","confidence","model","completed_at"],"results":[["018f1000-0000-7000-8000-000000000001","Reviewed the fictional dashboard","The user opened the dashboard and refreshed its widgets.","Review current dashboard metrics.","The widgets refreshed successfully.","[\"slow widget refresh\"]",0.9,"gemini-3-flash-preview","2026-08-26T10:00:12Z"]]}"#
                    )
                }
                return reply(
                    request,
                    status: 503,
                    json: #"{"detail":"Synthetic enrichment outage"}"#
                )
            }
        }
        return try await demo.send(request)
    }

    private func reply(
        _ request: URLRequest,
        status: Int,
        json: String
    ) -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private actor ScopedSummaryListTransport: HTTPTransport {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 1 {
            return reply(
                request,
                status: 200,
                json: #"{"columns":["session_id","title","summary","intent","outcome","friction_points","confidence","model","completed_at"],"results":[["018f1000-0000-7000-8000-000000000001","Example dashboard","A synthetic dashboard summary.","","","[]",0.9,null,"2026-08-26T10:00:12Z"]]}"#
            )
        }
        return reply(
            request,
            status: 503,
            json: #"{"detail":"Synthetic replacement outage"}"#
        )
    }

    private func reply(
        _ request: URLRequest,
        status: Int,
        json: String
    ) -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

@MainActor
@Suite("Sessions summary enrichment")
struct SessionsSummaryEnrichmentTests {
    private func client(_ transport: SessionsSummaryEnrichmentTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )
    }

    @Test("one query enriches a loaded recordings page with summaries and friction")
    func batchEnrichment() async throws {
        let transport = SessionsSummaryEnrichmentTransport(summaryReply: .success)
        let store = SessionsStore()

        await store.load(client: client(transport), projectID: 1_001)

        #expect(store.recordings.count == 5)
        let digest = try #require(
            store.summary(for: "018f1000-0000-7000-8000-000000000001")
        )
        #expect(
            digest.cardSummary
                == "The user opened the dashboard and refreshed its widgets."
        )
        #expect(digest.hasFriction)
        #expect(await transport.queryCount() == 1)

        let recording = try #require(store.recordings.first)
        let presentation = SessionRowPresentation(
            recording: recording,
            summary: digest
        )
        #expect(
            presentation.summaryLine
                == "The user opened the dashboard and refreshed its widgets."
        )
        #expect(presentation.accessibilityDescription.contains("Replay Vision friction"))
        #expect(!presentation.accessibilityDescription.contains("AI summary"))
    }

    @Test("an optional enrichment failure keeps valid recordings and no list error")
    func enrichmentFailureDoesNotFailRecordings() async {
        let transport = SessionsSummaryEnrichmentTransport(summaryReply: .failure)
        let store = SessionsStore()

        await store.load(client: client(transport), projectID: 1_001)

        #expect(store.recordings.count == 5)
        #expect(store.error == nil)
        #expect(store.summariesBySessionID.isEmpty)
        #expect(await transport.queryCount() == 1)
    }

    @Test("a failed replacement enrichment removes stale summaries and friction")
    func replacementEnrichmentFailureDoesNotRetainStaleCards() async {
        let transport = RefreshingSessionsSummaryTransport()
        let store = SessionsStore()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )

        await store.load(client: client, projectID: 1_001)
        #expect(!store.summariesBySessionID.isEmpty)

        await store.load(client: client, projectID: 1_001)

        #expect(store.recordings.count == 5)
        #expect(store.error == nil)
        #expect(store.summariesBySessionID.isEmpty)
    }

    @Test("a credential replacement immediately retires sessions from the old epoch")
    func credentialEpochReplacementClearsSessions() async {
        let transport = SessionsSummaryEnrichmentTransport(summaryReply: .success)
        let store = SessionsStore()

        await store.load(client: client(transport), projectID: 1_001)
        #expect(!store.recordings.isEmpty)
        #expect(!store.summariesBySessionID.isEmpty)

        store.prepare(authority: ResourceRequestAuthority(
            projectID: 1_001,
            region: .usCloud,
            authSessionID: UUID(uuidString: "018f9000-0000-7000-8000-000000000601")!
        ))

        #expect(store.recordings.isEmpty)
        #expect(store.summariesBySessionID.isEmpty)
        #expect(store.loadedAt == nil)
    }

    @Test("a completed detail summary immediately enriches its session card")
    func completedDetailSummaryPublishesToList() async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: DemoTransport()
        )
        let detail = ReplayVisionSummaryStore(pollDelay: {})
        await detail.load(
            client: client,
            projectID: 1_001,
            sessionID: "018f1000-0000-7000-8000-000000000001"
        )
        let observation = try #require(detail.observation)
        let store = SessionsStore()
        let authority = ResourceRequestAuthority(
            projectID: 1_001,
            region: .usCloud,
            authSessionID: UUID(uuidString: "018f9000-0000-7000-8000-000000000602")!
        )
        store.prepare(authority: authority)

        store.publish(summary: observation, authority: authority)

        let digest = try #require(
            store.summary(for: "018f1000-0000-7000-8000-000000000001")
        )
        #expect(
            digest.cardSummary
                == "The user opened the orbital dashboard, compared telemetry, and refreshed a slow status widget before finishing the review."
        )
        #expect(digest.hasFriction)

        let olderResponse = try QueryResponse.decode(from: Data(#"{"columns":["session_id","title","summary","intent","outcome","friction_points","confidence","model","completed_at"],"results":[["018f1000-0000-7000-8000-000000000001","Older synthetic summary","An older synthetic summary.","","","[]",0.8,null,"2026-01-17T10:00:12Z"]]}"#.utf8))
        let older = try #require(ReplayVisionSummaryDigest.rows(from: olderResponse).first)

        store.mergeSummaries([older])

        #expect(
            store.summary(for: "018f1000-0000-7000-8000-000000000001")?.cardSummary
                == "The user opened the orbital dashboard, compared telemetry, and refreshed a slow status widget before finishing the review."
        )
    }

    @Test("a failed credential replacement cannot display another authority's summaries")
    func summaryListClearsAcrossCredentialAuthority() async {
        let transport = ScopedSummaryListTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )
        let store = SessionSummariesStore()

        await store.load(
            client: client,
            authority: ResourceRequestAuthority(
                projectID: 1_001,
                region: .usCloud,
                authSessionID: UUID(uuidString: "018f9000-0000-7000-8000-000000000601")!
            )
        )
        #expect(store.rows.map(\.id) == ["018f1000-0000-7000-8000-000000000001"])

        await store.load(
            client: client,
            authority: ResourceRequestAuthority(
                projectID: 1_001,
                region: .usCloud,
                authSessionID: UUID(uuidString: "018f9000-0000-7000-8000-000000000602")!
            )
        )

        #expect(store.rows.isEmpty)
        #expect(store.error != nil)
    }

    @Test("session glyphs give console errors priority over Replay Vision friction")
    func sessionSignalPriority() {
        #expect(
            SessionBrandAppearance.glyph(
                hasErrors: true,
                isReplayable: true,
                hasFriction: true
            ) == .errorSession
        )
        #expect(
            SessionBrandAppearance.glyph(
                hasErrors: false,
                isReplayable: true,
                hasFriction: true
            ) == .frictionSession
        )
        #expect(
            SessionBrandAppearance.glyph(
                hasErrors: false,
                isReplayable: true,
                hasFriction: false
            ) == .session
        )
    }
}
