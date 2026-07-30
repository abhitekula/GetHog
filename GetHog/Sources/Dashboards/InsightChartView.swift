import Charts
import GetHogKit
import SwiftUI

/// Renders an `InsightRenderModel`.
///
/// Every form ships a VoiceOver chart descriptor, and multi-series charts always
/// carry a legend plus symbol marks so identity never rests on colour alone —
/// which is also the relief the light-mode palette's contrast warning requires.
struct InsightChartView: View {
    let model: InsightRenderModel
    var compact: Bool = true
    var webURL: URL?

    var body: some View {
        switch model {
        case .timeSeries(let series, let style):
            TimeSeriesChart(series: series, style: style, compact: compact)
        case .barValue(let bars):
            BarValueChart(bars: bars, compact: compact)
        case .bigNumber(let number):
            BigNumberView(number: number)
        case .funnel(let groups):
            FunnelChart(groups: groups, compact: compact)
        case .lifecycle(let series):
            LifecycleChart(series: series, compact: compact)
        case .retention(let grid):
            RetentionGridView(grid: grid, compact: compact)
        case .stickiness(let series):
            StickinessChart(series: series, compact: compact)
        case .paths(let graph):
            PathsFlowView(graph: graph, compact: compact)
        case .unsupported(let kind):
            UnsupportedInsightCard(kind: kind, webURL: webURL)
        }
    }
}

// MARK: - Lifecycle

struct LifecycleChart: View {
    let series: [LifecycleSeries]
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(series, id: \.status) { s in
                    ForEach(s.points, id: \.day) { point in
                        BarMark(
                            x: .value("Day", point.day),
                            y: .value("Users", point.value)
                        )
                        .foregroundStyle(by: .value("Status", s.status.title))
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
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: compact ? 3 : 6)) }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartLegend(.visible)
            .frame(height: compact ? 170 : 280)
            .accessibilityChartDescriptor(LifecycleDescriptor(series: series))

            if !compact {
                ForEach(series, id: \.status) { s in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(SeriesPalette.color(at: s.status.paletteSlot))
                            .frame(width: 8, height: 8)
                        Text(s.status.title).font(.caption)
                        Spacer()
                        Text(s.total.compactFormatted)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            // Churn reads as a loss, so it is signed, not absolute.
                            .foregroundStyle(s.status.isNegative ? Theme.Status.critical : .primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(s.status.title): \(s.total.formatted()) users")
                }
            }
        }
    }
}

// MARK: - Retention

struct RetentionGridView: View {
    let grid: RetentionGrid
    var compact: Bool

    private var visibleIntervals: Int {
        min(grid.intervalCount, compact ? 6 : 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Column headers
            HStack(spacing: 2) {
                Text("Cohort")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                ForEach(0..<visibleIntervals, id: \.self) { index in
                    Text("\(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(grid.cohorts) { cohort in
                HStack(spacing: 2) {
                    Text(cohort.label)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(width: 62, alignment: .leading)

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

    var body: some View {
        Group {
            if let rate {
                Text(rate, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(rate > 0.55 ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background(
                        SeriesPalette.color(at: 0).opacity(0.1 + 0.75 * rate),
                        in: .rect(cornerRadius: 3)
                    )
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

    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { compact ? 170 : 280 }

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
            // Reserve the row unconditionally so the chart never shifts when a
            // scrub begins.
            scrubReadout
                .opacity(selectedPoints.isEmpty ? 0 : 1)

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
            .chartLegend(series.count > 1 ? .visible : .hidden)
            .chartXAxis {
                // Let the axis choose its own tick count and format; a fixed
                // categorical axis is what produced overlapping labels.
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: compact ? 3 : 5)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartXSelection(value: $selectedDate)
            // Scrubbing is the one chart interaction nothing on screen hints at,
            // so it gets the tip. Only on the full-size chart: firing this over
            // every tile in a dashboard grid at once would be an infestation.
            .popoverTip(compact ? nil : ChartScrubTip())
            .frame(height: height)
            .sensoryFeedback(.selection, trigger: selectedDate)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selectedDate)
            .accessibilityChartDescriptor(TimeSeriesDescriptor(series: series))
        }
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
                    Circle()
                        .fill(SeriesPalette.color(at: entry.index))
                        .frame(width: 6, height: 6)
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

    private var visible: [BarValue] {
        Array(bars.prefix(compact ? 6 : 20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .chartYAxis { AxisMarks(preset: .aligned, position: .leading) }
            .frame(height: CGFloat(visible.count) * 26 + 20)
            .accessibilityChartDescriptor(BarValueDescriptor(bars: visible))

            if bars.count > visible.count {
                Text("+\(bars.count - visible.count) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Big number

struct BigNumberView: View {
    let number: BigNumber

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(number.value.compactFormatted)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
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

    private var fraction: Double {
        maxCount > 0 ? step.count / maxCount : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(index + 1). \(step.name)")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(step.count.compactFormatted)
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(SeriesPalette.color(at: 0))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Step \(index + 1), \(step.name): \(step.count.formatted()), "
            + "\(fraction.formatted(.percent.precision(.fractionLength(0)))) of the first step"
        )
    }
}
