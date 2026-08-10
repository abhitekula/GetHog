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

    @Test("compact date-axis labels stay short and distinguish sub-day points")
    func compactDateAxisLabelsStayDistinct() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US_POSIX")
        let dates = try [
            DateComponents(year: 2026, month: 1, day: 13, hour: 0),
            DateComponents(year: 2026, month: 1, day: 13, hour: 12),
            DateComponents(year: 2026, month: 1, day: 14, hour: 0),
            DateComponents(year: 2026, month: 1, day: 14, hour: 12),
        ].map { try #require(calendar.date(from: $0)) }

        let labels = dates.map {
            HogQLDateAxisLabel(
                date: $0,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        }

        #expect(labels.allSatisfy { !$0.day.isEmpty && !$0.time.isEmpty })
        #expect(labels.allSatisfy { $0.day.count <= 6 })
        #expect(labels.allSatisfy { $0.time.count <= 8 })
        #expect(Set(labels.map { "\($0.day)|\($0.time)" }).count == dates.count)
        #expect(labels[0].month == "Jan")
        #expect(labels[0].dayOfMonth == "13")
    }

    @Test("only date axes pad their scale to contain endpoint labels")
    func onlyDateAxesPadEndpointLabels() {
        #expect(HogQLCartesianLayout.xAxisPlacement(for: .date, hasParsedDates: true) == .paddedDate)
        #expect(HogQLCartesianLayout.xAxisPlacement(for: .dateTime, hasParsedDates: true) == .paddedDate)
        #expect(HogQLCartesianLayout.xAxisPlacement(for: .date, hasParsedDates: false) == .standard)
        #expect(HogQLCartesianLayout.xAxisPlacement(for: .string, hasParsedDates: false) == .standard)
        #expect(HogQLCartesianLayout.xAxisPlacement(for: .integer, hasParsedDates: false) == .standard)
    }

    @Test("date-axis gutters grow for accessibility text without consuming the plot")
    func dateAxisGutterAdaptsToTextScale() {
        let standard = HogQLCartesianLayout.dateScalePadding(textScale: 1)
        let accessibility = HogQLCartesianLayout.dateScalePadding(textScale: 4.3)
        let extreme = HogQLCartesianLayout.dateScalePadding(textScale: 20)

        #expect(standard == 34)
        #expect(accessibility > standard)
        #expect(accessibility == extreme)
        #expect(extreme <= 96)
    }

    @Test("daily axes omit redundant midnight while sub-day axes retain time")
    func dateAxisTimeReflectsGranularity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let midnight = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 13, hour: 0)
        ))
        let nextMidnight = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 14, hour: 0)
        ))
        let noon = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 13, hour: 12)
        ))

        #expect(!HogQLCartesianLayout.dateAxisIncludesTime(
            dates: [midnight, nextMidnight],
            calendar: calendar
        ))
        #expect(HogQLCartesianLayout.dateAxisIncludesTime(
            dates: [midnight, noon],
            calendar: calendar
        ))
    }

    @Test("accessibility date labels stack narrow month and day components")
    func accessibilityDateLabelsStack() {
        #expect(HogQLCartesianLayout.dateAxisLabelStyle(isAccessibilitySize: false) == .inline)
        #expect(HogQLCartesianLayout.dateAxisLabelStyle(isAccessibilitySize: true) == .stacked)
    }

    @Test("the totals legend replaces Swift Charts' duplicate multi-series legend")
    func multiSeriesUsesOneLegend() {
        #expect(HogQLCartesianLayout.hidesBuiltInLegend(seriesCount: 0) == false)
        #expect(HogQLCartesianLayout.hidesBuiltInLegend(seriesCount: 1) == false)
        #expect(HogQLCartesianLayout.hidesBuiltInLegend(seriesCount: 2))
    }

    @Test("multi-series style domains retain configured slots when labels repeat or a series is empty")
    func seriesStyleDomainsStayAlignedWithTheLegend() throws {
        let visualization = try Self.visualization(
            display: "ActionsLineGraph",
            chartSettings: """
            "chartSettings": {
              "xAxis": {"column": "day"},
              "yAxis": [
                {"column": "opened", "settings": {"display": {"label": "Same label"}}},
                {"column": "clicked", "settings": {"display": {"label": "Same label"}}}
              ]
            },
            """,
            columns: #"["day", "opened", "clicked"]"#,
            types: #"[["day", "Date"], ["opened", "UInt64"], ["clicked", "UInt64"]]"#,
            rows: #"[["2026-02-01", "not numeric", 4]]"#
        )
        let data = try #require(visualization.chartData)
        let styles = HogQLCartesianLayout.seriesStyles(for: data.series)

        #expect(data.series[0].points.isEmpty)
        #expect(styles.map(\.key) == ["opened", "clicked"])
        #expect(styles.map(\.label) == ["Same label", "Same label"])
        #expect(styles.map(\.slot) == [0, 1])
    }

    @Test("sub-minute and multi-year axes retain the precision needed to distinguish labels")
    func dateAxisPrecisionMatchesTheDomain() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US_POSIX")
        let dates = try [
            DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 59, second: 1),
            DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 2),
        ].map { try #require(calendar.date(from: $0)) }
        let configuration = HogQLCartesianLayout.dateAxisConfiguration(
            dates: dates,
            calendar: calendar
        )
        let labels = dates.map {
            HogQLDateAxisLabel(
                date: $0,
                configuration: configuration,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        }

        #expect(configuration.includesSeconds)
        #expect(configuration.includesYear)
        #expect(labels.map(\.time) == ["11:59:01\u{202f}PM", "11:59:02\u{202f}PM"])
        #expect(labels.map(\.year) == ["2025", "2026"])
        #expect(Set(labels.map(\.day)).count == dates.count)
    }

    @Test("project chart time zones resolve explicitly and fall back to UTC")
    func projectTimeZoneResolutionIsDeterministic() {
        let newYork = ProjectChartTimeZone.resolve("America/New_York")
        let utc = ProjectChartTimeZone.resolve(nil)
        let invalid = ProjectChartTimeZone.resolve("Not/A_Time_Zone")

        #expect(newYork.identifier == "America/New_York")
        #expect(utc.secondsFromGMT(for: Date(timeIntervalSince1970: 0)) == 0)
        #expect(invalid == utc)
    }

    @Test("compact result tables leave vertical scrolling to their dashboard")
    func compactTablesOnlyOwnTheHorizontalAxis() {
        #expect(!HogQLTableLayout.allowsVerticalScrolling(compact: true))
        #expect(HogQLTableLayout.allowsVerticalScrolling(compact: false))
    }

    @Test("only compact HogQL tables require direct touch inside a dashboard tile")
    func compactTableInteractionIsScopedToTables() throws {
        let table = try Self.visualization(display: "ActionsTable")
        let line = try Self.visualization(display: "ActionsLineGraph")
        let fallback = try Self.visualization(
            display: "ActionsLineGraph",
            chartSettings: #""chartSettings": {"xAxis": {"column": "missing"}},"#
        )

        #expect(InsightChartInteraction.requiresDirectTouch(for: .hogQL(table), compact: true))
        #expect(!InsightChartInteraction.requiresDirectTouch(for: .hogQL(table), compact: false))
        #expect(!InsightChartInteraction.requiresDirectTouch(for: .hogQL(line), compact: true))
        #expect(InsightChartInteraction.requiresDirectTouch(for: .hogQL(fallback), compact: true))
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

    @MainActor
    @Test("dated chart preparation parses each unique axis value once per input identity")
    func datedChartPreparationIsIdentityCached() throws {
        let visualization = try Self.visualization(
            display: "ActionsLineGraph",
            chartSettings: """
            "chartSettings": {
              "xAxis": {"column": "timestamp"},
              "yAxis": [{"column": "opened"}, {"column": "clicked"}]
            },
            """,
            columns: #"["timestamp", "opened", "clicked"]"#,
            types: #"[["timestamp", "DateTime64(6)"], ["opened", "UInt64"], ["clicked", "UInt64"]]"#,
            rows: #"[["2026-02-01T00:00:00Z", 2, 1], ["2026-02-02T00:00:00Z", 4, 3]]"#
        )
        let data = try #require(visualization.chartData)
        var parsedValues: [String] = []
        let cache = HogQLDatedChartCache { raw, _, _ in
            parsedValues.append(raw)
            return Date(timeIntervalSinceReferenceDate: Double(parsedValues.count))
        }
        var calendar = Calendar(identifier: .gregorian)
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        calendar.timeZone = utc

        let first = cache.model(for: data, calendar: calendar, timeZone: utc)
        let repeated = cache.model(for: data, calendar: calendar, timeZone: utc)

        #expect(first == repeated)
        #expect(first.points?.count == 4)
        #expect(parsedValues == [
            "2026-02-01T00:00:00Z",
            "2026-02-02T00:00:00Z",
        ])

        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        calendar.timeZone = newYork
        _ = cache.model(for: data, calendar: calendar, timeZone: newYork)
        #expect(parsedValues == [
            "2026-02-01T00:00:00Z",
            "2026-02-02T00:00:00Z",
            "2026-02-01T00:00:00Z",
            "2026-02-02T00:00:00Z",
        ])
    }

    @MainActor
    @Test("dated chart layout reuses its preparation cache across body revisions")
    func datedChartLayoutReusesPreparationCache() throws {
        let visualization = try Self.visualization(
            display: "ActionsLineGraph",
            columns: #"["timestamp", "value"]"#,
            types: #"[["timestamp", "DateTime64(6)"], ["value", "UInt64"]]"#,
            rows: #"[["2026-02-01T00:00:00Z", 2], ["2026-02-02T00:00:00Z", 4]]"#
        )
        var parsedValues: [String] = []
        let cache = HogQLDatedChartCache { raw, _, _ in
            parsedValues.append(raw)
            return Date(timeIntervalSinceReferenceDate: Double(parsedValues.count))
        }
        let renderer = ImageRenderer(
            content: HogQLVisualizationView(
                visualization: visualization,
                compact: false,
                title: "Synthetic dated chart",
                datedChartCache: cache
            )
        )
        for iteration in 0..<5 {
            renderer.proposedSize = ProposedViewSize(
                width: 620 + Double(iteration % 2),
                height: 360
            )
            #if canImport(AppKit)
            _ = try #require(renderer.nsImage)
            #elseif canImport(UIKit)
            _ = try #require(renderer.uiImage)
            #endif
        }
        #expect(parsedValues == [
            "2026-02-01T00:00:00Z",
            "2026-02-02T00:00:00Z",
        ])
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
