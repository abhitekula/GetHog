import Foundation
import GetHogKit
import Testing

@testable import GetHog

private actor DashboardRangeTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        let body = """
        {"results": [{"label": "Synthetic events", "count": 3,
          "data": [1, 2], "days": ["2026-02-01", "2026-02-02"]}]}
        """
        return (Data(body.utf8), response)
    }
}

@Suite("HogQL dashboard integration")
@MainActor
struct HogQLDashboardIntegrationTests {
    @Test("dashboard range overrides skip HogQL and count only eligible insight requests")
    func rangeOverridesSkipHogQL() async throws {
        let dashboard = try Dashboard.decode(from: Data(Self.dashboardJSON.utf8))
        let store = DashboardDetailStore()
        store.dashboard = dashboard
        let transport = DashboardRangeTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: transport
        )

        await store.apply(range: .week, compare: false, client: client, projectID: 1)

        #expect(await transport.requests.count == 1)
        #expect(store.overrides.keys.sorted() == [720101])
        #expect(store.rangeError == nil)
        #expect(store.rangeNotice == "1 HogQL insight keeps its saved result because dashboard ranges do not rewrite SQL.")
    }

    @Test("text tiles present as noninteractive notes without freshness or insight export")
    func textTilePresentationIsIndependent() throws {
        let dashboard = try Dashboard.decode(from: Data(Self.dashboardJSON.utf8))
        let tile = try #require(dashboard.tiles.first(where: { $0.id == 720103 }))
        let presentation = TileCardPresentation(tile: tile)

        #expect(presentation.kind == .note("A fictional launch annotation."))
        #expect(!presentation.opensInsight)
        #expect(!presentation.showsFreshness)
        #expect(!presentation.exportsInsight)
    }

    private static let dashboardJSON = """
    {
      "id": 720100,
      "name": "Synthetic operations",
      "tiles": [
        {
          "id": 720101,
          "insight": {
            "id": 720201,
            "name": "Synthetic trend",
            "query": {"kind": "InsightVizNode", "source": {
              "kind": "TrendsQuery", "series": [], "dateRange": {"date_from": "-30d"}
            }},
            "result": [{"label": "Synthetic events", "count": 3,
              "data": [1, 2], "days": ["2026-02-01", "2026-02-02"]}]
          }
        },
        {
          "id": 720102,
          "insight": {
            "id": 720202,
            "name": "Synthetic SQL table",
            "query": {"kind": "DataVisualizationNode", "display": "ActionsTable",
              "source": {"kind": "HogQLQuery", "query": "SELECT value FROM synthetic_metrics"}},
            "columns": ["value"], "types": [["value", "UInt64"]], "result": [[4]]
          }
        },
        {
          "id": 720103,
          "text": {"body": "A fictional launch annotation."},
          "insight": null,
          "last_refresh": null
        }
      ]
    }
    """
}
