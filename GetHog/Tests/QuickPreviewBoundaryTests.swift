import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// A real-client request recorder shared by Quick Preview lifecycle boundaries.
/// Later metadata-only preview tasks can mount their preview lifecycle against
/// the same zero-default harness and prove that no request was emitted.
private actor QuickPreviewRequestRecorder: HTTPTransport {
    private let response: Data
    private var requests: [URLRequest] = []

    init(response: Data = Data()) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            response,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func recordedRequests() -> [URLRequest] { requests }
}

@Suite("Quick Preview request boundaries")
@MainActor
struct QuickPreviewBoundaryTests {
    @Test("insight activation emits one cached detail request and nothing else")
    func insightUsesOnlyCachedDetailRequest() async throws {
        let recorder = QuickPreviewRequestRecorder(response: Self.cachedInsight)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: recorder
        )
        let store = InsightQuickPreviewStore()
        let scope = InsightPreviewScope(
            authority: ResourceRequestAuthority(
                projectID: 1_001,
                region: .usCloud,
                authSessionID: UUID(
                    uuidString: "018F9000-0000-7000-8000-000000000720"
                )!
            ),
            insightID: 7_201
        )

        await store.activate(client: client, scope: scope)

        let requests = await recorder.recordedRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/projects/1001/insights/7201")
        #expect(
            URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                .queryItems == [URLQueryItem(name: "refresh", value: "force_cache")]
        )
        #expect(
            requests.allSatisfy { request in
                let components = request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)
                }
                let refresh = components?.queryItems?
                    .first(where: { $0.name == "refresh" })?.value
                return request.url?.path.hasSuffix("/query") != true
                    && refresh != "blocking"
                    && refresh != "lazy_async"
            }
        )
    }

    private static let cachedInsight = Data(
        #"""
        {
          "id": 7201,
          "name": "Synthetic cached preview",
          "is_cached": true,
          "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
          "result": [{"label":"Synthetic series","count":7,"data":[7],"days":["2026-08-26"]}]
        }
        """#.utf8
    )
}
