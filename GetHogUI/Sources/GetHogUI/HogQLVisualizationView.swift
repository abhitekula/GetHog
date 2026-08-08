import Charts
import Foundation
import GetHogKit
import SwiftUI

enum HogQLPresentation {
    enum State: Equatable {
        case uncomputed
        case empty
        case visualization(HogQLDisplay)
        case tableFallback(String)
    }

    static func state(for visualization: HogQLVisualization) -> State {
        guard visualization.isComputed else { return .uncomputed }
        guard visualization.rows?.isEmpty == false else { return .empty }
        if let issue = visualization.configurationIssue {
            return .tableFallback(issue)
        }
        return .visualization(visualization.resolvedDisplay)
    }
}

/// Draws PostHog `DataVisualizationNode` results without discarding their
/// lossless table representation.
public struct HogQLVisualizationView: View {
    public let visualization: HogQLVisualization
    public var compact: Bool
    public var title: String

    public init(visualization: HogQLVisualization, compact: Bool = true, title: String = "") {
        self.visualization = visualization
        self.compact = compact
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch HogQLPresentation.state(for: visualization) {
            case .uncomputed:
                stateView(
                    symbol: "clock.badge.questionmark",
                    title: "Not yet computed",
                    message: "PostHog has not produced a result for this insight yet."
                )
            case .empty:
                stateView(
                    symbol: "tablecells",
                    title: "No rows",
                    message: "The query completed successfully and matched no rows."
                )
            case .tableFallback(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Status.warningInk)
                    .accessibilityLabel(message)
                HogQLResultTable(table: visualization.displayedTable, compact: compact)
            case .visualization(let display):
                visualizationView(display)
            }

            if visualization.hasMore {
                Label("More rows are available in PostHog", systemImage: "ellipsis.circle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func visualizationView(_ display: HogQLDisplay) -> some View {
        switch display {
        case .table:
            HogQLResultTable(table: visualization.displayedTable, compact: compact)
        case .line, .area, .bar, .stackedBar:
            if let data = visualization.chartData {
                HogQLCartesianChart(data: data, display: display, compact: compact)
            } else {
                HogQLResultTable(table: visualization.displayedTable, compact: compact)
            }
        case .pie:
            HogQLPieView(slices: visualization.pieSlices, compact: compact)
        case .heatmap:
            if let heatmap = visualization.heatmap {
                HogQLHeatmapView(data: heatmap, compact: compact)
            } else {
                HogQLResultTable(table: visualization.displayedTable, compact: compact)
            }
        case .boldNumber:
            HogQLBoldNumberView(value: visualization.boldNumber)
        case .auto:
            // `resolvedDisplay` never returns Auto. This keeps the switch
            // total if the resolver changes later.
            HogQLResultTable(table: visualization.displayedTable, compact: compact)
        case .unsupported:
            HogQLResultTable(table: visualization.displayedTable, compact: compact)
        }
    }

    private func stateView(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.Ink.tertiary)
            Text(title)
                .font(Theme.Typography.title)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 120 : 180)
        .accessibilityElement(children: .combine)
    }

    private var accessibilityLabel: String {
        let prefix = title.isEmpty ? "HogQL insight" : title
        return "\(prefix). \(InsightSummary.spoken(.hogQL(visualization)))"
    }
}

private struct HogQLResultTable: View {
    let table: HogQLDisplayedTable
    let compact: Bool

    private var rows: ArraySlice<[JSONValue]> {
        compact ? table.rows.prefix(6) : table.rows[...]
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                tableRow(table.columns.map(\.name), header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row.map(\.tabularDescription), header: false)
                }
            }
        }
        .frame(maxHeight: compact ? 210 : 420)
        .overlay(alignment: .bottomTrailing) {
            if compact, table.rows.count > rows.count {
                Text("+\(table.rows.count - rows.count) rows")
                    .font(Theme.Typography.caption)
                    .padding(Theme.Space.xs)
                    .background(Theme.cardBackground)
            }
        }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell.isEmpty ? "—" : cell)
                    .font(header ? Theme.Typography.caption.weight(.semibold) : Theme.Typography.caption)
                    .foregroundStyle(header ? Theme.Ink.secondary : Color.primary)
                    .lineLimit(compact ? 2 : 4)
                    .frame(width: compact ? 112 : 168, alignment: .leading)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, Theme.Space.s)
                    .background(header ? Theme.pageBackground : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                    }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

