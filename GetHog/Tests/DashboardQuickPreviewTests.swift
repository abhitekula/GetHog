import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Dashboard Quick Preview")
struct DashboardQuickPreviewTests {
    @Test
    func baseNeverInventsATileCount() throws {
        let summary = try Self.summary()

        let presentation = DashboardQuickPreviewPresentation(
            summary: summary,
            enriched: nil
        )

        #expect(
            presentation == DashboardQuickPreviewPresentation(
                title: "Synthetic launch health",
                description: "Signals for a fictional product.",
                stateText: "Pinned · Template",
                lastRefresh: Self.lastRefresh,
                tileCount: nil,
                tiles: []
            )
        )
    }

    @Test
    func enrichedContentCountsEveryTileButSummarisesAtMostThree() throws {
        let summary = try Self.summary()
        let dashboard = try Dashboard.decode(from: Data(Self.orderedDashboard.utf8))

        let presentation = DashboardQuickPreviewPresentation(
            summary: summary,
            enriched: dashboard
        )

        #expect(
            presentation == DashboardQuickPreviewPresentation(
                title: "Synthetic launch health",
                description: "Signals for a fictional product.",
                stateText: "Pinned · Template",
                lastRefresh: Self.lastRefresh,
                tileCount: 5,
                tiles: [
                    .init(title: "Synthetic signups", detail: "42"),
                    .init(title: "Synthetic activity", detail: "7"),
                    .init(title: "Synthetic retention", detail: "Retention"),
                ]
            )
        )
    }

    @Test
    func unknownAndInteractiveTilesAreCountedButNotRenderedAsResults() throws {
        let summary = try Self.summary()
        let dashboard = try Dashboard.decode(from: Data(Self.mixedDashboard.utf8))

        let presentation = DashboardQuickPreviewPresentation(
            summary: summary,
            enriched: dashboard
        )

        #expect(
            presentation == DashboardQuickPreviewPresentation(
                title: "Synthetic launch health",
                description: "Signals for a fictional product.",
                stateText: "Pinned · Template",
                lastRefresh: Self.lastRefresh,
                tileCount: 5,
                tiles: [
                    .init(title: "Synthetic trend", detail: "Trends"),
                ]
            )
        )
    }

    @Test
    func accessibilitySummaryStatesPinnedTemplateAndFreshness() throws {
        let summary = try Self.summary()
        let dashboard = try Dashboard.decode(from: Data(Self.mixedDashboard.utf8))
        let presentation = DashboardQuickPreviewPresentation(
            summary: summary,
            enriched: dashboard
        )

        #expect(
            presentation.accessibilitySummary
                == "Synthetic launch health. Signals for a fictional product. Pinned, template. Updated Aug 26, 2026. 5 tiles. Synthetic trend, Trends."
        )
    }

    private static let lastRefresh = Date(timeIntervalSince1970: 1_787_738_400)

    private static func summary() throws -> DashboardSummary {
        try JSONDecoder().decode(
            DashboardSummary.self,
            from: Data(
                #"{"id":720100,"name":"Synthetic launch health","description":"Signals for a fictional product.","pinned":true,"last_refresh":"2026-08-26T10:00:00Z","creation_mode":"template"}"#.utf8
            )
        )
    }

    private static let orderedDashboard = #"""
    {
      "id": 720100,
      "name": "Synthetic launch health",
      "tiles": [
        {
          "id": 720105,
          "order": 50,
          "text": {"body": "Synthetic note"}
        },
        {
          "id": 720103,
          "order": 30,
          "insight": {
            "id": 721003,
            "name": "Synthetic retention",
            "query": {"kind":"InsightVizNode","source":{"kind":"RetentionQuery"}},
            "result": []
          }
        },
        {
          "id": 720101,
          "order": 10,
          "insight": {
            "id": 721001,
            "name": "Synthetic signups",
            "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery","trendsFilter":{"display":"BoldNumber"}}},
            "result": [{"label":"Synthetic signups","aggregated_value":42,"data":[],"days":[]}]
          }
        },
        {
          "id": 720104,
          "order": 40,
          "insight": {
            "id": 721004,
            "name": "Synthetic paths",
            "query": {"kind":"InsightVizNode","source":{"kind":"PathsQuery"}},
            "result": []
          }
        },
        {
          "id": 720102,
          "order": 20,
          "insight": {
            "id": 721002,
            "name": "Synthetic activity",
            "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
            "result": [{"label":"Synthetic activity","count":7,"data":[3,7],"days":["2026-04-25","2026-04-26"]}]
          }
        }
      ]
    }
    """#

    private static let mixedDashboard = #"""
    {
      "id": 720100,
      "name": "Synthetic launch health",
      "tiles": [
        {"id":720201,"order":1,"text":{"body":"Synthetic note"}},
        {"id":720202,"order":2,"button_tile":{"text":"Synthetic button"}},
        {"id":720203,"order":3,"widget":{"key":"synthetic-widget"}},
        {"id":720204,"order":4,"future_tile":{"kind":"synthetic-future"}},
        {
          "id": 720205,
          "order": 5,
          "insight": {
            "id": 721005,
            "name": "Synthetic trend",
            "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
            "result": []
          }
        }
      ]
    }
    """#
}
