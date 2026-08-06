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
    /// Passed through to `TimeSeriesChart`, which is the only form that has a
    /// scrub gesture to teach. Off by default — see `TimeSeriesChart.body`.
    var showsScrubTip: Bool = false

    var body: some View {
        switch model {
        case .timeSeries(let series, let style):
            TimeSeriesChart(
                series: series,
                style: style,
                compact: compact,
                title: title,
                showsScrubTip: showsScrubTip
            )
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

    /// Per-entry drill-downs, keyed by the entry's position.
    ///
    /// A legend row names a *series*, and a series on its own is not something
    /// PostHog will resolve to people — measured, a `series`-only actors query
    /// returns zero rows. So a row that can be drilled offers the points it is
    /// made of instead, each with the count already drawn on the chart.
    var drills: [Int: [InsightDrill]] = [:]
    /// What the drills are indexed by, in the reader's words.
    var drillAxisLabel = "Interval"
    var onDrill: ((InsightDrillRequest) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // Indexed, not keyed by label: two series of a breakdown can carry
            // the same label, and a duplicate `ForEach` id drops one of them.
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if let onDrill, let choices = drills[index], !choices.isEmpty {
                    drillableRow(entry, choices: choices, onDrill: onDrill)
                } else {
                    row(entry)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(for: entry))
                }
            }
        }
    }

    /// Opens the most recent interval, and offers the rest inside the sheet.
    ///
    /// `choices` arrives newest-first, so `first` is the latest interval — the
    /// one a reader looking at a legend is almost always asking about.
    private func drillableRow(
        _ entry: Entry,
        choices: [InsightDrill],
        onDrill: @escaping (InsightDrillRequest) -> Void
    ) -> some View {
        Button {
            guard let latest = choices.first else { return }
            onDrill(
                InsightDrillRequest(
                    selected: latest, siblings: choices, axisLabel: drillAxisLabel
                )
            )
        } label: {
            row(entry)
                // A legend row is two lines of `.caption`; the hit target is
                // built here rather than inherited.
                .frame(minHeight: 44, alignment: .center)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: entry))
        .accessibilityHint("Shows the people counted in this band")
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
                    unit: "users",
                    drills: bandDrills,
                    drillAxisLabel: "Interval",
                    onDrill: drill?.open
                )
            }
        }
    }

    @Environment(\.insightDrill) private var drill

    /// One drill per band per day, newest first.
    ///
    /// Per *day*, not per band: a lifecycle band on one day reconciles exactly —
    /// checked against all four statuses across all five weeks of a live weekly
    /// insight, 18 of 18 including the dormant band, whose charted value is
    /// negative and whose people are its magnitude. A band without a day does
    /// return people, but nothing on the chart states how many, so there would
    /// be no number to be honest about.
    ///
    /// Costs nothing to build: every label and count here is already drawn.
    private var bandDrills: [Int: [InsightDrill]] {
        guard drill?.axis == .lifecycleBand else { return [:] }
        var out: [Int: [InsightDrill]] = [:]
        for (index, s) in series.enumerated() {
            out[index] = s.points.reversed().filter { $0.value != 0 }.map { point in
                InsightDrill(
                    kind: .lifecycleBand(status: s.status.rawValue, day: point.day),
                    title: "\(Self.dayLabel(point)) · \(s.status.title)",
                    expectedCount: abs(point.value)
                )
            }
        }
        return out
    }

    private static func dayLabel(_ point: Point) -> String {
        point.date?.formatted(.dateTime.month(.abbreviated).day()) ?? point.day
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
                    // Hover highlighting only, per spec §3 — the percentage is
                    // already printed, so there is no tooltip to earn.
                    .chartHoverOutline(cornerRadius: 3)
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
    /// Whether to teach the scrub gesture above this chart — see `body`.
    /// Off by default so a new call site has to say that its chart is one a
    /// finger can actually reach.
    var showsScrubTip: Bool = false

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

    /// The scrub's easing — iOS only. A finger forgives 150ms of retargeting;
    /// a pointer does not: hover is sampled per pixel, and a rule mark that
    /// eases toward the cursor reads as latency, not polish.
    private var scrubAnimation: Animation? {
        #if os(macOS)
        nil
        #else
        reduceMotion ? nil : .easeOut(duration: 0.15)
        #endif
    }

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
    ///
    /// Carries the point's own `day` string as well as its value, because that
    /// is what an actors query has to be given — PostHog matches the day label
    /// it sent, and reformatting the parsed `Date` back into text would be a
    /// second, independent guess at its format.
    private var selectedPoints: [(series: Series, point: Point, index: Int)] {
        guard let selectedDate else { return [] }
        return series.enumerated().compactMap { index, s in
            guard s.datedPoints != nil,
                  let nearest = ChartScrubMath.nearestDatedPoint(in: s.points, to: selectedDate)
            else { return nil }
            return (s, nearest, index)
        }
    }

    @Environment(\.insightDrill) private var drill

    /// Whether the scrubbed point can be turned into a list of people.
    ///
    /// Compact tiles are excluded on purpose. A tile is already a button that
    /// opens the insight, the readout is a few points tall inside it, and a
    /// sheet presented from a dashboard grid would land the user somewhere they
    /// did not navigate to.
    private var canDrill: Bool { drill?.axis == .trendsPoint && !compact }

    /// One drill per series at the scrubbed day.
    ///
    /// The day is required, not optional: the trends-actors contract does not
    /// interpret a missing day as the whole range. That is why this affordance
    /// hangs off the scrub readout at all. The plot region belongs to
    /// `chartXSelection`, and a tap gesture there would fight the scrub for the
    /// same pixels; the readout is a separate view that only exists once a day
    /// has been chosen, so it can be a button without contending for anything.
    private var pointDrills: [InsightDrill] {
        guard canDrill else { return [] }
        return selectedPoints.filter { $0.point.value != 0 }.map { entry in
            InsightDrill(
                kind: .trendsPoint(series: entry.index, day: entry.point.day),
                title: series.count > 1
                    ? "\(selectedLabel) · \(entry.series.label)"
                    : selectedLabel,
                expectedCount: entry.point.value
            )
        }
    }

    private var selectedLabel: String {
        selectedDate?.formatted(.dateTime.month(.abbreviated).day()) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // **Above the chart, not over it.**
            //
            // This was `.popoverTip(compact ? nil : ChartScrubTip())` on the
            // `Chart` itself, which anchors a popover to the plot — a coach mark
            // positioned over the thing it is teaching you to touch.
            //
            // **What was actually observed is worse than that, and the note
            // should say so rather than repeat the theory.** With the popover
            // form the tip appears in *neither* capture of a full-size chart —
            // `light/` and `dark/` of both `saved-insight-detail` and
            // `dashboard-tile-insight`, iPhone 17 Pro — and this harness uses
            // `XCUIScreen.main.screenshot()`, which does capture popover
            // windows (that is why it is used). So it was not merely badly
            // placed; on the evidence available it was not presenting at all.
            // Inline it appears on both, above the plot, with the chart intact
            // beneath it. Nobody here has seen the popover cover a chart.
            //
            // **The gesture it advertises is still live where this appears** —
            // checked, because `Dashboards/` changed underneath this: a tile's
            // chart is now `.allowsHitTesting(false)` inside `TileCard`'s
            // `Button`, so scrubbing genuinely does *not* work on a dashboard
            // tile. It does not orphan the tip, because the tip was never on a
            // tile: the old gate was `compact ? nil : …` and a tile is
            // `compact: true`. `showsScrubTip` is opt-in at the two call sites
            // that host a full-size, un-buttoned chart — `SavedInsightDetailView`
            // and `InsightDetailBody` — where `.chartXSelection` below is
            // reached by a real finger.
            //
            // Opt-in rather than `!compact`, and that is not tidiness:
            // `ChartImageRenderer` also renders `compact: false`, into a PNG the
            // user shares. A tip inferred from `compact` would have been eligible
            // to appear in an exported image.
            //
            // **Withheld at accessibility sizes**, which is not a precaution
            // copied from `FlagsRoot` but the same defect measured here:
            // `ax5/saved-insight-detail.png` on iPhone 17 Pro came back with the
            // tip filling the viewport — title on three lines, message still
            // running off the bottom — and the chart it describes entirely below
            // the fold. A coach mark that displaces its subject is the failure
            // this move out of the popover was meant to fix, arriving from the
            // other direction.
            #if os(iOS)
            // Mac builds skip the tip rather than reword it: it teaches a
            // touch gesture the pointer replaces, and hovering needs no
            // coaching — the readout appears the first time the pointer
            // crosses a plot.
            if showsScrubTip, !dynamicTypeSize.isAccessibilitySize {
                AppTipView(ChartScrubTip())
            }
            #endif

            HStack(alignment: .firstTextBaseline) {
                // Reserve the row unconditionally so the chart never shifts when
                // a scrub begins.
                Group {
                    if let onDrill = drill?.open, !pointDrills.isEmpty {
                        drillableReadout(onDrill: onDrill)
                    } else {
                        scrubReadout
                    }
                }
                .opacity(selectedPoints.isEmpty ? 0 : 1)
                // Hidden from touch and from VoiceOver while there is nothing
                // scrubbed: an invisible button that still takes taps is worse
                // than no button.
                .allowsHitTesting(!selectedPoints.isEmpty)
                .accessibilityHidden(selectedPoints.isEmpty)

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
            // The first tick sits on the plot origin, and a label centred on
            // it extends half its width past the leading edge — sheared to
            // "il 5" on every device the sweep captured, glyphs that read as a
            // different month. A little scale padding gives the "J" room.
            .chartXScale(range: .plotDimension(padding: 12))
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
            // **This must never be reachable inside a control.** Left live
            // inside `TileCard`'s `Button` it did not merely swallow the tap on
            // the plot, which is what the tile's own comment used to claim: it
            // left the button unable to fire *at all*, anywhere in its bounds,
            // for the rest of the screen's life. Measured on iPhone 16e — see
            // `TileCard.card`, which is where the guard is and where the
            // measurement is written down. Nothing here can defend against that
            // on its own, because a chart cannot know what contains it; the
            // container has to say so. `NotebookQueryBlock` draws the same
            // compact chart *outside* any button and scrubbing there is a real
            // feature, which is why this is not gated on `compact`.
            #if os(iOS)
            .chartXSelection(value: $selectedDate)
            #else
            // The pointer's spelling of the same gesture: hover writes the
            // same `selectedDate` the touch drag writes, so the rule mark,
            // the readout and the drill are one path with two front doors.
            // The control trap above applies unchanged — `TileCard` keeps
            // this unreachable inside its button via hit testing, which
            // blocks hover exactly as it blocks touch.
            .chartHoverSelection($selectedDate)
            #endif
            // Pan. Swift Charts arbitrates the drag between scrolling and
            // scrubbing itself once an axis is scrollable — selection is
            // promoted to press-then-drag — which is why this does not need a
            // hand-rolled gesture mask.
            .chartScrollableAxes(allowsZoom ? .horizontal : [])
            .chartXVisibleDomain(length: visibleSpan)
            .frame(height: height)
            .simultaneousGesture(allowsZoom ? magnify : nil)
            #if os(iOS)
            // iOS only: on a Force Touch trackpad this would tick on every
            // pixel of pointer travel. It was tuned for a deliberate drag.
            .sensoryFeedback(.selection, trigger: selectedDate)
            #endif
            // Fires at the ends of the range, so a pinch that has stopped doing
            // anything says so rather than feeling broken.
            .sensoryFeedback(.levelChange, trigger: isAtZoomLimit)
            .animation(scrubAnimation, value: selectedDate)
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
                    Text(entry.point.value.compactFormatted)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                }
            }
            if canDrill {
                // The only hint that the readout does anything. Without it the
                // affordance is invisible — a scrub readout has never been
                // tappable before.
                Image(systemName: "person.2")
                    .font(.caption2)
                    .foregroundStyle(Theme.Status.accentInk)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: .capsule)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// The readout, as "show me these people".
    ///
    /// A second, deliberate tap after the scrub has already chosen the day — it
    /// cannot be fired by a finger that was only trying to scrub, which matters
    /// because the request is charged to a budget shared organisation-wide with
    /// the user's production integrations.
    ///
    /// Opens the largest series at that day and offers the others in the sheet.
    /// A chart with one series — which is most of them — is a single tap.
    private func drillableReadout(onDrill: @escaping (InsightDrillRequest) -> Void) -> some View {
        Button {
            let choices = pointDrills
            guard let biggest = choices.max(by: { $0.expectedCount < $1.expectedCount })
            else { return }
            onDrill(
                InsightDrillRequest(selected: biggest, siblings: choices, axisLabel: "Series")
            )
        } label: {
            scrubReadout
                .frame(minHeight: 44, alignment: .center)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selectedLabel), \(selectedPoints.count) series")
        .accessibilityHint("Shows the people behind this point")
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

    @Environment(\.insightDrill) private var drill
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Bars become rows when each one is a breakdown value that can be resolved
    /// to people — which is also the shape a `WorldMap` insight arrives in.
    ///
    /// Only at full size. In a dashboard tile the bars stay a `Chart`: six rows
    /// with 44pt targets do not fit a tile, and the tile is already one button.
    private var canDrill: Bool { drill?.axis == .breakdown && !compact }

    var body: some View {
        if canDrill {
            drillableRows
        } else {
            plainChart
        }
    }

    /// The same bars, as rows, because a `Chart`'s marks cannot carry a button.
    ///
    /// Hand-drawn rather than overlaid on the chart: `FunnelStepRow` and
    /// `PathsFlowView` already draw exactly this — a label, a capsule track, a
    /// figure — so this is the house style rather than a new one, and unlike a
    /// tap-target overlay on a plot it reflows under Dynamic Type and gives
    /// VoiceOver a real button per row.
    private var drillableRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, bar in
                Button {
                    // Every visible bar is a sibling, so the sheet can move
                    // between breakdown values without going back to the chart.
                    let choices = visible.map {
                        InsightDrill(
                            kind: .breakdown(series: 0, value: $0.rawValue),
                            title: $0.label,
                            expectedCount: $0.value
                        )
                    }
                    let selected = InsightDrill(
                        kind: .breakdown(series: 0, value: bar.rawValue),
                        title: bar.label,
                        expectedCount: bar.value
                    )
                    drill?.open(
                        InsightDrillRequest(
                            selected: selected, siblings: choices, axisLabel: "Value"
                        )
                    )
                } label: {
                    BarValueRow(bar: bar, maxValue: visible.map(\.value).max() ?? 1)
                        .frame(minHeight: 44, alignment: .center)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(bar.label), \(bar.value.formatted())")
                .accessibilityHint("Shows the people counted here")
            }

            if bars.count > visible.count {
                Text("+\(bars.count - visible.count) more")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
    }

    private var plainChart: some View {
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

/// One breakdown value, drawn the way this app already draws a proportion.
struct BarValueRow: View {
    let bar: BarValue
    let maxValue: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 6

    private var fraction: Double {
        maxValue > 0 ? bar.value / maxValue : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The same reflow as `FunnelStepRow`, for the same measured reason:
            // past the accessibility threshold a label and a figure sharing one
            // row leave the figure a couple of characters wide.
            if dynamicTypeSize.isAccessibilitySize {
                name
                value
            } else {
                HStack {
                    name
                    Spacer(minLength: Theme.Space.s)
                    value
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
            // Clipped by the track, in the track's own space — see the note on
            // `FunnelStepRow`, where the same 2pt floor leaves a self-clipped
            // fill's corners outside the track's cap.
            .clipShape(.capsule)
        }
    }

    private var name: some View {
        Text(bar.label)
            .font(.caption)
            .lineLimit(2)
            // Either end can be the distinguishing part of a breakdown value —
            // the same reasoning as the chart's own axis labels.
            .truncationMode(.middle)
    }

    private var value: some View {
        Text(bar.value.compactFormatted)
            .font(.caption.weight(.semibold).monospacedDigit())
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

    @Environment(\.insightDrill) private var drill

    /// Steps are the one place in this app where a chart element was already a
    /// discrete row, so the drill-down needed no new interaction — only a button
    /// around what was there.
    private var canDrill: Bool { drill?.axis == .funnelStep }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let primary {
                if let breakdown = primary.breakdownValue, groups.count > 1 {
                    // Names *which* breakdown the steps below belong to, so it
                    // is on `Ink.secondary` for the same reason the notice at
                    // the foot of this stack is on `Ink.tertiary`: the system
                    // ramp measures 3.26:1 against the page ground, and these
                    // three lines have to stay in the order they were written
                    // in. `.secondary` here would have come out *lighter* than
                    // the "+N more breakdowns" beneath it once that line was
                    // fixed, which is the same inversion one row up.
                    Text(breakdown)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Ink.secondary)
                }

                ForEach(Array(primary.steps.enumerated()), id: \.offset) { index, step in
                    let row = FunnelStepRow(
                        step: step,
                        index: index,
                        maxCount: primary.steps.first?.count ?? 1
                    )
                    if canDrill {
                        stepButton(for: step, at: index, in: primary) { row }
                            .chartHoverHighlight()
                    } else {
                        row
                            .chartHoverHighlight()
                    }
                }

                if groups.count > 1 {
                    // `.tertiary` is a *disabled-control* weight, and that is
                    // what this line read as. On the funnel detail it sampled
                    // lighter than the `FreshnessLabel` directly beneath it, so
                    // the one sentence saying the chart is showing 1 of 8
                    // breakdowns looked switched off while "Updated yesterday"
                    // looked live — a hierarchy exactly inverted against what
                    // the two lines are worth. It is not decoration: it is the
                    // only notice that seven breakdowns are missing from what is
                    // on screen, and a reader who does not see it reads a
                    // one-browser funnel as the whole funnel.
                    //
                    // `Ink.secondary` rather than `Ink.tertiary`, for the reason
                    // `FreshnessLabel` gives: `.caption2` is the smallest type
                    // the app sets and small type needs the *most* contrast.
                    // Levelling with the timestamp is the point — the inversion
                    // is the defect, and a third step here would only make it
                    // smaller. 6.95:1 on the page, 7.98:1 on a card.
                    Text("+\(groups.count - 1) more breakdown\(groups.count == 2 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Funnel with \(primary?.steps.count ?? 0) steps, "
            + "\((primary?.conversionRate ?? 0).formatted(.percent.precision(.fractionLength(0...1)))) overall conversion"
        )
    }

    /// A step opens the people who *reached* it, and offers the drop-off inside
    /// the sheet.
    ///
    /// Converted first because it is the step's own headline figure — the number
    /// already drawn on the row — so the tap resolves to the thing under the
    /// finger. "Who dropped out here" is the question people actually come for,
    /// but it is a different number from the one on the row, and opening it from
    /// a tap on that row would be a lie about what was tapped.
    ///
    /// The first step offers no drop-off at all: nobody can fall out before the
    /// funnel begins, and asking PostHog anyway is **HTTP 500**, not an empty
    /// list. `InsightDrill.funnelDropOff` returns nil there and the sibling is
    /// simply never built, so the picker cannot offer a tap that fails.
    private func stepButton(
        for step: FunnelStep,
        at index: Int,
        in group: FunnelGroup,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let converted = InsightDrill.funnelConverted(step: step, index: index)
        let dropped = InsightDrill.funnelDropOff(
            step: step, index: index, previous: index > 0 ? group.steps[index - 1] : nil
        )

        return Button {
            drill?.open(
                InsightDrillRequest(
                    selected: converted,
                    siblings: [converted, dropped].compactMap(\.self),
                    axisLabel: "Outcome"
                )
            )
        } label: {
            label()
                // The row is text and a 6pt bar — nowhere near 44pt on its own.
                .frame(minHeight: 44, alignment: .center)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Step \(index + 1), \(step.name): \(step.count.formatted()) people"
        )
        .accessibilityHint("Shows who completed or dropped off at this step")
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
            // The step's share of the first step — a number the column exists
            // to be scanned down, at the smallest size the app sets, and the
            // one thing on the row that says whether a step is a cliff. Off the
            // system ramp for the reason `Theme.Ink` documents.
            .foregroundStyle(Theme.Ink.secondary)
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
