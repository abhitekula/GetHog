import Foundation
import Testing

@testable import GetHogKit

/// Every `ChartDisplayType` PostHog will send, and what this app draws for it.
///
/// The vocabulary is not guessed. `POST /query/` with an invalid display returns
/// the enum in its validation error, and on 2026-07-30 that was exactly:
///
///     Auto, ActionsLineGraph, ActionsBar, ActionsUnstackedBar,
///     ActionsStackedBar, ActionsAreaGraph, ActionsLineGraphCumulative,
///     BoldNumber, Metric, ActionsPie, ActionsBarValue, ActionsTable,
///     WorldMap, CalendarHeatmap, TwoDimensionalHeatmap, BoxPlot, SlopeGraph
///
/// The payload each one actually returns was then measured by running the same
/// trends query seventeen times, once per display. Three of them return a shape
/// with no time series in it, and all three used to reach the line renderer and
/// draw an empty pair of axes.
@Suite("Display type coverage")
struct DisplayTypeCoverageTests {

    /// Every display PostHog's own validator accepts.
    static let all = [
        "Auto", "ActionsLineGraph", "ActionsBar", "ActionsUnstackedBar",
        "ActionsStackedBar", "ActionsAreaGraph", "ActionsLineGraphCumulative",
        "BoldNumber", "Metric", "ActionsPie", "ActionsBarValue", "ActionsTable",
        "WorldMap", "CalendarHeatmap", "TwoDimensionalHeatmap", "BoxPlot", "SlopeGraph",
    ]

    /// A trends result with an aggregated figure and no series — the shape
    /// `WorldMap` and `CalendarHeatmap` return.
    private func aggregated(label: String, value: Double) -> RawResult {
        .series([TrendsSeriesDTO(
            label: label, count: 0, data: [], days: [],
            aggregatedValue: value, status: nil
        )])
    }

    private func timeSeries() -> RawResult {
        .series([TrendsSeriesDTO(
            label: "$pageview", count: 153, data: [37, 15, 17],
            days: ["2026-01-23", "2026-01-24", "2026-01-25"],
            aggregatedValue: nil, status: nil
        )])
    }

    @Test("no display type draws an empty line chart", arguments: DisplayTypeCoverageTests.all)
    func noDisplayFallsThroughToAnEmptyLine(display: String) {
        // Deterministic contract shapes for each display family.
        let aggregatedDisplays: Set<String> = [
            "BoldNumber", "ActionsPie", "ActionsBarValue", "ActionsTable",
            "WorldMap", "CalendarHeatmap",
        ]
        let emptyDisplays: Set<String> = ["BoxPlot"]

        let result: RawResult
        if emptyDisplays.contains(display) {
            result = .series([])
        } else if aggregatedDisplays.contains(display) {
            result = aggregated(label: "US", value: 35)
        } else {
            result = timeSeries()
        }

        let model = Insight.renderModel(
            result: result, sourceKind: "TrendsQuery", display: display
        )

        // The defect this suite exists for: a tile whose payload has no points
        // must never come back as a time series, because that draws axes with
        // nothing on them and reads as broken rather than as unsupported.
        if case .timeSeries(let series, _) = model {
            let points = series.flatMap(\.points)
            #expect(!points.isEmpty, "\(display) drew a time series with no points")
        }
    }

    @Test("WorldMap draws the bar-value shape its payload actually is")
    func worldMapIsBarValue() {
        // Authored WorldMap bar-value example: `data: []`, `days: []`,
        // `aggregated_value: 35`, `label: "US"`.
        let result = RawResult.series([
            TrendsSeriesDTO(label: "US", count: 0, data: [], days: [],
                            aggregatedValue: 35, status: nil),
            TrendsSeriesDTO(label: "$$_posthog_breakdown_null_$$", count: 0, data: [], days: [],
                            aggregatedValue: 537, status: nil),
        ])
        let model = Insight.renderModel(result: result, sourceKind: "TrendsQuery", display: "WorldMap")

        guard case .barValue(let bars) = model else {
            Issue.record("WorldMap rendered as \(model)"); return
        }
        #expect(bars.count == 2)
        #expect(bars[0].label == "US")
        #expect(bars[0].value == 35)
    }

    @Test("the null-breakdown sentinel is shown as words and sent as itself")
    func nullBreakdownSentinel() {
        // A live WorldMap returns `$$_posthog_breakdown_null_$$` with 537 — the
        // largest bar on the chart, and unreadable when drawn as-is.
        let result = RawResult.series([
            TrendsSeriesDTO(label: "$$_posthog_breakdown_null_$$", count: 0, data: [], days: [],
                            aggregatedValue: 537, status: nil),
        ])
        guard case .barValue(let bars) = Insight.renderModel(
            result: result, sourceKind: "TrendsQuery", display: "WorldMap"
        ) else {
            Issue.record("expected bars"); return
        }
        #expect(bars[0].label == "(no value)")
        // The drill-down has to send back what PostHog sent, not what the user
        // was shown.
        #expect(bars[0].rawValue == "$$_posthog_breakdown_null_$$")
    }

    @Test("an ordinary breakdown label is untouched")
    func ordinaryBreakdownLabel() {
        let result = RawResult.series([
            TrendsSeriesDTO(label: "US", count: 0, data: [], days: [],
                            aggregatedValue: 35, status: nil),
        ])
        guard case .barValue(let bars) = Insight.renderModel(
            result: result, sourceKind: "TrendsQuery", display: "ActionsBarValue"
        ) else {
            Issue.record("expected bars"); return
        }
        #expect(bars[0].label == "US")
        #expect(bars[0].rawValue == "US")
    }

    @Test("CalendarHeatmap and BoxPlot degrade to the honest card")
    func undrawableDisplaysAreUnsupported() {
        // CalendarHeatmap: the synthetic contract shape uses `data: []`,
        // `days: null` under a `calendar_heatmap_data` key this app does not model.
        #expect(
            Insight.renderModel(
                result: aggregated(label: "$pageview", value: 139),
                sourceKind: "TrendsQuery", display: "CalendarHeatmap"
            ) == .unsupported(kind: "CalendarHeatmap")
        )
        // BoxPlot: `results: []` outright.
        #expect(
            Insight.renderModel(
                result: .series([]), sourceKind: "TrendsQuery", display: "BoxPlot"
            ) == .unsupported(kind: "BoxPlot")
        )
    }

    @Test("ActionsUnstackedBar draws bars, not a line")
    func unstackedBarStyle() {
        // It returns ordinary time-series data and used to fall through to
        // `.line`, drawing a bar insight as a line.
        #expect(TimeSeriesStyle(display: "ActionsUnstackedBar") == .bar)
        #expect(TimeSeriesStyle(display: "ActionsBar") == .bar)
        #expect(TimeSeriesStyle(display: "ActionsStackedBar") == .stackedBar)
        #expect(TimeSeriesStyle(display: "ActionsAreaGraph") == .area)
    }

    @Test("displays whose payload really is a plain series stay a line")
    func linesStayLines() {
        // Measured: cumulative arrives already summed (`[37, 52, 69, …]`),
        // SlopeGraph arrives as exactly two points, and TwoDimensionalHeatmap
        // arrives byte-identical to the same query with no display at all.
        for display in ["Auto", "ActionsLineGraph", "ActionsLineGraphCumulative",
                        "SlopeGraph", "Metric", "TwoDimensionalHeatmap"] {
            #expect(TimeSeriesStyle(display: display) == .line, "\(display)")
        }
    }
}
