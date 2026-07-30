import Charts
import GetHogKit
import SwiftUI

/// Renders an `InsightRenderModel`.
///
/// Four of the nine forms ship an `AXChartDescriptor`: time series, bar value,
/// lifecycle and stickiness. Those are the ones drawn as a plot, where every
/// figure exists only as geometry and the chart rotor is the sole way to reach
/// the numbers at all.
///
/// Funnel, retention, paths and big number deliberately do not, and should not.
/// They are already laid out as rows of text, and each row carries a combined
/// label of its own — "Step 2, Second page view: 45, 33% of the first step",
/// "Week 0, interval 0: 100%, interval 1: 1%…". A descriptor over the top of
/// that would give the same numbers a second, parallel representation: the
/// reader would meet every figure twice, once by swiping and once in the rotor,
/// with nothing saying the two were the same data. The row label is also the
/// only form that survives the accessibility-size reflows these four views make
/// — retention stops being a grid past the threshold, funnel and paths break
/// their rows in two — and a descriptor's fixed axes cannot describe a layout
/// that changes shape underneath them.
///
/// Multi-series charts always carry a legend plus symbol marks so identity never
/// rests on colour alone — which is also the relief the light-mode palette's
/// contrast warning requires.
struct InsightChartView: View {
    let model: InsightRenderModel
    var compact: Bool = true
    var webURL: URL?
    /// The insight's own name, for the chart descriptor to announce.
    ///
    /// Defaulted, and left empty at exactly one call site: `ChartImageRenderer`
    /// rasterises the chart to a PNG, which has no accessibility tree for a
    /// descriptor to land in, and prints the title above the plot as pixels
    /// instead. Every call site a person can actually navigate passes one.
    var title: String = ""

    var body: some View {
        switch model {
        case .timeSeries(let series, let style):
            TimeSeriesChart(series: series, style: style, compact: compact, title: title)
        case .barValue(let bars):
            BarValueChart(bars: bars, compact: compact, title: title)
        case .bigNumber(let number):
            BigNumberView(number: number)
        case .funnel(let groups):
            FunnelChart(groups: groups, compact: compact)
        case .lifecycle(let series):
            LifecycleChart(series: series, compact: compact, title: title)
        case .retention(let grid):
            RetentionGridView(grid: grid, compact: compact)
        case .stickiness(let series):
            StickinessChart(series: series, compact: compact, title: title)
        case .paths(let graph):
            PathsFlowView(graph: graph, compact: compact)
        case .unsupported(let kind):
            UnsupportedInsightCard(kind: kind, webURL: webURL)
        }
    }
}

// MARK: - Legend

/// A chart's legend, drawn below the plot instead of inside it.
///
/// `chartLegend(.visible)` lays the legend out *within* the height the chart's
/// own `.frame` grants and gives the plot whatever is left. Measured on the
/// "Growth accounting" tile at AX5: four statuses, each on its own line at
/// accessibility size, took about 400pt of a 255pt frame and left a plot strip
/// roughly 40pt tall — a tile that was 90% legend and 10% unreadable chart.
/// Below the chart the legend costs the *tile* the height it needs, and the plot
/// keeps the whole of the frame.
///
/// Dropping the legend instead is not on offer: a stacked bar segment is
/// identified by its colour and nothing else, three light-mode palette hues fall
/// below 3:1, and this legend is the relief the palette's contrast rule requires
/// — its symbol carries the identity without hue. Printing each series' total
/// makes the accessibility-size trade the same one retention's cohort list
/// makes: less chart, more figures, never less data.
struct InsightLegend: View {
    struct Entry {
        let label: String
        /// Palette slot rather than row position, so the swatch cannot drift
        /// from the mark it names.
        let slot: Int
        let total: Double
        /// Churn reads as a loss, so its total is signed, not absolute.
        var isNegative: Bool = false
    }

