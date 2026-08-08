import Foundation
import GetHogKit
import SwiftUI
import Testing

@testable import GetHogUI

@Suite("HogQL visualization UI")
struct HogQLVisualizationViewTests {
    @Test("selects independent uncomputed, empty, visualization, and table-fallback states")
    func selectsPresentationState() throws {
        let uncomputed = try Self.visualization(display: "ActionsTable", rows: "null")
        let empty = try Self.visualization(display: "ActionsLineGraph", rows: "[]")
        let line = try Self.visualization(display: "ActionsLineGraph")
        let invalid = try Self.visualization(
            display: "ActionsLineGraph",
            chartSettings: #""chartSettings": {"xAxis": {"column": "missing"}},"#
        )

        #expect(HogQLPresentation.state(for: uncomputed) == .uncomputed)
        #expect(HogQLPresentation.state(for: empty) == .empty)
        #expect(HogQLPresentation.state(for: line) == .visualization(.line))
        guard case .tableFallback = HogQLPresentation.state(for: invalid) else {
            Issue.record("Expected malformed chart settings to select the table fallback")
            return
        }
    }

    @Test("summaries and tile identity describe HogQL data, not unsupported SQL")
    func describesVisualization() throws {
        let visualization = try Self.visualization(display: "ActionsLineGraph")
        let model = InsightRenderModel.hogQL(visualization)

        #expect(InsightSummary.spoken(model).contains("2 rows"))
        #expect(InsightSummary.spoken(model).contains("2 columns"))
        #expect(TileStyle.symbol(for: model) == "chart.xyaxis.line")
        #expect(TileStyle.preferredColumns(for: model) == 1)
    }

    @MainActor
    @Test("every supported display produces a nonempty render", arguments: [
        "ActionsTable", "ActionsLineGraph", "ActionsAreaGraph", "ActionsBar",
        "ActionsStackedBar", "ActionsPie", "TwoDimensionalHeatmap", "BoldNumber",
    ])
    func rendersEveryDisplay(display: String) throws {
        let visualization = try Self.visualization(
            display: display,
            columns: #"["region", "channel", "value"]"#,
            types: #"[["region", "String"], ["channel", "String"], ["value", "UInt64"]]"#,
            rows: #"[["north", "email", 2], ["south", "chat", 4]]"#
        )
        let renderer = ImageRenderer(
            content: HogQLVisualizationView(
                visualization: visualization,
                compact: false,
                title: "Synthetic visualization"
            )
            .frame(width: 480, height: 320)
        )
        #if canImport(AppKit)
        #expect(renderer.nsImage != nil)
        #elseif canImport(UIKit)
        #expect(renderer.uiImage != nil)
        #endif
    }

    private static func visualization(
        display: String,
        chartSettings: String = "",
        columns: String = #"["day", "value"]"#,
        types: String = #"[["day", "Date"], ["value", "UInt64"]]"#,
        rows: String = #"[["2026-02-01", 2], ["2026-02-02", 4]]"#
    ) throws -> HogQLVisualization {
        let data = Data(
            """
            {
              "id": 711001,
              "query": {
                "kind": "DataVisualizationNode",
                "display": "\(display)",
                \(chartSettings)
                "source": {"kind": "HogQLQuery", "query": "SELECT * FROM synthetic_metrics"}
              },
              "columns": \(columns),
              "types": \(types),
              "result": \(rows),
              "hasMore": false
            }
            """.utf8
        )
        let insight = try JSONDecoder().decode(Insight.self, from: data)
        guard case .hogQL(let visualization) = insight.renderModel else {
            throw TestError.expectedHogQL
        }
        return visualization
    }

    private enum TestError: Error { case expectedHogQL }
}
