import Foundation
import Testing

@testable import GetHogKit

@Suite("Insight decoding")
struct InsightDecodingTests {

    @Test("decodes a trends line graph tile into a time series")
    func trendsLineGraph() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        #expect(dashboard.tiles.count == 7)

        // Tile 0 in the synthetic dashboard fixture is "Daily active users (DAUs)",
        // a TrendsQuery rendered as ActionsLineGraph.
        guard case .timeSeries(let series, let style) = dashboard.tiles[0].renderModel else {
            Issue.record("expected .timeSeries, got \(dashboard.tiles[0].renderModel)")
            return
        }

        #expect(style == .line)
        #expect(series.count == 1)
        // Days must parse to real Dates so the chart can thin its own axis
        // labels; a categorical axis would render one label per day.
        #expect(series[0].datedPoints?.count == 31)
        #expect(series[0].label == "account_created")
        #expect(series[0].total == 1_382.7)
        #expect(series[0].points.count == 31)
        #expect(series[0].points.first?.value == 27)
    }

    @Test("decodes an ActionsBarValue tile into ranked bar values")
    func trendsBarValue() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))

        // Tile 4 is "Referring domain (last 14 days)": a TrendsQuery displayed as
        // ActionsBarValue, which carries `aggregated_value` and an EMPTY `data`
        // array — decoding it as a time series would yield an empty chart.
        guard case .barValue(let bars) = dashboard.tiles[4].renderModel else {
            Issue.record("expected .barValue, got \(String(describing: dashboard.tiles[4].renderModel))")
            return
        }

        #expect(bars.count == 12)
        #expect(bars[0].label == "example.com synthetic fixture 6")
        #expect(bars[0].value == 393)
        #expect(bars[1].label == "Synthetic series 332")
        #expect(bars[1].value == 231)
    }

    @Test("decodes a funnel with a breakdown into one group per breakdown value")
    func funnelWithBreakdown() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))

        // Tile 5 is "Pageview funnel, by browser" — result is an array of arrays,
        // one inner array of steps per breakdown value.
        guard case .funnel(let groups) = dashboard.tiles[5].renderModel else {
            Issue.record("expected .funnel, got \(String(describing: dashboard.tiles[5].renderModel))")
            return
        }

        #expect(groups.count == 8)
        #expect(groups[0].breakdownValue == "Safari")
        #expect(groups[0].steps.map(\.count) == [281, 97, 53])
        #expect(groups[0].steps.map(\.order) == [192, 194, 196])
        #expect(groups[0].steps[0].averageConversionTime == nil)
        #expect(groups[0].steps[1].averageConversionTime != nil)
    }

    @Test(
        "carries the display type through so bar insights aren't drawn as lines",
        arguments: [
            ("ActionsLineGraph", TimeSeriesStyle.line),
            ("ActionsAreaGraph", TimeSeriesStyle.area),
            ("ActionsBar", TimeSeriesStyle.bar),
            ("ActionsStackedBar", TimeSeriesStyle.stackedBar),
        ]
    )
    func displayTypeSelectsChartStyle(display: String, expected: TimeSeriesStyle) throws {
        let json = #"""
        {"id": 1, "name": "T", "query": {"kind": "InsightVizNode",
         "source": {"kind": "TrendsQuery", "trendsFilter": {"display": "\#(display)"}}},
         "result": [{"label": "a", "count": 3, "data": [1,2], "days": ["2025-06-18","2026-01-02"]}]}
        """#
        let insight = try JSONDecoder().decode(Insight.self, from: Data(json.utf8))

        guard case .timeSeries(_, let style) = insight.renderModel else {
            Issue.record("expected .timeSeries, got \(insight.renderModel)")
            return
        }
        #expect(style == expected)
    }

    @Test("defaults to a line when no display type is specified")
    func defaultsToLine() throws {
        let json = #"""
        {"id": 1, "name": "T", "query": {"kind": "InsightVizNode",
         "source": {"kind": "TrendsQuery"}},
         "result": [{"label": "a", "count": 1, "data": [1], "days": ["2025-06-18"]}]}
        """#
        let insight = try JSONDecoder().decode(Insight.self, from: Data(json.utf8))
        guard case .timeSeries(_, let style) = insight.renderModel else { return }
        #expect(style == .line)
    }

    @Test("dispatches on query kind, not result shape")
    func dispatchesOnKindNotShape() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))

        // Lifecycle results carry `data`/`days` exactly like trends, so sniffing
        // the result's shape would silently draw a plain line chart and lose the
        // new/returning/dormant split entirely.
        if case .timeSeries = dashboard.tiles[2].renderModel {
            Issue.record("lifecycle was mis-dispatched as a plain time series")
        }
        if case .lifecycle = dashboard.tiles[2].renderModel {} else {
            Issue.record("expected .lifecycle for tile 2")
        }
    }

    @Test("degrades a genuinely unsupported insight type rather than mis-rendering")
    func unsupportedKind() throws {
        // Paths has no representation on a phone yet; it must produce a card, not
        // a wrong chart and not a crash.
        let json = #"""
        {"id": 1, "name": "Paths", "query": {"kind": "InsightVizNode",
         "source": {"kind": "PathsQuery"}}, "result": [{"weird": true}]}
        """#
        let insight = try JSONDecoder().decode(Insight.self, from: Data(json.utf8))

        guard case .unsupported(let kind) = insight.renderModel else {
            Issue.record("expected .unsupported, got \(insight.renderModel)")
            return
        }
        #expect(kind == "PathsQuery")
    }

    @Test("resolves a tile title, falling back to derived_name")
    func insightTitle() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        #expect(dashboard.tiles[0].insight?.title == "Example daily engagement")
        #expect(dashboard.tiles[5].insight?.title == "Example signup funnel by browser")
    }
}