    let entries: [Entry]
    /// What the totals count. VoiceOver reads a legend row on its own, without
    /// the chart descriptor that would otherwise name the unit.
    var unit: String = ""

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // Indexed, not keyed by label: two series of a breakdown can carry
            // the same label, and a duplicate `ForEach` id drops one of them.
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                row(entry)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(for: entry))
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        // The same reflow as `FunnelStepRow`, for the same measured reason: at
        // AX5 "Resurrecting" set in `.caption` is wider than a phone tile, so a
        // name and a figure sharing one row leave the figure a column a couple
        // of characters wide.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                name(entry)
                total(entry)
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                name(entry)
                Spacer(minLength: Theme.Space.s)
                total(entry)
            }
        }
    }

    private func name(_ entry: Entry) -> some View {
        HStack(spacing: Theme.Space.s) {
            // Scales with the label it identifies: pinned to a fixed size, the
            // one part of this legend that does not depend on hue shrinks to a
            // speck for precisely the readers it exists for.
            Image(systemName: SeriesPalette.symbol(at: entry.slot))
                .font(.caption2)
                .foregroundStyle(SeriesPalette.color(at: entry.slot))
            Text(entry.label)
                .font(.caption)
        }
    }

    private func total(_ entry: Entry) -> some View {
        Text(entry.total.compactFormatted)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(entry.isNegative ? Theme.Status.criticalInk : .primary)
    }

    private func accessibilityLabel(for entry: Entry) -> String {
        let total = entry.total.formatted()
        return unit.isEmpty ? "\(entry.label), total \(total)" : "\(entry.label): \(total) \(unit)"
    }
}

// MARK: - Lifecycle

struct LifecycleChart: View {
    let series: [LifecycleSeries]
    var compact: Bool
    var title: String = ""

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// See `TimeSeriesChart.textScale`; this chart had the same fixed height and
    /// the same fixed axis count.
    @ScaledMetric(relativeTo: .caption2) private var textScale: CGFloat = 1

    /// One stacked segment, on the date its day label already encodes.
    private struct DatedBar: Identifiable {
        let id: String
        let status: String
        let date: Date
        let value: Double
    }

    /// The bars on a real date axis, or `nil` when a day label will not parse.
    ///
    /// The days used to be plotted as the strings PostHog sends, which makes the
    /// x-axis *categorical* — and a categorical axis draws one label per
    /// category and holds each label to its band's width, whatever
    /// `desiredCount` asks for. That is why routing the count through
    /// `thinnedAxisCount` fixed nothing here: at AX5 the five bands of "Growth
    /// accounting" were about 50pt each, so all five labels rendered as "2…",
    /// the first character of "2026-06-28". A date scale thins to the count it
    /// is handed and places what survives on a continuous axis, where a label is
    /// not confined to a band — which is the width the thinning was supposed to
    /// buy. `Point.date` has carried the parsed date all along.
    private var datedBars: [DatedBar]? {
        var bars: [DatedBar] = []
        for s in series {
            for point in s.points {
                guard let date = point.date else { return nil }
                bars.append(
                    DatedBar(
                        id: "\(s.status.rawValue)-\(point.day)",
                        status: s.status.title,
                        date: date,
                        value: point.value
                    )
                )
            }
        }
        return bars.isEmpty ? nil : bars
    }

    /// The reporting interval, read off the gap between the first two days.
    ///
    /// A `BarMark` on a date axis is exactly as wide as the unit it is given,
    /// and lifecycle is not always daily — the demo's "Growth accounting" is
    /// weekly — so a hardcoded `.day` would draw a one-day sliver in the middle
    /// of every seven-day slot.
    private func interval(of bars: [DatedBar]) -> Calendar.Component {
        let days = Set(bars.map(\.date)).sorted()
        guard days.count >= 2 else { return .day }
        let gap = days[1].timeIntervalSince(days[0])
        if gap <= 7_200 { return .hour }
        if gap <= 129_600 { return .day }
        if gap <= 864_000 { return .weekOfYear }
        return .month
    }

    private var xAxisTickCount: Int {
        dynamicTypeSize.thinnedAxisCount(compact ? 3 : 6)
    }

    private var yAxisTickCount: Int {
        dynamicTypeSize.thinnedAxisCount(compact ? 4 : 5)
    }

