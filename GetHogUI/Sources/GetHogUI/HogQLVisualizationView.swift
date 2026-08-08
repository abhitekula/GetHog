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
    public var timeZone: TimeZone

    public init(
        visualization: HogQLVisualization,
        compact: Bool = true,
        title: String = "",
        timeZone: TimeZone = ProjectChartTimeZone.fallback
    ) {
        self.visualization = visualization
        self.compact = compact
        self.title = title
        self.timeZone = timeZone
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
                HogQLCartesianChart(
                    data: data,
                    display: display,
                    compact: compact,
                    timeZone: timeZone
                )
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
        ScrollView(scrollAxes) {
            LazyVStack(alignment: .leading, spacing: 0) {
                tableRow(table.columns.map(\.name), header: true, rowIndex: nil)
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    tableRow(
                        row.map(\.tabularDescription),
                        header: false,
                        rowIndex: rowIndex
                    )
                }
            }
        }
        .accessibilityIdentifier("gethog.hogql-result-table")
        .frame(maxHeight: compact ? nil : 420)
        .overlay(alignment: .bottomTrailing) {
            if compact, table.rows.count > rows.count {
                Text("+\(table.rows.count - rows.count) rows")
                    .font(Theme.Typography.caption)
                    .padding(Theme.Space.xs)
                    .background(Theme.cardBackground)
            }
        }
    }

    private var scrollAxes: Axis.Set {
        HogQLTableLayout.allowsVerticalScrolling(compact: compact)
            ? [.horizontal, .vertical]
            : .horizontal
    }

    private func tableRow(_ cells: [String], header: Bool, rowIndex: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { columnIndex, cell in
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
                    .accessibilityIdentifier(
                        header
                            ? "gethog.hogql-table.column.\(columnIndex)"
                            : "gethog.hogql-table.row.\(rowIndex ?? 0).cell.\(columnIndex)"
                    )
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

enum HogQLTableLayout {
    static func allowsVerticalScrolling(compact: Bool) -> Bool {
        !compact
    }
}

struct HogQLSeriesStyle: Equatable {
    let key: String
    let label: String
    let slot: Int
}

struct HogQLDateAxisConfiguration: Equatable {
    let includesTime: Bool
    let includesSeconds: Bool
    let includesYear: Bool

    init(includesTime: Bool = false, includesSeconds: Bool = false, includesYear: Bool = false) {
        self.includesTime = includesTime
        self.includesSeconds = includesSeconds
        self.includesYear = includesYear
    }
}

enum HogQLCartesianLayout {
    enum XAxisPlacement: Equatable {
        case paddedDate
        case standard
    }

    enum DateAxisLabelStyle: Equatable {
        case inline
        case stacked
    }

    static func xAxisPlacement(
        for scalar: HogQLColumnScalar,
        hasParsedDates: Bool
    ) -> XAxisPlacement {
        scalar.isDate && hasParsedDates ? .paddedDate : .standard
    }

    static func hidesBuiltInLegend(seriesCount: Int) -> Bool {
        seriesCount > 1
    }

    static func seriesStyles(for series: [HogQLChartSeries]) -> [HogQLSeriesStyle] {
        let needsStableKeys = series.count > 1
        return series.enumerated().map { index, series in
            HogQLSeriesStyle(
                key: needsStableKeys ? series.id : series.label,
                label: series.label,
                slot: index
            )
        }
    }

    static func dateScalePadding(textScale: CGFloat) -> CGFloat {
        min(34 * max(textScale, 1), 96)
    }

    static func dateAxisIncludesTime(
        dates: [Date],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        dates.contains { date in
            let components = calendar.dateComponents(
                [.hour, .minute, .second, .nanosecond],
                from: date
            )
            return components.hour != 0
                || components.minute != 0
                || components.second != 0
                || components.nanosecond != 0
        }
    }

    static func dateAxisConfiguration(
        dates: [Date],
        calendar: Calendar = .autoupdatingCurrent
    ) -> HogQLDateAxisConfiguration {
        let includesTime = dateAxisIncludesTime(dates: dates, calendar: calendar)
        let includesSeconds = dates.contains { date in
            let components = calendar.dateComponents([.second, .nanosecond], from: date)
            return components.second != 0 || components.nanosecond != 0
        }
        let years = Set(dates.compactMap { calendar.dateComponents([.year], from: $0).year })
        return HogQLDateAxisConfiguration(
            includesTime: includesTime,
            includesSeconds: includesSeconds,
            includesYear: years.count > 1
        )
    }

    static func dateAxisLabelStyle(isAccessibilitySize: Bool) -> DateAxisLabelStyle {
        isAccessibilitySize ? .stacked : .inline
    }
}

private struct HogQLCartesianChart: View {
    let data: HogQLChartData
    let display: HogQLDisplay
    let compact: Bool
    let timeZone: TimeZone

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var textScale: CGFloat = 1

    private struct DatedPoint: Identifiable {
        let id: String
        let seriesKey: String
        let seriesLabel: String
        let index: Int
        let date: Date
        let value: Double
    }

    var body: some View {
        let seriesStyles = HogQLCartesianLayout.seriesStyles(for: data.series)
        let datedPoints = parsedDatedPoints(seriesStyles: seriesStyles)
        let dateAxisConfiguration = HogQLCartesianLayout.dateAxisConfiguration(
            dates: datedPoints?.map(\.date) ?? [],
            calendar: projectCalendar
        )

        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Group {
                if data.xColumn.scalar.isDate, let dated = datedPoints {
                    Chart(dated) { point in
                        marks(
                            x: point.date,
                            value: point.value,
                            seriesKey: point.seriesKey,
                            seriesLabel: point.seriesLabel
                        )
                    }
                    .chartXScale(
                        range: .plotDimension(
                            padding: HogQLCartesianLayout.dateScalePadding(textScale: textScale)
                        )
                    )
                } else if data.xColumn.scalar.isNumeric {
                    Chart {
                        ForEach(Array(data.series.enumerated()), id: \.offset) { index, series in
                            ForEach(series.points) { point in
                                if case .number(let x) = point.x {
                                    marks(
                                        x: x,
                                        value: point.value,
                                        seriesKey: seriesStyles[index].key,
                                        seriesLabel: series.label
                                    )
                                }
                            }
                        }
                    }
                } else {
                    Chart {
                        ForEach(Array(data.series.enumerated()), id: \.offset) { index, series in
                            ForEach(series.points) { point in
                                marks(
                                    x: point.x.label,
                                    value: point.value,
                                    seriesKey: seriesStyles[index].key,
                                    seriesLabel: series.label
                                )
                            }
                        }
                    }
                }
            }
            .chartXAxis {
                switch HogQLCartesianLayout.xAxisPlacement(
                    for: data.xColumn.scalar,
                    hasParsedDates: datedPoints != nil
                ) {
                case .paddedDate:
                    AxisMarks(
                        preset: .aligned,
                        values: .automatic(desiredCount: xAxisTickCount)
                    ) { value in
                        AxisGridLine()
                        if let date = value.as(Date.self) {
                            let label = HogQLDateAxisLabel(
                                date: date,
                                configuration: dateAxisConfiguration,
                                calendar: projectCalendar,
                                timeZone: timeZone
                            )
                            AxisValueLabel {
                                VStack(spacing: 0) {
                                    switch HogQLCartesianLayout.dateAxisLabelStyle(
                                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                                    ) {
                                    case .inline:
                                        Text(label.day)
                                    case .stacked:
                                        Text(label.month)
                                        Text(label.dayOfMonth)
                                        if dateAxisConfiguration.includesYear {
                                            Text(label.year)
                                        }
                                    }
                                    if dateAxisConfiguration.includesTime {
                                        Text(label.time)
                                            .foregroundStyle(Theme.Ink.tertiary)
                                    }
                                }
                                .multilineTextAlignment(.center)
                            }
                            .font(.caption2)
                        }
                    }
                case .standard:
                    AxisMarks(values: .automatic(desiredCount: xAxisTickCount)) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(
                    position: .leading,
                    values: .automatic(desiredCount: yAxisTickCount)
                ) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: (compact ? 180 : 300) * min(textScale, 1.5))
            .chartForegroundStyleScale(
                domain: seriesStyles.map(\.key),
                range: seriesStyles.map { SeriesPalette.color(at: $0.slot) }
            )
            .chartLegend(
                HogQLCartesianLayout.hidesBuiltInLegend(seriesCount: data.series.count)
                    ? .hidden
                    : .visible
            )

            if seriesStyles.count > 1 {
                InsightLegend(entries: zip(seriesStyles, data.series).map { style, series in
                    InsightLegend.Entry(
                        label: style.label,
                        slot: style.slot,
                        total: series.points.reduce(0) { $0 + $1.value }
                    )
                })
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    private var xAxisTickCount: Int {
        dynamicTypeSize.thinnedAxisCount(compact ? 3 : 5)
    }

    private var yAxisTickCount: Int {
        dynamicTypeSize.thinnedAxisCount(compact ? 4 : 5)
    }

    @ChartContentBuilder
    private func marks<X: Plottable>(
        x: X,
        value: Double,
        seriesKey: String,
        seriesLabel: String
    ) -> some ChartContent {
        switch display {
        case .area:
            AreaMark(x: .value(data.xColumn.name, x), y: .value(seriesLabel, value))
                .foregroundStyle(by: .value("Series", seriesKey))
                .opacity(0.28)
            LineMark(x: .value(data.xColumn.name, x), y: .value(seriesLabel, value))
                .foregroundStyle(by: .value("Series", seriesKey))
                .symbol(by: .value("Series", seriesKey))
        case .bar:
            BarMark(x: .value(data.xColumn.name, x), y: .value(seriesLabel, value))
                .foregroundStyle(by: .value("Series", seriesKey))
                .position(by: .value("Series", seriesKey))
        case .stackedBar:
            BarMark(x: .value(data.xColumn.name, x), y: .value(seriesLabel, value))
                .foregroundStyle(by: .value("Series", seriesKey))
        default:
            LineMark(x: .value(data.xColumn.name, x), y: .value(seriesLabel, value))
                .foregroundStyle(by: .value("Series", seriesKey))
                .symbol(by: .value("Series", seriesKey))
        }
    }

    private var projectCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        return calendar
    }

    private func parsedDatedPoints(seriesStyles: [HogQLSeriesStyle]) -> [DatedPoint]? {
        let parser = ISO8601DateFormatter()
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.calendar = projectCalendar
        fallback.timeZone = timeZone
        fallback.dateFormat = "yyyy-MM-dd"
        var values: [DatedPoint] = []
        for (index, series) in data.series.enumerated() {
            for point in series.points {
                guard case .date(let raw) = point.x,
                      let date = parser.date(from: raw) ?? fallback.date(from: raw)
                else { return nil }
                values.append(DatedPoint(
                    id: "\(series.id)-\(point.row)",
                    seriesKey: seriesStyles[index].key,
                    seriesLabel: series.label,
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

struct HogQLDateAxisLabel: Equatable, Sendable {
    let day: String
    let month: String
    let dayOfMonth: String
    let year: String
    let time: String

    init(
        date: Date,
        configuration: HogQLDateAxisConfiguration = HogQLDateAxisConfiguration(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        let base = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        var dayStyle = base.month(.abbreviated).day()
        if configuration.includesYear {
            dayStyle = dayStyle.year()
        }
        day = date.formatted(dayStyle)
        month = date.formatted(base.month(.abbreviated))
        dayOfMonth = date.formatted(base.day())
        year = date.formatted(base.year())
        var timeStyle = base.hour().minute()
        if configuration.includesSeconds {
            timeStyle = timeStyle.second()
        }
        time = date.formatted(timeStyle)
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
