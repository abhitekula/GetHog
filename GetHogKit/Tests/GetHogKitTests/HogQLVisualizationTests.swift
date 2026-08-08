import Foundation
import Testing

@testable import GetHogKit

@Suite("HogQL visualizations")
struct HogQLVisualizationTests {
    @Test("decodes dashboard text tiles as notes instead of empty insights")
    func decodesTextTile() throws {
        let dashboard = try Dashboard.decode(from: Data(
            """
            {
              "id": 710900,
              "name": "Synthetic dashboard",
              "tiles": [{
                "id": 710901,
                "text": {"body": "A fictional operational note."},
                "insight": null,
                "last_refresh": null
              }]
            }
            """.utf8
        ))
        let tile = try #require(dashboard.tiles.first)

        guard case .text(let note) = tile.content else {
            Issue.record("Expected a dashboard text tile")
            return
        }
        #expect(note.body == "A fictional operational note.")
        #expect(tile.insight == nil)
        #expect(tile.title == "Note")
    }

    @Test("distinguishes a computed empty result from an uncomputed result")
    func distinguishesEmptyFromUncomputed() throws {
        let computed = try JSONDecoder().decode(
            Insight.self,
            from: Data(Self.insightJSON(result: "[]").utf8)
        )
        let uncomputed = try JSONDecoder().decode(
            Insight.self,
            from: Data(Self.insightJSON(result: "null").utf8)
        )

        guard case .hogQL(let computedVisualization) = computed.renderModel else {
            Issue.record("Expected a HogQL visualization for the computed insight")
            return
        }
        guard case .hogQL(let uncomputedVisualization) = uncomputed.renderModel else {
            Issue.record("Expected a HogQL visualization for the uncomputed insight")
            return
        }

        #expect(computedVisualization.rows == [])
        #expect(computedVisualization.isComputed)
        #expect(uncomputedVisualization.rows == nil)
        #expect(!uncomputedVisualization.isComputed)
    }

    @Test("decodes saved display, typed columns, axes, table settings, and truncation")
    func decodesVisualizationMetadata() throws {
        let visualization = try Self.visualization(
            display: "ActionsStackedBar",
            chartSettings: """
            "chartSettings": {
              "xAxis": {"column": "period"},
              "yAxis": [
                {"column": "opened", "settings": {"display": {"label": "Opened"}}},
                {"column": "clicked"}
              ],
              "showNullsAsZero": true,
              "heatmap": {
                "xAxisColumn": "period",
                "yAxisColumn": "channel",
                "valueColumn": "opened"
              }
            },
            """,
            tableSettings: """
            "tableSettings": {
              "columns": [{"column": "clicked"}, {"column": "period"}],
              "transpose": true
            },
            """,
            columns: #"["period", "channel", "opened", "clicked"]"#,
            types: #"[["period", "DateTime64(6)"], ["channel", "String"], ["opened", "UInt64"], ["clicked", "Float64"]]"#,
            rows: #"[["2026-02-01T00:00:00Z", "email", 12, 4.5]]"#,
            hasMore: true
        )

        #expect(visualization.display == .stackedBar)
        #expect(visualization.columns.map(\.scalar) == [.dateTime, .string, .integer, .float])
        #expect(visualization.chart.xAxis == "period")
        #expect(visualization.chart.yAxes == ["opened", "clicked"])
        #expect(visualization.chart.showNullsAsZero)
        #expect(visualization.chart.heatmap.xAxisColumn == "period")
        #expect(visualization.chart.heatmap.yAxisColumn == "channel")
        #expect(visualization.chart.heatmap.valueColumn == "opened")
        #expect(visualization.table.columnOrder == ["clicked", "period"])
        #expect(visualization.table.transpose)
        #expect(visualization.hasMore)
    }

    @Test("maps every explicit display and resolves Auto using PostHog's typed-column rules", arguments: [
        ("ActionsTable", HogQLDisplay.table),
        ("ActionsLineGraph", .line),
        ("ActionsAreaGraph", .area),
        ("ActionsBar", .bar),
        ("ActionsStackedBar", .stackedBar),
        ("ActionsPie", .pie),
        ("TwoDimensionalHeatmap", .heatmap),
        ("BoldNumber", .boldNumber),
    ])
    func mapsExplicitDisplays(apiValue: String, expected: HogQLDisplay) throws {
        let visualization = try Self.visualization(display: apiValue)
        #expect(visualization.resolvedDisplay == expected)
    }