    /// Past the accessibility threshold the legend has to leave the chart's
    /// frame — see `InsightLegend`. The full-size chart draws it below too,
    /// where it replaces the built-in one rather than doubling it.
    private var legendBelowChart: Bool {
        !compact || dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                if let datedBars {
                    ForEach(datedBars) { bar in
                        BarMark(
                            x: .value("Day", bar.date, unit: interval(of: datedBars)),
                            y: .value("Users", bar.value)
                        )
                        .foregroundStyle(by: .value("Status", bar.status))
                    }
                } else {
                    // Only for labels that are not dates at all. The axis below
                    // stays categorical to match, with the truncation that
                    // implies — better than dropping points that will not parse.
                    ForEach(series, id: \.status) { s in
                        ForEach(s.points, id: \.day) { point in
                            BarMark(
                                x: .value("Day", point.day),
                                y: .value("Users", point.value)
                            )
                            .foregroundStyle(by: .value("Status", s.status.title))
                        }
                    }
                }
                // Dormant is drawn below zero, so the axis line is the reference
                // between growth and churn rather than decoration.
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartForegroundStyleScale(
                domain: series.map(\.status.title),
                range: series.map { SeriesPalette.color(at: $0.status.paletteSlot) }
            )
            .chartXAxis {
                if datedBars != nil {
                    AxisMarks(preset: .aligned, values: .automatic(desiredCount: xAxisTickCount)) { _ in
                        AxisGridLine()
                        // Short by construction: "Jun 28" is a quarter of
                        // "2026-06-28", and the label the axis kept has to fit
                        // in whatever the y-axis labels left of the tile.
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: xAxisTickCount)) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
            }
            .chartYAxis {
                // Thinned like the x-axis, and for the same reason once the
                // height stopped being free: `AxisMarks(position: .leading)`
                // alone asked for the default four-or-so labels at the default
                // axis font, and at AX5 they landed on top of each other in a
                // smear at the left edge — "-40" and "20" occupying the same
                // 40pt. See `TimeSeriesChart.height` for why the room they stack
                // in does not grow with them.
                AxisMarks(position: .leading, values: .automatic(desiredCount: yAxisTickCount)) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartLegend(legendBelowChart ? .hidden : .visible)
            .frame(height: (compact ? 170 : 280) * min(textScale, 1.5))
            .accessibilityChartDescriptor(LifecycleDescriptor(series: series, title: title))

            if legendBelowChart {
                InsightLegend(
                    entries: series.map {
                        InsightLegend.Entry(
                            label: $0.status.title,
                            slot: $0.status.paletteSlot,
                            total: $0.total,
                            isNegative: $0.status.isNegative
                        )
                    },
                    unit: "users"
                )
            }
        }
    }
}

// MARK: - Retention

struct RetentionGridView: View {
    let grid: RetentionGrid
    var compact: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The cohort labels are dates — "Week of Jan 12" — and a fixed 62pt column
    /// clipped them at the default size, never mind once the text scales.
    @ScaledMetric(relativeTo: .caption2) private var cohortColumn: CGFloat = 62

    /// Columns are cut from six because the cells now carry `.caption2` instead
    /// of a fixed 9pt: the widest cell reads "100%", and six of those beside the
    /// cohort column no longer cross a phone tile. The list is not bound by
    /// width, so it shows what the grid used to.
    private var visibleIntervals: Int {
        let limit = dynamicTypeSize.isAccessibilitySize
            ? (compact ? 6 : 12)
            : (compact ? 4 : 12)
        return min(grid.intervalCount, limit)
    }

    var body: some View {
        // Past the accessibility threshold this stops being a grid.
        //
        // A grid spends width to buy density, and at those sizes there is no
        // width left to spend: the cohort column has scaled, three columns of
        // "100%" is all a phone tile has room for, and a retention insight
        // showing three intervals is not worth reading. The same figures as a
        // list are, and vertical room is the one thing a tile can always find.
        if dynamicTypeSize.isAccessibilitySize {
            cohortList
        } else {
            cohortGrid
        }
    }

    private var cohortGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Column headers
            HStack(spacing: 2) {
                Text("Cohort")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: cohortColumn, alignment: .leading)
                ForEach(0..<visibleIntervals, id: \.self) { index in
                    Text("\(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(grid.cohorts) { cohort in
                HStack(spacing: 2) {
                    // Two lines, because even a scaled column is narrower than
                    // "Week of Jan 12" set at `.caption2` — wrapping shows the
                    // whole date where one line showed "Week of Ja…".
                    Text(cohort.label)
                        .font(.caption2)
                        .lineLimit(2)
                        .frame(width: cohortColumn, alignment: .leading)

                    ForEach(0..<visibleIntervals, id: \.self) { index in
                        RetentionCell(
                            rate: index < cohort.counts.count ? cohort.rate(at: index) : nil,
                            count: index < cohort.counts.count ? cohort.counts[index] : nil
                        )
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: cohort))
            }
        }
    }

    /// One block per cohort, one row per interval.
    ///
    /// Each row still carries the grid's tint, because that is what makes a
    /// decay curve scannable rather than a column of numbers to be read one at a
    /// time — and the same `.primary` on it, for the same contrast reason.
    /// VoiceOver is handed the identical per-cohort label either way, so the two
    /// layouts are indistinguishable to it.
    private var cohortList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(grid.cohorts) { cohort in
                VStack(alignment: .leading, spacing: 3) {
                    Text(cohort.label)
                        .font(.caption.weight(.semibold))

                    ForEach(0..<min(visibleIntervals, cohort.counts.count), id: \.self) { index in
                        HStack(spacing: Theme.Space.s) {
                            Text("Interval \(index)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: Theme.Space.s)
                            Text(cohort.rate(at: index), format: .percent.precision(.fractionLength(0)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RetentionCell.fill(for: cohort.rate(at: index)),
                                    in: .rect(cornerRadius: 3)
                                )
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: cohort))
            }
        }
    }

    private func accessibilityLabel(for cohort: RetentionCohort) -> String {
        let rates = (0..<min(visibleIntervals, cohort.counts.count)).map { index in
            "interval \(index): \(cohort.rate(at: index).formatted(.percent.precision(.fractionLength(0))))"
        }
        return "\(cohort.label), \(rates.joined(separator: ", "))"
    }
}

