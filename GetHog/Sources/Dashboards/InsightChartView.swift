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
        case .timeSeries(let series):
            TimeSeriesChart(series: series, compact: compact)
        case .barValue(let bars):
            BarValueChart(bars: bars, compact: compact)
        case .bigNumber(let number):
            BigNumberView(number: number)
        case .funnel(let groups):
            FunnelChart(groups: groups, compact: compact)
        case .unsupported(let kind):
            UnsupportedInsightCard(kind: kind, webURL: webURL)
        }
    }
}

// MARK: - Time series

struct TimeSeriesChart: View {
    let series: [Series]
    var compact: Bool

    @State private var selectedDay: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { compact ? 160 : 280 }

    private var selectedPoints: [(series: Series, point: Point, index: Int)] {
        guard let selectedDay else { return [] }
        return series.enumerated().compactMap { index, s in
            s.points.first { $0.day == selectedDay }.map { (s, $0, index) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !selectedPoints.isEmpty {
                scrubReadout
            }

            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { index, s in
                    ForEach(s.points, id: \.day) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value(s.label, point.value)
                        )
                        .foregroundStyle(SeriesPalette.color(at: index))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        // Monotone, not catmullRom: catmullRom overshoots between
                        // points, which would misrepresent the data.
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", s.label))
                        .symbol(by: .value("Series", s.label))
                    }
                }

                if let selectedDay {
                    RuleMark(x: .value("Day", selectedDay))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(range: paletteRange)
            .chartSymbolScale(range: symbolRange)
            .chartLegend(series.count > 1 ? .visible : .hidden)
            .chartXAxis { AxisMarks(preset: .aligned, values: .automatic(desiredCount: compact ? 3 : 6)) }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXSelection(value: $selectedDay)
            .frame(height: height)
            .sensoryFeedback(.selection, trigger: selectedDay)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selectedDay)
            .accessibilityChartDescriptor(TimeSeriesDescriptor(series: series))
        }
    }

    private var paletteRange: [Color] {
        series.indices.map { SeriesPalette.color(at: $0) }
    }

    private var symbolRange: [BasicChartSymbolShape] {
        let shapes: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond,
                                               .pentagon, .plus, .cross, .asterisk]
        return series.indices.map { shapes[$0 % shapes.count] }
    }

    private var scrubReadout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selectedDay ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(selectedPoints, id: \.index) { entry in
                HStack(spacing: 6) {
                    Image(systemName: SeriesPalette.symbol(at: entry.index))
                        .font(.system(size: 7))
                        .foregroundStyle(SeriesPalette.color(at: entry.index))
                    Text(entry.series.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.point.value.compactFormatted)
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
            }
        }
        .transition(.opacity)
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
