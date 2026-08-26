import Foundation
import GetHogKit
import Testing

@testable import GetHog

extension ReplayVisionSummaryStore {
    private static let syntheticAuthority = ResourceRequestAuthority(
        projectID: 1_001,
        region: PostHogRegion.usCloud,
        authSessionID: UUID(uuidString: "018f9000-0000-7000-8000-000000000600")!
    )

    func load(client: PostHogClient, projectID: Int, sessionID: String) async {
        await load(
            client: client,
            authority: Self.authority(projectID: projectID, client: client),
            sessionID: sessionID
        )
    }

    func generate(client: PostHogClient, projectID: Int, sessionID: String) async {
        await generate(
            client: client,
            authority: Self.authority(projectID: projectID, client: client),
            sessionID: sessionID
        )
    }

    func retry(client: PostHogClient, projectID: Int, sessionID: String) async {
        await retry(
            client: client,
            authority: Self.authority(projectID: projectID, client: client),
            sessionID: sessionID
        )
    }

    private static func authority(
        projectID: Int,
        client: PostHogClient
    ) -> ResourceRequestAuthority {
        .init(
            projectID: projectID,
            region: client.region,
            authSessionID: syntheticAuthority.authSessionID
        )
    }
}

private actor ReplayVisionSummaryTransport: HTTPTransport {
    enum Mode {
        case absent
        case loaded
        case generation
        case forbidden
        case quota
        case retry
    }

    private let mode: Mode
    private var observationReads = 0
    private(set) var paths: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func requestedPaths() -> [String] { paths }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        paths.append(path)

        if path.hasSuffix("/vision/scanners/inline_scan/") {
            switch mode {
            case .forbidden:
                return reply(
                    request,
                    status: 403,
                    json: #"{"detail":"Your personal API key is missing the replay_scanner:write scope."}"#
                )
            case .quota:
                return reply(
                    request,
                    status: 202,
                    json: #"{"scan_id":null,"started":0,"results":[{"session_id":"session-example-001","scan_outcome":"skipped_quota"}]}"#
                )
            default:
                return reply(
                    request,
                    status: 202,
                    json: #"{"scan_id":"scanner-example-001","started":1,"results":[{"session_id":"session-example-001","scan_outcome":"started"}]}"#
                )
            }
        }

        if path.hasSuffix("/observation-example-failed/retry/") {
            return reply(
                request,
                status: 202,
                json: #"{"workflow_id":"replay-vision-retry-example"}"#
            )
        }

        if path.hasSuffix("/observations/") {
            observationReads += 1
            switch mode {
            case .absent, .forbidden, .quota:
                return reply(request, json: Self.page([]))
            case .loaded:
                return reply(request, json: Self.page([Self.succeeded]))
            case .generation:
                if observationReads == 1 {
                    return reply(request, json: Self.page([]))
                }
                if observationReads == 2 {
                    return reply(request, json: Self.page([Self.pending]))
                }
                return reply(request, json: Self.page([Self.succeeded]))
            case .retry:
                if observationReads == 1 {
                    return reply(request, json: Self.page([Self.failed]))
                }
                return reply(request, json: Self.page([Self.succeeded]))
            }
        }

        return reply(request, status: 404, json: #"{"detail":"Unexpected synthetic route"}"#)
    }

    private func reply(
        _ request: URLRequest,
        status: Int = 200,
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

    private static func page(_ observations: [String]) -> String {
        "{\"count\":\(observations.count),\"next\":null,\"previous\":null,\"results\":[\(observations.joined(separator: ","))]}"
    }

    private static let snapshot = #"""
    "scanner_snapshot": {
      "name": "",
      "scanner_type": "summarizer",
      "scanner_version": 1,
      "model": "gemini-3-flash-preview",
      "provider": "google",
      "emits_signals": false,
      "scanner_config": {"prompt":"Synthetic prompt","length":"medium"}
    }
    """#

    private static let pending = """
    {"id":"observation-example-pending","scanner_id":"scanner-example-001","session_id":"session-example-001","status":"pending","error_reason":"","workflow_id":"workflow-example",\(snapshot),"scanner_result":null,"started_at":null,"completed_at":null,"created_at":"2026-08-26T10:00:00Z"}
    """

    private static let failed = """
    {"id":"observation-example-failed","scanner_id":"scanner-example-001","session_id":"session-example-001","status":"failed","error_reason":"Synthetic replay was too short",\(snapshot),"scanner_result":null,"started_at":"2026-08-26T10:00:00Z","completed_at":"2026-08-26T10:00:03Z","created_at":"2026-08-26T10:00:00Z"}
    """

    private static let succeeded = """
    {"id":"observation-example-succeeded","scanner_id":"scanner-example-001","session_id":"session-example-001","status":"succeeded","error_reason":"",\(snapshot),"scanner_result":{"model_output":{"scanner_type":"summarizer","title":"Reviewed the fictional dashboard","summary":"The user opened the dashboard and refreshed its widgets.","summary_segments":[{"kind":"text","value":"Opened the dashboard "},{"kind":"chip","timestamp_ms":4200}],"intent":"Review current dashboard metrics.","outcome":"The widgets refreshed successfully.","friction_points":["slow widget refresh"],"keywords":["dashboard","refreshed"],"confidence":0.9},"signals_count":0},"started_at":"2026-08-26T10:00:00Z","completed_at":"2026-08-26T10:00:12Z","created_at":"2026-08-26T10:00:00Z"}
    """
}

@MainActor
@Suite("Replay Vision summary store")
struct ReplayVisionSummaryStoreTests {
    private func client(_ transport: ReplayVisionSummaryTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )
    }

    private func store() -> ReplayVisionSummaryStore {
        ReplayVisionSummaryStore(pollDelay: {})
    }

    @Test("a session without a summarizer observation is absent")
    func absent() async {
        let transport = ReplayVisionSummaryTransport(mode: .absent)
        let store = store()

        await store.load(
            client: client(transport),
            projectID: 1_001,
            sessionID: "session-example-001"
        )

        #expect(store.state == .absent)
        #expect(store.summary == nil)
        #expect(store.loadedAt != nil)
    }

    @Test("a succeeded summarizer observation exposes its generated summary")
    func loadsSucceededObservation() async throws {
        let transport = ReplayVisionSummaryTransport(mode: .loaded)
        let store = store()

        await store.load(
            client: client(transport),
            projectID: 1_001,
            sessionID: "session-example-001"
        )

        #expect(store.summary?.title == "Reviewed the fictional dashboard")
        #expect(store.summary?.hasFriction == true)
        #expect(store.observation?.status == .succeeded)
    }

    @Test("a credential replacement clears loaded summary evidence before suspension")
    func authorityReplacementClearsSummary() async {
        let transport = ReplayVisionSummaryTransport(mode: .loaded)
        let store = store()

        await store.load(
            client: client(transport),
            projectID: 1_001,
            sessionID: "session-example-001"
        )
        #expect(store.summary != nil)

        store.prepare(authority: ResourceRequestAuthority(
            projectID: 1_001,
            region: .usCloud,
            authSessionID: UUID(uuidString: "018f9000-0000-7000-8000-000000000601")!
        ))

        #expect(store.state == .idle)
        #expect(store.observation == nil)
        #expect(store.summary == nil)
        #expect(store.loadedAt == nil)
    }

    @Test("generation posts only to Replay Vision and polls through pending to success")
    func generatesAndPolls() async {
        let transport = ReplayVisionSummaryTransport(mode: .generation)
        let store = store()
        let client = client(transport)

        await store.load(
            client: client,
            projectID: 1_001,
            sessionID: "session-example-001"
        )
        #expect(store.state == .absent)

        await store.generate(
            client: client,
            projectID: 1_001,
            sessionID: "session-example-001"
        )

        #expect(store.summary?.title == "Reviewed the fictional dashboard")
        let paths = await transport.requestedPaths()
        #expect(paths.contains { $0.hasSuffix("/vision/scanners/inline_scan/") })
        #expect(
            paths.contains {
                $0.hasSuffix("/vision/scanners/scanner-example-001/observations/")
            }
        )
        #expect(paths.allSatisfy { !$0.contains("session_summaries") })
        #expect(paths.allSatisfy { !$0.contains("single_session_summaries") })
    }

    @Test("a PAT missing Replay Vision write scope gets actionable guidance")
    func missingScopeGuidance() async {
        let transport = ReplayVisionSummaryTransport(mode: .forbidden)
        let store = store()

        await store.generate(
            client: client(transport),
            projectID: 1_001,
            sessionID: "session-example-001"
        )

        guard case .generationFailed(let message) = store.state else {
            Issue.record("Expected a generation-specific error")
            return
        }
        #expect(message.contains("replay_scanner:write"))
        #expect(message.contains("session_recording:read"))
        #expect(message.localizedCaseInsensitiveContains("personal API key"))
    }

    @Test("a quota-skipped inline scan reports the quota instead of polling forever")
    func quotaSkip() async {
        let transport = ReplayVisionSummaryTransport(mode: .quota)
        let store = store()

        await store.generate(
            client: client(transport),
            projectID: 1_001,
            sessionID: "session-example-001"
        )

        guard case .generationFailed(let message) = store.state else {
            Issue.record("Expected a generation-specific error")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("quota"))
    }

    @Test("failed observations retry on the current route and load the replacement")
    func retriesFailedObservation() async {
        let transport = ReplayVisionSummaryTransport(mode: .retry)
        let store = store()
        let client = client(transport)

        await store.load(
            client: client,
            projectID: 1_001,
            sessionID: "session-example-001"
        )
        #expect(store.observation?.status == .failed)

        await store.retry(
            client: client,
            projectID: 1_001,
            sessionID: "session-example-001"
        )

        #expect(store.observation?.status == .succeeded)
        #expect(store.summary?.title == "Reviewed the fictional dashboard")
        let paths = await transport.requestedPaths()
        #expect(paths.contains { $0.hasSuffix("/observation-example-failed/retry/") })
        #expect(
            paths.contains {
                $0.hasSuffix("/vision/scanners/scanner-example-001/observations/")
            }
        )
    }
}