/// A single retention cell.
///
/// Sequential magnitude, so it is one hue light→dark rather than a rainbow, and
/// the percentage is always printed — intensity alone is not readable enough,
/// and printing it is also the relief the light palette's contrast rule requires.
struct RetentionCell: View {
    let rate: Double?
    let count: Double?

    /// One hue, floor to full. Declared once because the list layout draws the
    /// same tint, and two copies of a ramp are two ramps waiting to disagree.
    static func fill(for rate: Double) -> Color {
        SeriesPalette.color(at: 0).opacity(0.1 + 0.75 * rate)
    }

    var body: some View {
        Group {
            if let rate {
                Text(rate, format: .percent.precision(.fractionLength(0)))
                    // A fixed 9pt ignored Dynamic Type outright, so the one
                    // insight that is nothing but small numbers stayed 9pt at
                    // every accessibility size.
                    .font(.caption2.monospacedDigit())
                    // One colour at every intensity. White was switched in above
                    // 55% retention, where the fill has only reached part of its
                    // strength: about 1.9:1 at the switch and still only 3.5:1
                    // at 100% — worst on exactly the cells worth reading.
                    // `.primary` clears 4.5:1 against the densest fill in both
                    // modes.
                    .foregroundStyle(.primary)
                    // A floor, not a cap: the cell grows with the text.
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background(Self.fill(for: rate), in: .rect(cornerRadius: 3))
            } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: 22)
            }
        }
    }
}

// MARK: - Time series

struct TimeSeriesChart: View {
    let series: [Series]
    var style: TimeSeriesStyle = .line
    var compact: Bool
    var title: String = ""

    @State private var selectedDate: Date?
    /// Width of the visible window, in seconds. `nil` means the whole series,
    /// which is the state every chart starts in — zoom is opt-in, so a tile
    /// always first shows all the data it has.
    @State private var zoomSpan: TimeInterval?
    /// Live pinch factor. Kept separate from `zoomSpan` so the gesture can be
    /// abandoned without having mutated the committed window.
    @GestureState private var pinch: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A chart is laid out in points; the labels inside it are not. This is how
    /// the two are kept in step — see `height`.
    @ScaledMetric(relativeTo: .caption2) private var textScale: CGFloat = 1

    /// Grows with the text, to a point.
    ///
    /// The y-axis labels stack vertically inside this height, so a height fixed
    /// in points is a height that runs out of room for them. Capped at half
    /// again: past that a single tile stops fitting on a phone screen and the
    /// dashboard becomes a scroll through one chart at a time.
    ///
    /// The cap is why the y-axis has to be thinned as well. `.caption2` is about
    /// 4.3× its default size at AX5 while this height grows 1.5×, so the room
    /// each label stacks in shrinks by roughly three as the labels themselves
    /// grow — the opposite of what an earlier note here claimed. It is also why
    /// nothing but plot and axes may live inside this frame: a legend sharing it
    /// is what flattened the lifecycle tile's plot to a 40pt strip.
    private var height: CGFloat { (compact ? 170 : 280) * min(textScale, 1.5) }

    private var xAxisTickCount: Int {
        dynamicTypeSize.thinnedAxisCount(compact ? 3 : 5)
    }

    private var yAxisTickCount: Int {
        dynamicTypeSize.thinnedAxisCount(compact ? 4 : 5)
    }