private struct HogQLCartesianChart: View {
    let data: HogQLChartData
    let display: HogQLDisplay
    let compact: Bool

    private struct DatedPoint: Identifiable {
        let id: String
        let series: String
        let index: Int
        let date: Date
        let value: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Group {
                if data.xColumn.scalar.isDate, let dated = datedPoints {
                    Chart(dated) { point in
                        marks(x: point.date, value: point.value, series: point.series)
                    }
                } else if data.xColumn.scalar.isNumeric {
                    Chart {
                        ForEach(Array(data.series.enumerated()), id: \.offset) { _, series in
                            ForEach(series.points) { point in
                                if case .number(let x) = point.x {
                                    marks(x: x, value: point.value, series: series.label)
                                }
                            }
                        }
                    }
                } else {
                    Chart {
                        ForEach(Array(data.series.enumerated()), id: \.offset) { _, series in
                            ForEach(series.points) { point in
                                marks(x: point.x.label, value: point.value, series: series.label)
                            }
                        }
                    }
                }
            }
            .frame(height: compact ? 180 : 300)
            .chartForegroundStyleScale(range: data.series.indices.map { SeriesPalette.color(at: $0) })

            if data.series.count > 1 {
                InsightLegend(entries: data.series.enumerated().map { index, series in
                    InsightLegend.Entry(
                        label: series.label,
                        slot: index,
                        total: series.points.reduce(0) { $0 + $1.value }
                    )
                })
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    @ChartContentBuilder
    private func marks<X: Plottable>(x: X, value: Double, series: String) -> some ChartContent {
        switch display {
        case .area:
            AreaMark(x: .value(data.xColumn.name, x), y: .value(series, value))
                .foregroundStyle(by: .value("Series", series))
                .opacity(0.28)
            LineMark(x: .value(data.xColumn.name, x), y: .value(series, value))
                .foregroundStyle(by: .value("Series", series))
                .symbol(by: .value("Series", series))
        case .bar:
            BarMark(x: .value(data.xColumn.name, x), y: .value(series, value))
                .foregroundStyle(by: .value("Series", series))
                .position(by: .value("Series", series))
        case .stackedBar:
            BarMark(x: .value(data.xColumn.name, x), y: .value(series, value))
                .foregroundStyle(by: .value("Series", series))
        default:
            LineMark(x: .value(data.xColumn.name, x), y: .value(series, value))
                .foregroundStyle(by: .value("Series", series))
                .symbol(by: .value("Series", series))
        }
    }

    private var datedPoints: [DatedPoint]? {
        let parser = ISO8601DateFormatter()
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd"
        var values: [DatedPoint] = []
        for series in data.series {
            for point in series.points {
                guard case .date(let raw) = point.x,
                      let date = parser.date(from: raw) ?? fallback.date(from: raw)
                else { return nil }
                values.append(DatedPoint(
                    id: "\(series.id)-\(point.row)",
                    series: series.label,
                    index: point.row,
                    date: date,
                    value: point.value
                ))
            }
        }
        return values.isEmpty ? nil : values
    }

    private var summary: String {
        let points = data.series.reduce(0) { $0 + $1.points.count }
        return "\(data.series.count) series with \(points) values by \(data.xColumn.name)"
    }
}

private struct HogQLPieView: View {
    let slices: [HogQLPieSlice]
    let compact: Bool