    @Test("Auto resolves time series, heatmap, bold number, bar, and table")
    func resolvesAuto() throws {
        let time = try Self.visualization(
            display: "Auto",
            columns: #"["day", "value"]"#,
            types: #"[["day", "Date"], ["value", "UInt64"]]"#,
            rows: #"[["2026-02-01", 1], ["2026-02-02", 2]]"#
        )
        let heatmap = try Self.visualization(
            display: "Auto",
            columns: #"["region", "channel", "value"]"#,
            types: #"[["region", "String"], ["channel", "String"], ["value", "Decimal(12, 2)"]]"#,
            rows: #"[["north", "email", 1.5]]"#
        )
        let bold = try Self.visualization(
            display: "Auto",
            columns: #"["value"]"#,
            types: #"[["value", "Int64"]]"#,
            rows: #"[[42]]"#
        )
        let bar = try Self.visualization(
            display: "Auto",
            columns: #"["label", "value"]"#,
            types: #"[["label", "String"], ["value", "Float64"]]"#,
            rows: #"[["alpha", 3]]"#
        )
        let table = try Self.visualization(
            display: "Auto",
            columns: #"["label"]"#,
            types: #"[["label", "String"]]"#,
            rows: #"[["alpha"]]"#
        )

        #expect(time.resolvedDisplay == .line)
        #expect(heatmap.resolvedDisplay == .heatmap)
        #expect(bold.resolvedDisplay == .boldNumber)
        #expect(bar.resolvedDisplay == .bar)
        #expect(table.resolvedDisplay == .table)
    }

    @Test("builds default and explicit chart axes without losing null rows")
    func buildsChartData() throws {
        let defaultAxes = try Self.visualization(
            display: "ActionsLineGraph",
            chartSettings: #""chartSettings": {"showNullsAsZero": true},"#,
            columns: #"["day", "opened", "clicked"]"#,
            types: #"[["day", "Date"], ["opened", "UInt64"], ["clicked", "Float64"]]"#,
            rows: #"[["2026-02-01", 10, null], ["2026-02-02", 12, 3.5]]"#
        )
        let explicitAxes = try Self.visualization(
            display: "ActionsBar",
            chartSettings: #""chartSettings": {"xAxis": {"column": "opened"}, "yAxis": [{"column": "clicked"}]},"#,
            columns: #"["label", "opened", "clicked"]"#,
            types: #"[["label", "String"], ["opened", "UInt64"], ["clicked", "Float64"]]"#,
            rows: #"[["alpha", 10, 2.5]]"#
        )

        let defaultChart = try #require(defaultAxes.chartData)
        #expect(defaultChart.xColumn.name == "day")
        #expect(defaultChart.series.map(\.column.name) == ["opened", "clicked"])
        #expect(defaultChart.series[1].points.first?.value == 0)
        #expect(defaultChart.series[0].points.first?.x == .date("2026-02-01"))

        let explicitChart = try #require(explicitAxes.chartData)
        #expect(explicitChart.xColumn.name == "opened")
        #expect(explicitChart.series.map(\.column.name) == ["clicked"])
        #expect(explicitChart.series[0].points.first?.x == .number(10))
    }

    @Test("honors table order and transpose while padding mismatched rows losslessly")
    func transformsDisplayedTable() throws {
        let ordered = try Self.visualization(
            display: "ActionsTable",
            tableSettings: #""tableSettings": {"columns": [{"column": "meta"}, {"column": "label"}]},"#,
            columns: #"["label", "value", "meta"]"#,
            types: #"[["label", "String"], ["value", "UInt64"], ["meta", "Tuple(String, UInt64)"]]"#,
            rows: #"[["alpha", 2, {"source":"synthetic"}], ["beta"]]"#
        )
        let transposed = try Self.visualization(
            display: "ActionsTable",
            tableSettings: #""tableSettings": {"columns": [{"column": "label"}, {"column": "value"}], "transpose": true},"#,
            columns: #"["label", "value"]"#,
            types: #"[["label", "String"], ["value", "UInt64"]]"#,
            rows: #"[["alpha", 2], ["beta", 4]]"#
        )

        #expect(ordered.displayedTable.columns.map(\.name) == ["meta", "label"])
        #expect(ordered.displayedTable.rows[0][0] == .object(["source": .string("synthetic")]))
        #expect(ordered.displayedTable.rows[1] == [.null, .string("beta")])
        #expect(transposed.displayedTable.columns.map(\.name) == ["Field", "Row 1", "Row 2"])
        #expect(transposed.displayedTable.rows[0] == [.string("label"), .string("alpha"), .string("beta")])
        #expect(transposed.displayedTable.rows[1] == [.string("value"), .number(2), .number(4)])
    }

