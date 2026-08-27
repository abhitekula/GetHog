import Foundation
import GetHogKit
import SwiftUI
import Testing
import UIKit

@testable import GetHog

@Suite("Quick Preview rendering")
@MainActor
struct QuickPreviewRenderingTests {
    @Test("Dashboard and Insight states render at requested widths in both appearances")
    func dashboardAndInsightStatesRenderAtRequestedWidthsInBothAppearances() throws {
        let dashboardSummary = try Self.dashboardSummary()
        let dashboard = try Dashboard.decode(from: Data(Self.dashboardJSON.utf8))
        let insightSummary = try Self.insight(Self.insightSummaryJSON)
        let insight = try Self.insight(Self.insightLoadedJSON)
        let loadedAt = Date(timeIntervalSince1970: 1_787_738_400)

        let dashboardStates: [(String, QuickPreviewEnrichment<Dashboard>)] = [
            ("loading", .loading()),
            ("loaded", .loaded(dashboard, loadedAt: loadedAt)),
            ("unavailable", .unavailable),
            ("stale", .stale(dashboard, loadedAt: loadedAt)),
        ]
        let insightStates: [(String, QuickPreviewEnrichment<Insight>)] = [
            ("loading", .loading()),
            ("loaded", .loaded(insight, loadedAt: loadedAt)),
            ("unavailable", .unavailable),
            ("stale", .stale(insight, loadedAt: loadedAt)),
        ]

        for width in [CGFloat(320), 520] {
            for scheme in [ColorScheme.light, .dark] {
                for (stateName, state) in dashboardStates {
                    let image = try Self.render(
                        DashboardQuickPreview(summary: dashboardSummary, state: state),
                        width: width,
                        scheme: scheme,
                        dynamicTypeSize: .accessibility5
                    )
                    #expect(
                        abs(image.size.width - width) < 0.5,
                        "Dashboard \(stateName) rendered \(image.size.width)pt at \(width)pt."
                    )
                    #expect(image.size.height > 0)
                }

                for (stateName, state) in insightStates {
                    let image = try Self.render(
                        InsightQuickPreview(summary: insightSummary, state: state),
                        width: width,
                        scheme: scheme,
                        dynamicTypeSize: .accessibility5
                    )
                    #expect(
                        abs(image.size.width - width) < 0.5,
                        "Insight \(stateName) rendered \(image.size.width)pt at \(width)pt."
                    )
                    #expect(image.size.height > 0)
                }
            }
        }
    }

    @Test("Accessibility facts stack taller than ordinary type")
    func accessibilityFactsStackTallerThanOrdinaryType() throws {
        let loadedAt = Date(timeIntervalSince1970: 1_787_738_400)
        let dashboard = try Dashboard.decode(from: Data(Self.dashboardJSON.utf8))
        let dashboardView = DashboardQuickPreview(
            summary: try Self.dashboardSummary(),
            state: .loaded(dashboard, loadedAt: loadedAt)
        )
        let insight = try Self.insight(Self.insightLoadedJSON)
        let insightView = InsightQuickPreview(
            summary: try Self.insight(Self.insightSummaryJSON),
            state: .loaded(insight, loadedAt: loadedAt)
        )

        let ordinaryDashboard = try Self.render(
            dashboardView,
            width: 320,
            scheme: .light,
            dynamicTypeSize: .large
        )
        let accessibleDashboard = try Self.render(
            dashboardView,
            width: 320,
            scheme: .light,
            dynamicTypeSize: .accessibility5
        )
        #expect(accessibleDashboard.size.height > ordinaryDashboard.size.height)

        let ordinaryInsight = try Self.render(
            insightView,
            width: 320,
            scheme: .light,
            dynamicTypeSize: .large
        )
        let accessibleInsight = try Self.render(
            insightView,
            width: 320,
            scheme: .light,
            dynamicTypeSize: .accessibility5
        )
        #expect(accessibleInsight.size.height > ordinaryInsight.size.height)
    }

    @Test("Metadata-only cards render long synthetic content at compact and regular widths")
    func metadataOnlyCardsRenderLongSyntheticContent() throws {
        let cards: [(String, AnyView)] = [
            ("event", AnyView(EventQuickPreview(row: try Self.event()))),
            ("session", AnyView(SessionQuickPreview(
                recording: try Self.mobileSession(),
                digest: try Self.digest()
            ))),
            ("flag", AnyView(FlagQuickPreview(flag: try Self.flag()))),
            ("error", AnyView(ErrorQuickPreview(issue: try Self.issue()))),
            ("trace", AnyView(TraceQuickPreview(trace: try Self.trace()))),
        ]

        for width in [CGFloat(320), 520] {
            for scheme in [ColorScheme.light, .dark] {
                for (name, card) in cards {
                    let image = try Self.render(
                        card,
                        width: width,
                        scheme: scheme,
                        dynamicTypeSize: .accessibility5
                    )
                    #expect(
                        abs(image.size.width - width) < 0.5,
                        "\(name) rendered \(image.size.width)pt at \(width)pt."
                    )
                    #expect(image.size.height > 0)
                }
            }
        }
    }

    private static func render<Content: View>(
        _ content: Content,
        width: CGFloat,
        scheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize
    ) throws -> UIImage {
        let renderer = ImageRenderer(
            content: content
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.uiImage, "Quick Preview produced no rendered image.")
    }

    private static func dashboardSummary() throws -> DashboardSummary {
        try JSONDecoder().decode(
            DashboardSummary.self,
            from: Data(
                #"{"id":720100,"name":"Synthetic launch health across every observatory and portable display","description":"Long fictional dashboard context that must wrap without clipping at compact and regular preview widths.","pinned":true,"last_refresh":"2026-08-26T10:00:00Z","creation_mode":"template"}"#.utf8
            )
        )
    }

    private static func insight(_ json: String) throws -> Insight {
        try JSONDecoder().decode(Insight.self, from: Data(json.utf8))
    }

    private static func event() throws -> EventRow {
        try #require(EventRow(row: QueryRow(
            columns: ["event", "timestamp", "distinct_id", "$current_url", "properties"],
            values: [
                .string("synthetic_observatory_calibration_completed_across_every_portable_display"),
                .string("2026-08-27T14:15:30Z"),
                .string("fictional-person-with-a-deliberately-long-distinct-identifier"),
                .string("https://example.com/observatory/calibration/portable-display/complete"),
                .object([
                    "synthetic_duration_bucket": .string("long-running-calibration-window"),
                    "synthetic_result": .string("all fictional instruments aligned"),
                ]),
            ]
        )))
    }

    private static func mobileSession() throws -> SessionRecording {
        try JSONDecoder().decode(
            SessionRecording.self,
            from: Data(
                #"{"id":"018f1000-0000-7000-8000-000000009901","distinct_id":"fictional-portable-observer","recording_duration":765,"active_seconds":601,"start_time":"2026-08-27T14:15:30Z","start_url":"https://example.com/observatory/calibration/portable-display/complete","click_count":19,"keypress_count":7,"console_error_count":2,"snapshot_source":"mobile","person":{"uuid":"018f0000-0000-7000-8000-000000009901","name":"Synthetic Portable Observatory Calibration Reviewer With Long Text","distinct_ids":["fictional-portable-observer"]}}"#.utf8
            )
        )
    }

    private static func digest() throws -> ReplayVisionSummaryDigest {
        let response = try QueryResponse.decode(from: Data(#"""
        {
          "columns": ["session_id", "title", "summary", "intent", "outcome", "friction_points", "confidence", "model", "completed_at"],
          "results": [[
            "018f1000-0000-7000-8000-000000009901",
            "Synthetic portable calibration review found a narrow control",
            "The fictional reviewer compared every observatory display and found one narrow calibration control before completing the walkthrough.",
            "Review fictional calibration telemetry",
            "Completed the synthetic review",
            ["A fictional control wrapped at compact width"],
            0.91,
            "synthetic-model",
            "2026-08-27T14:20:30Z"
          ]]
        }
        """#.utf8))
        return try #require(ReplayVisionSummaryDigest.rows(from: response).first)
    }

    private static func flag() throws -> FeatureFlag {
        try JSONDecoder().decode(
            FeatureFlag.self,
            from: Data(#"""
            {
              "id": 799001,
              "key": "synthetic-portable-observatory-calibration-across-every-display",
              "name": "Synthetic portable observatory calibration across every fictional display",
              "active": true,
              "archived": false,
              "filters": {
                "groups": [
                  {"properties": [], "rollout_percentage": 61},
                  {"properties": [], "rollout_percentage": 17}
                ],
                "multivariate": {
                  "variants": [
                    {"key": "compact", "name": "Compact fictional controls", "rollout_percentage": 50},
                    {"key": "regular", "name": "Regular fictional controls", "rollout_percentage": 50}
                  ]
                }
              }
            }
            """#.utf8)
        )
    }

    private static func issue() throws -> ErrorIssue {
        try JSONDecoder().decode(
            ErrorIssue.self,
            from: Data(#"""
            {
              "id": "018f3300-0000-7000-8000-000000009901",
              "name": "SyntheticPortableObservatoryCalibrationLayoutFaultWithLongText",
              "description": "A fictional calibration control exceeded the compact preview width while every synthetic instrument remained safe.",
              "status": "active",
              "last_seen": "2026-08-27T14:15:30Z",
              "aggregations": {"occurrences": 29, "sessions": 11, "users": 9}
            }
            """#.utf8)
        )
    }

    private static func trace() throws -> TraceGroup {
        let traceID = "018f9000-0000-7000-8000-000000009901"
        let root = try #require(TraceSpan(row: QueryRow(
            columns: [
                "uuid", "trace_id", "span_id", "parent_span_id", "name",
                "service_name", "status_code", "timestamp", "duration_nano", "is_root_span",
            ],
            values: [
                .string("synthetic-root"), .string(traceID), .string("root"), .null,
                .string("calibrate every fictional portable observatory display"),
                .string("synthetic-observatory-coordination-service-with-long-text"),
                .string("ok"), .string("2026-08-27T14:15:30Z"),
                .number(12_500_000_000), .bool(true),
            ]
        )))
        return TraceGroup(id: traceID, spans: [root])
    }

    private static let dashboardJSON = #"""
    {
      "id": 720100,
      "name": "Synthetic launch health across every observatory and portable display",
      "tiles": [
        {
          "id": 720101,
          "order": 1,
          "insight": {
            "id": 721001,
            "name": "Synthetic weekly activation across a deliberately long fictional cohort name",
            "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery","trendsFilter":{"display":"BoldNumber"}}},
            "result": [{"label":"Synthetic activations","aggregated_value":12500,"data":[],"days":[]}]
          }
        }
      ]
    }
    """#

    private static let insightSummaryJSON = #"""
    {
      "id": 7201,
      "name": "Synthetic activation trend across every observatory and portable display",
      "description": "Long fictional insight context that must wrap without clipping at compact and regular preview widths.",
      "favorited": true,
      "dashboards": [7301, 7302],
      "last_modified_at": "2026-08-26T10:00:00Z",
      "last_refresh": "2026-08-26T09:00:00Z",
      "is_cached": true,
      "query": {
        "kind": "InsightVizNode",
        "source": {"kind":"TrendsQuery","trendsFilter":{"display":"BoldNumber"}}
      },
      "result": []
    }
    """#

    private static let insightLoadedJSON = #"""
    {
      "id": 7201,
      "query": {
        "kind": "InsightVizNode",
        "source": {"kind":"TrendsQuery","trendsFilter":{"display":"BoldNumber"}}
      },
      "result": [{"label":"Synthetic activations","aggregated_value":12500,"data":[],"days":[]}]
    }
    """#
}