    var body: some View {
        let shown = Array(slices.prefix(compact ? 8 : slices.count))
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Chart(Array(shown.enumerated()), id: \.offset) { index, slice in
                SectorMark(
                    angle: .value("Value", max(slice.value, 0)),
                    innerRadius: .ratio(0.48),
                    angularInset: 1
                )
                .foregroundStyle(SeriesPalette.color(at: index))
            }
            .frame(height: compact ? 180 : 260)
            ForEach(Array(shown.enumerated()), id: \.offset) { index, slice in
                HStack {
                    Image(systemName: SeriesPalette.symbol(at: index))
                        .foregroundStyle(SeriesPalette.color(at: index))
                    Text(slice.label).lineLimit(2)
                    Spacer()
                    Text(slice.value.formatted()).monospacedDigit()
                }
                .font(Theme.Typography.caption)
                .accessibilityElement(children: .combine)
            }
            if shown.count < slices.count {
                Text("Compact view hides \(slices.count - shown.count) slices")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
    }
}

private struct HogQLHeatmapView: View {
    let data: HogQLHeatmapData
    let compact: Bool

    var body: some View {
        let xLabels = Array(data.xLabels.prefix(compact ? 6 : data.xLabels.count))
        let yLabels = Array(data.yLabels.prefix(compact ? 6 : data.yLabels.count))
        let maximum = max(data.cells.map(\.value).max() ?? 1, 1)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(yLabels, id: \.self) { y in
                    HStack(spacing: Theme.Space.xs) {
                        Text(y)
                            .font(Theme.Typography.caption)
                            .frame(width: 80, alignment: .trailing)
                        ForEach(xLabels, id: \.self) { x in
                            HogQLHeatmapValueCell(
                                x: x,
                                y: y,
                                value: data.cells.first(where: { $0.x == x && $0.y == y })?.value,
                                maximum: maximum
                            )
                        }
                    }
                }
                HStack(spacing: Theme.Space.xs) {
                    Color.clear.frame(width: 80, height: 1)
                    ForEach(xLabels, id: \.self) { x in
                        Text(x)
                            .font(Theme.Typography.caption)
                            .frame(width: 58)
                            .lineLimit(2)
                    }
                }
            }
        }
        if data.wasTruncated {
            Text("Heatmap limited to the first 400 populated cells")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
        if compact, data.xLabels.count > xLabels.count || data.yLabels.count > yLabels.count {
            let hiddenX = data.xLabels.count - xLabels.count
            let hiddenY = data.yLabels.count - yLabels.count
            Text("Compact view hides \(hiddenX) columns and \(hiddenY) rows")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }
}

/// Kept separate from the grid so SwiftUI does not have to infer the cell's
/// formatting, colour arithmetic, clipping, and accessibility label inside
/// two nested `ForEach` builders. That expression crosses the visionOS
/// compiler's type-check budget even though iOS and macOS accept it.
private struct HogQLHeatmapValueCell: View {
    let x: String
    let y: String
    let value: Double?
    let maximum: Double

    private var text: String { value?.formatted() ?? "—" }
    private var spokenValue: String { value?.formatted() ?? "no value" }
    private var intensity: Double {
        min(max(0.08 + 0.78 * ((value ?? 0) / maximum), 0.08), 0.86)
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption.monospacedDigit())
            .frame(width: 58, height: 44)
            .background(SeriesPalette.color(at: 0).opacity(intensity))
            .clipShape(.rect(cornerRadius: Theme.Radius.small))
            .accessibilityLabel("\(x), \(y): \(spokenValue)")
    }
}

private struct HogQLBoldNumberView: View {
    let value: JSONValue?

    private var displayedValue: String {
        guard let description = value?.tabularDescription, !description.isEmpty else { return "—" }
        return description
    }

    var body: some View {
        Text(displayedValue)
            .font(Theme.Typography.metric)
            .monospacedDigit()
            .frame(maxWidth: .infinity, minHeight: 160)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(displayedValue == "—" ? "No value" : displayedValue)
    }
}