    @Test("synthesizes missing column names so every returned cell remains visible")
    func preservesUnnamedColumns() throws {
        let visualization = try Self.visualization(
            display: "ActionsTable",
            columns: #"["label"]"#,
            types: #"[["label", "String"], ["", "UInt64"]]"#,
            rows: #"[["alpha", 7, {"source":"synthetic"}]]"#
        )

        #expect(visualization.columns.map(\.name) == ["label", "Column 2", "Column 3"])
        #expect(visualization.displayedTable.rows == [[
            .string("alpha"),
            .number(7),
            .object(["source": .string("synthetic")]),
        ]])
    }

    @Test("derives pie slices, aggregated heatmap cells, and the first displayed bold value")
    func derivesSpecializedDisplays() throws {
        let pie = try Self.visualization(
            display: "ActionsPie",
            columns: #"["label", "value"]"#,
            types: #"[["label", "String"], ["value", "UInt64"]]"#,
            rows: #"[["alpha", 2], ["beta", 4]]"#
        )
        let heatmap = try Self.visualization(
            display: "TwoDimensionalHeatmap",
            columns: #"["region", "channel", "value"]"#,
            types: #"[["region", "String"], ["channel", "String"], ["value", "UInt64"]]"#,
            rows: #"[["north", "email", 2], ["north", "email", 3], ["south", "chat", 4]]"#
        )
        let bold = try Self.visualization(
            display: "BoldNumber",
            tableSettings: #""tableSettings": {"columns": [{"column": "second"}, {"column": "first"}]},"#,
            columns: #"["first", "second"]"#,
            types: #"[["first", "UInt64"], ["second", "UInt64"]]"#,
            rows: #"[[1, 9]]"#
        )

        #expect(pie.pieSlices.map(\.label) == ["alpha", "beta"])
        #expect(pie.pieSlices.map(\.value) == [2, 4])
        #expect(heatmap.heatmap?.cells.first(where: { $0.x == "north" && $0.y == "email" })?.value == 5)
        #expect(bold.boldNumber == .number(9))
    }

    @Test("invalid explicit chart settings fall back to the complete table")
    func invalidSettingsFallBack() throws {
        let visualization = try Self.visualization(
            display: "ActionsLineGraph",
            chartSettings: #""chartSettings": {"xAxis": {"column": "missing"}, "yAxis": [{"column": "value"}]},"#,
            columns: #"["label", "value"]"#,
            types: #"[["label", "String"], ["value", "UInt64"]]"#,
            rows: #"[["alpha", 2]]"#
        )

        #expect(visualization.chartData == nil)
        #expect(visualization.configurationIssue != nil)
        #expect(visualization.displayedTable.rows.count == 1)
    }

    @Test("non-plottable series and negative pie values fall back to the lossless table")
    func invalidValuesFallBack() throws {
        let nonNumericValues = try Self.visualization(
            display: "ActionsLineGraph",
            columns: #"["label", "value"]"#,
            types: #"[["label", "String"], ["value", "UInt64"]]"#,
            rows: #"[["alpha", "not a number"]]"#
        )
        let negativePie = try Self.visualization(
            display: "ActionsPie",
            columns: #"["label", "value"]"#,
            types: #"[["label", "String"], ["value", "Int64"]]"#,
            rows: #"[["alpha", -2], ["beta", 4]]"#
        )

        #expect(nonNumericValues.chartData == nil)
        #expect(nonNumericValues.configurationIssue?.contains("no plottable") == true)
        #expect(negativePie.chartData == nil)
        #expect(negativePie.configurationIssue?.contains("negative") == true)
        #expect(negativePie.displayedTable.rows.count == 2)
    }

    @Test("exports the displayed table and reduces only a bold numeric headline")
    func exportsAndReducesSafely() throws {
        let tableInsight = try Self.insight(
            display: "ActionsTable",
            tableSettings: #""tableSettings": {"columns": [{"column": "meta"}, {"column": "label"}]},"#,
            columns: #"["label", "meta"]"#,
            types: #"[["label", "String"], ["meta", "Tuple(String)"]]"#,
            rows: #"[["alpha", {"source":"synthetic"}]]"#
        )
        let boldInsight = try Self.insight(
            display: "BoldNumber",
            columns: #"["value"]"#,
            types: #"[["value", "UInt64"]]"#,
            rows: #"[[42]]"#
        )

        #expect(InsightCSV.rows(tableInsight.renderModel) == [
            ["meta", "label"],
            [#"{"source":"synthetic"}"#, "alpha"],
        ])

        let tableTile = try Self.tile(containing: tableInsight)
        let boldTile = try Self.tile(containing: boldInsight)
        #expect(SharedSnapshot.Metric(tile: tableTile, dashboardID: 9) == nil)
        let metric = try #require(SharedSnapshot.Metric(tile: boldTile, dashboardID: 9))
        #expect(metric.value == 42)
        #expect(metric.unit == "value")
    }

    private static func insightJSON(result: String) -> String {
        """
        {
          "id": 710201,
          "name": "Synthetic telemetry table",
          "query": {
            "kind": "DataVisualizationNode",
            "display": "ActionsTable",
            "source": {
              "kind": "HogQLQuery",
              "query": "SELECT period, value FROM synthetic_metrics"
            }
          },
          "columns": ["period", "value"],
          "types": [["period", "String"], ["value", "UInt64"]],
          "result": \(result),
          "hasMore": false
        }
        """
    }

    private static func visualization(
        display: String? = nil,
        chartSettings: String = "",
        tableSettings: String = "",
        columns: String = #"["label", "value"]"#,
        types: String = #"[["label", "String"], ["value", "UInt64"]]"#,
        rows: String = #"[["alpha", 3]]"#,
        hasMore: Bool = false
    ) throws -> HogQLVisualization {
        let insight = try insight(
            display: display,
            chartSettings: chartSettings,
            tableSettings: tableSettings,
            columns: columns,
            types: types,
            rows: rows,
            hasMore: hasMore
        )
        guard case .hogQL(let visualization) = insight.renderModel else {
            throw TestError.expectedHogQL
        }
        return visualization
    }

    private static func insight(
        display: String? = nil,
        chartSettings: String = "",
        tableSettings: String = "",
        columns: String = #"["label", "value"]"#,
        types: String = #"[["label", "String"], ["value", "UInt64"]]"#,
        rows: String = #"[["alpha", 3]]"#,
        hasMore: Bool = false
    ) throws -> Insight {
        let displayField = display.map { #""display": "\#($0)","# } ?? ""
        let data = Data(
            """
            {
              "id": 710202,
              "name": "Synthetic visualization",
              "query": {
                "kind": "DataVisualizationNode",
                \(displayField)
                \(chartSettings)
                \(tableSettings)
                "source": {
                  "kind": "HogQLQuery",
                  "query": "SELECT * FROM synthetic_metrics"
                }
              },
              "columns": \(columns),
              "types": \(types),
              "result": \(rows),
              "hasMore": \(hasMore)
            }
            """.utf8
        )
        return try JSONDecoder().decode(Insight.self, from: data)
    }

    private static func tile(containing insight: Insight) throws -> Tile {
        let insightData = try JSONEncoder().encode(insight.rawQuery ?? .null)
        let query = String(decoding: insightData, as: UTF8.self)
        let model: HogQLVisualization
        guard case .hogQL(let visualization) = insight.renderModel else { throw TestError.expectedHogQL }
        model = visualization
        let rowsData = try JSONEncoder().encode(model.rows ?? [])
        let columnsData = try JSONEncoder().encode(model.columns.map(\.name))
        let typesData = try JSONEncoder().encode(model.columns.map { [$0.name, $0.typeName ?? "Unknown"] })
        let tileData = Data(
            """
            {"id": 711900, "insight": {
              "id": \(insight.id), "name": "Synthetic metric", "query": \(query),
              "columns": \(String(decoding: columnsData, as: UTF8.self)),
              "types": \(String(decoding: typesData, as: UTF8.self)),
              "result": \(String(decoding: rowsData, as: UTF8.self))
            }}
            """.utf8
        )
        return try JSONDecoder().decode(Tile.self, from: tileData)
    }

    private enum TestError: Error {
        case expectedHogQL
    }
}