    /// Past the accessibility threshold a multi-series legend leaves the chart's
    /// frame — see `InsightLegend`.
    ///
    /// Tiles only. The full-size chart is followed by `SeriesLegend` on the
    /// detail screen already, so moving this one out as well would print two;
    /// and the export card renders at the default text size, where the built-in
    /// legend costs a single line.
    private var legendBelowChart: Bool {
        compact && series.count > 1 && dynamicTypeSize.isAccessibilitySize
    }

    // MARK: - Zoom and pan

    /// Zoom is confined to the full-size chart.
    ///
    /// A dashboard grid is itself a scroll view full of tiles; making each tile
    /// horizontally scrollable turns an ordinary flick down the page into a
    /// fight over which view owns the drag. The detail chart has the screen to
    /// itself and no such competition.
    private var allowsZoom: Bool { !compact && usesDateAxis && fullSpan != nil }

    private var allDates: [Date] {
        series.compactMap(\.datedPoints).flatMap { $0 }.map(\.date)
    }

    /// Total time covered, or `nil` when there is nothing to span — a single
    /// point, or every point sharing a timestamp.
    private var fullSpan: TimeInterval? {
        guard let first = allDates.min(), let last = allDates.max(), last > first else {
            return nil
        }
        return last.timeIntervalSince(first)
    }

    /// Floor on zoom: roughly three sampling intervals.
    ///
    /// Without it a pinch can reach a window narrower than the gap between two
    /// points, which draws a single mark stranded in empty space and looks like
    /// a rendering fault rather than a zoom.
    private var minimumSpan: TimeInterval {
        guard let fullSpan else { return 1 }
        let pointCount = max(series.map { ($0.datedPoints ?? []).count }.max() ?? 2, 2)
        let interval = fullSpan / Double(pointCount - 1)
        return min(interval * 3, fullSpan)
    }

    /// The window actually drawn, folding in any in-flight pinch.
    private var visibleSpan: TimeInterval {
        guard let fullSpan else { return 1 }
        let base = zoomSpan ?? fullSpan
        return (base / Double(pinch)).clamped(to: minimumSpan...fullSpan)
    }

    private var isZoomed: Bool {
        guard let fullSpan, let zoomSpan else { return false }
        return zoomSpan < fullSpan - 1
    }

    /// True when every series has parseable dates, which lets Swift Charts own
    /// the axis and thin its labels. Plotting day strings categorically forces a
    /// label per category and turns a month of data into unreadable overlap.
    private var usesDateAxis: Bool {
        series.allSatisfy { $0.datedPoints != nil }
    }

    /// The point nearest the scrub position, per series.
    private var selectedPoints: [(series: Series, value: Double, index: Int)] {
        guard let selectedDate else { return [] }
        return series.enumerated().compactMap { index, s in
            guard let dated = s.datedPoints,
                  let nearest = dated.min(by: {
                      abs($0.date.timeIntervalSince(selectedDate))
                          < abs($1.date.timeIntervalSince(selectedDate))
                  })
            else { return nil }
            return (s, nearest.value, index)
        }
    }

    private var selectedLabel: String {
        selectedDate?.formatted(.dateTime.month(.abbreviated).day()) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                // Reserve the row unconditionally so the chart never shifts when
                // a scrub begins.
                scrubReadout
                    .opacity(selectedPoints.isEmpty ? 0 : 1)

                Spacer(minLength: Theme.Space.s)

                // A pinch can be reversed by pinching back, but only if you
                // work out that you are zoomed at all — and a chart showing a
                // slice of its range looks exactly like a chart with less data.
                // This says which it is, and undoes it in one tap.
                if isZoomed {
                    Button {
                        zoomSpan = nil
                        selectedDate = nil
                    } label: {
                        Label("Show all", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(Theme.Typography.caption)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Show the full time range")
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isZoomed)

            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    ForEach(Array((s.datedPoints ?? []).enumerated()), id: \.offset) { _, point in
                        marks(for: point, in: s)
                    }
                }

                if let selectedDate {
                    RuleMark(x: .value("Date", selectedDate))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(range: paletteRange)
            .chartLegend(series.count > 1 && !legendBelowChart ? .visible : .hidden)
            .chartXAxis {
                // The axis owns the format and the thinning; a fixed categorical
                // axis is what produced overlapping labels. What it cannot see
                // is the text size, so the count it is asked for carries that —
                // see `xAxisTickCount`.
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: xAxisTickCount)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                }
            }
            .chartYAxis {
                // Thinned like the x-axis. The note that used to stand here —
                // that these labels stack down a height that scales, so they
                // gain room as they grow — was void the moment that height was
                // capped at 1.5×: see `height`. Left at four, they piled into
                // each other at the left edge of the lifecycle tile at AX5, and
                // this chart's y-axis is drawn by the same rules.
                AxisMarks(position: .leading, values: .automatic(desiredCount: yAxisTickCount)) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartXSelection(value: $selectedDate)
            // Pan. Swift Charts arbitrates the drag between scrolling and
            // scrubbing itself once an axis is scrollable — selection is
            // promoted to press-then-drag — which is why this does not need a
            // hand-rolled gesture mask.
            .chartScrollableAxes(allowsZoom ? .horizontal : [])
            .chartXVisibleDomain(length: visibleSpan)
            // Scrubbing is the one chart interaction nothing on screen hints at,
            // so it gets the tip. Only on the full-size chart: firing this over
            // every tile in a dashboard grid at once would be an infestation.
            .popoverTip(compact ? nil : ChartScrubTip())
            .frame(height: height)
            .simultaneousGesture(allowsZoom ? magnify : nil)
            .sensoryFeedback(.selection, trigger: selectedDate)
            // Fires at the ends of the range, so a pinch that has stopped doing
            // anything says so rather than feeling broken.
            .sensoryFeedback(.levelChange, trigger: isAtZoomLimit)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selectedDate)
            // The descriptor carries the insight's name because the marks
            // underneath it cannot. Swift Charts groups marks into five bands
            // and writes each band's label and value itself: measured here,
            // 'Jun 28, 2026 at 12 AM to Jul 5, 2026 at 12 AM' / 'starts at 10,
            // varies between 10 and 51, ends at 28, $pageview, 7 values'.
            //
            // Per-mark `.accessibilityLabel`/`.accessibilityValue` do not change
            // that — tried, and discarded by the framework at every width: a
            // chart pinched out to 819pt still produced the same five bands with
            // the same synthesised strings. The band's *series name* is the one
            // part a caller can move, and it moves by changing which marks exist
            // — see the hidden `AreaMark` below. Everything else a reader needs
            // (which insight, what the axes measure, the per-point figures) has
            // to come from this descriptor and from the tile's own button label.
            .accessibilityChartDescriptor(TimeSeriesDescriptor(series: series, title: title))
            // VoiceOver has no pinch. This exposes the same two states to the
            // rotor, which is the whole of the feature for anyone not using
            // two fingers.
            .accessibilityZoomAction { action in
                guard let fullSpan else { return }
                switch action.direction {
                case .zoomIn:
                    zoomSpan = (visibleSpan / 2).clamped(to: minimumSpan...fullSpan)
                case .zoomOut:
                    zoomSpan = (visibleSpan * 2).clamped(to: minimumSpan...fullSpan)
                @unknown default:
                    break
                }
            }

            if legendBelowChart {
                InsightLegend(
                    entries: series.enumerated().map { index, s in
                        InsightLegend.Entry(label: s.label, slot: index, total: s.total)
                    }
                )
            }
        }
    }

    /// Pinch to change the visible window.
    ///
    /// Two-fingered, so it does not compete with the one-finger drag that pans
    /// and scrubs. The magnification is only committed on release: updating
    /// `zoomSpan` continuously would re-lay-out the chart on every frame of the
    /// gesture, and Swift Charts re-runs its axis label thinning each time.
    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                guard let fullSpan else { return }
                let committed = ((zoomSpan ?? fullSpan) / Double(value.magnification))
                    .clamped(to: minimumSpan...fullSpan)
                zoomSpan = committed
            }
    }

    private var isAtZoomLimit: Bool {
        guard let fullSpan else { return false }
        return visibleSpan <= minimumSpan || visibleSpan >= fullSpan
    }

    /// The marks for one point.
    ///
    /// Extracted from the `Chart` builder purely because the type checker gave
    /// up on the combined expression once the gradient branch was added; it is
    /// the same content it always was.
    @ChartContentBuilder
    private func marks(for point: (date: Date, value: Double), in s: Series) -> some ChartContent {
        // The insight's own display type decides the mark. Drawing a stacked-bar
        // insight as overlapping lines would read as a different result.
        switch style {
        case .line, .area:
            LineMark(
                x: .value("Date", point.date),
                y: .value("Value", point.value)
            )
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            // Monotone, not catmullRom: catmullRom overshoots between points and
            // would misrepresent the data.
            .interpolationMethod(.monotone)
            .foregroundStyle(by: .value("Series", s.label))

            // A single series gets a gradient beneath it. A bare stroke on a
            // white card is what made these read as wireframes, and with one
            // series there is no ambiguity about whose area it is. Two or more
            // stay unfilled — overlapping washes obscure exactly the crossings
            // the reader came to look at.
            if series.count == 1 {
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Self.areaFill(SeriesPalette.color(at: 0)))
                // The fill is the line plotted a second time, and Swift Charts
                // counted it. Measured on the DAU tile, which has exactly one
                // series: swiping a band announced "varies between 10 and 51,
                // 2 Series" — the second "series" being this gradient. Hidden,
                // the same band names the series it is left with, and reads
                // "…, $pageview, 7 values". One modifier is the whole of the
                // series identity a linear swipe gets.
                .accessibilityHidden(true)
            }

        case .bar, .stackedBar:
            // Swift Charts stacks same-x BarMarks by default, which is exactly
            // stackedBar; plain bars sit side by side.
            BarMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(by: .value("Series", s.label))
            .position(by: style == .bar ? .value("Series", s.label) : .value("Series", ""))
            .cornerRadius(3)
        }
    }

    /// Fades to nothing at the baseline so the fill reads as depth under the
    /// line rather than as a second, solid series.
    static func areaFill(_ color: Color) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.28), color.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var paletteRange: [Color] {
        series.indices.map { SeriesPalette.color(at: $0) }
    }

    /// Floats over the chart while scrubbing rather than sitting above it, so the
    /// plot doesn't jump the moment a finger lands on it.
    private var scrubReadout: some View {
        HStack(spacing: 10) {
            Text(selectedLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(selectedPoints, id: \.index) { entry in
                HStack(spacing: 4) {
                    // The swatch is what ties a figure to its series, so it
                    // tracks the figure rather than staying a 6pt speck beside
                    // text three times its size.
                    Circle()
                        .fill(SeriesPalette.color(at: entry.index))
                        .frame(width: 6 * textScale, height: 6 * textScale)
                    Text(entry.value.compactFormatted)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: .capsule)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

// MARK: - Bar value

struct BarValueChart: View {
    let bars: [BarValue]
    var compact: Bool
    var title: String = ""

    /// Row pitch. Scales because the per-bar labels beside it do; at a fixed
    /// 26pt the labels of neighbouring rows ran into each other.
    @ScaledMetric(relativeTo: .caption2) private var barSlot: CGFloat = 26

    /// Preferred width of the label column, before it is measured against the
    /// tile it actually landed in.
    @ScaledMetric(relativeTo: .caption2) private var labelColumn: CGFloat = 78

    private var visible: [BarValue] {
        Array(bars.prefix(compact ? 6 : 20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The label column is bounded against the width the tile grants.
            // These labels are free text — domains, URLs, breakdown values — and
            // left to size itself the axis pushed "guinevere-horace.example.net"
            // straight off the trailing edge of the tile, with "www.google."
            // overlapping the row below. Held to a share of the width, an
            // over-long label truncates inside its own box instead.
            GeometryReader { geo in
                chart(labelWidth: min(labelColumn, geo.size.width * 0.45))
            }
            .frame(height: CGFloat(visible.count) * barSlot + 20)

            if bars.count > visible.count {
                Text("+\(bars.count - visible.count) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func chart(labelWidth: CGFloat) -> some View {
        Chart(Array(visible.enumerated()), id: \.offset) { index, bar in
            BarMark(
                x: .value("Value", bar.value),
                y: .value("Label", bar.label)
            )
            .foregroundStyle(SeriesPalette.color(at: 0))
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                // Direct labels: the relief the light-mode contrast warning
                // requires, and faster to read than a value axis.
                Text(bar.value.compactFormatted)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisValueLabel {
                    Text(value.as(String.self) ?? "")
                        .font(.caption2)
                        .lineLimit(2)
                        // Middle, because either end can be the distinguishing
                        // part: a tail truncation loses "…example.net" from one
                        // domain and leaves "www.google." indistinguishable from
                        // the next.
                        .truncationMode(.middle)
                        .frame(width: labelWidth, alignment: .leading)
                }
            }
        }
        .accessibilityChartDescriptor(BarValueDescriptor(bars: visible, title: title))
    }
}

// MARK: - Big number

struct BigNumberView: View {
    let number: BigNumber

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(number.value.compactFormatted)
                // The token, not a copy of it: this was the same declaration
                // spelled out inline, free to drift from the type scale.
                // `Typography.metric` already carries the monospaced digits.
                .font(Theme.Typography.metric)
                .contentTransition(.numericText())
            if !number.label.isEmpty {
                Text(number.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number.label): \(number.value.formatted())")
    }
}

// MARK: - Funnel

struct FunnelChart: View {
    let groups: [FunnelGroup]
    var compact: Bool

    /// With a breakdown there is one group per value; on a phone tile only the
    /// first is legible, so the rest are summarised rather than crammed in.
    private var primary: FunnelGroup? { groups.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let primary {
                if let breakdown = primary.breakdownValue, groups.count > 1 {
                    Text(breakdown)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(primary.steps.enumerated()), id: \.offset) { index, step in
                    FunnelStepRow(
                        step: step,
                        index: index,
                        maxCount: primary.steps.first?.count ?? 1
                    )
                }

                if groups.count > 1 {
                    Text("+\(groups.count - 1) more breakdown\(groups.count == 2 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Funnel with \(primary?.steps.count ?? 0) steps, "
            + "\((primary?.conversionRate ?? 0).formatted(.percent.precision(.fractionLength(0...1)))) overall conversion"
        )
    }
}

struct FunnelStepRow: View {
    let step: FunnelStep
    let index: Int
    let maxCount: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The bar is the only non-textual reading of the step, so it scales too —
    /// a 6pt rule under 32pt text reads as a hairline, not as a quantity.
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 6

    private var fraction: Double {
        maxCount > 0 ? step.count / maxCount : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The step name is the funnel's whole content and the only elastic
            // thing on the row, so it is what gave way: at AX3 the steps read
            // "1. First p…", "2. Second…", "3. Third pa…" and stopped being
            // distinguishable from one another. Two lines, and past the
            // accessibility threshold the count and its share step off the name's
            // row entirely rather than squeezing it to nothing.
            if dynamicTypeSize.isAccessibilitySize {
                name
                HStack(spacing: Theme.Space.s) { counts }
            } else {
                HStack {
                    name
                    Spacer()
                    counts
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(SeriesPalette.color(at: 0))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: barHeight)
            // The fill is clipped by the track's shape, in the track's
            // coordinate space. It cannot clip itself: a `Capsule` rounds at
            // `min(width, height) / 2`, so at the `max(2, …)` floor below the
            // fill is 2pt wide and rounds at 1pt while the track rounds at
            // `barHeight / 2` — leaving the fill's corners outside the track's
            // curved cap. Measured 1.50pt out at default type, 2.12pt at AX
            // sizes. The floor is what makes it reachable: it guarantees a
            // 2pt-wide fill whenever the fraction is near zero, which is
            // exactly when a funnel step has almost no conversions.
            .clipShape(.capsule)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Step \(index + 1), \(step.name): \(step.count.formatted()), "
            + "\(fraction.formatted(.percent.precision(.fractionLength(0)))) of the first step"
        )
    }

    private var name: some View {
        Text("\(index + 1). \(step.name)")
            .font(.caption)
            .lineLimit(2)
    }

    @ViewBuilder
    private var counts: some View {
        Text(step.count.compactFormatted)
            .font(.caption.weight(.semibold).monospacedDigit())
        Text(fraction, format: .percent.precision(.fractionLength(0)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

extension DynamicTypeSize {
    /// Thins an axis label count for the text size actually in force.
    ///
    /// Swift Charts thins its own labels to fit the count it is handed, but it
    /// is handed one count regardless of text size — so at AX3 the compact time
    /// series drew "Jul 5Jul 12ul 19ul 26", four labels printed over each other.
    /// A label is roughly three times as wide at the top of the scale as at the
    /// default size, so the count has to come down with it. Two is the floor: an
    /// axis with one mark has stopped being an axis.
    ///
    /// It thins the *vertical* axis by the same arithmetic, which an earlier note
    /// on this module's y-axes denied on the grounds that chart height scales
    /// with the text. It does not scale far enough: height is capped at 1.5×
    /// while `.caption2` grows about 4.3× by AX5, so a y-axis label has around a
    /// third of the room it needs. On the lifecycle tile that showed up as "-40"
    /// and "20" drawn on top of one another.
    ///
    /// Shared by every chart in this module, because they all inherited the same
    /// fixed count and the same collision.
    func thinnedAxisCount(_ base: Int) -> Int {
        guard isAccessibilitySize else { return base }
        return self >= .accessibility3 ? 2 : max(2, base - 2)
    }
}

extension Comparable {
    /// Keeps a value inside a range.
    ///
    /// Used by the chart's zoom, where both ends are load-bearing: past the
    /// lower bound the window is narrower than the gap between two points, and
    /// past the upper it shows more time than the series covers.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
