import Charts
import GetHogKit
import SwiftUI

/// Distribution of how many intervals users were active in.
///
/// The x-axis counts days, not dates, so this is a histogram rather than a time
/// series — drawing it as a line would imply a trend through time that isn't
/// there.
struct StickinessChart: View {
    let series: [StickinessSeries]
    var compact: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// See `TimeSeriesChart.textScale`; this chart carried the same fixed height
    /// and the same fixed axis count.
    @ScaledMetric(relativeTo: .caption2) private var textScale: CGFloat = 1

    private var buckets: [(seriesIndex: Int, bucket: StickinessBucket)] {
        series.enumerated().flatMap { index, s in
            s.buckets.map { (index, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, entry in
                    BarMark(
                        x: .value("Days active", entry.bucket.intervals),
                        y: .value("Users", entry.bucket.count)
                    )
                    .foregroundStyle(by: .value("Series", series[entry.seriesIndex].label))
                    .cornerRadius(3)
                }
            }
            .chartForegroundStyleScale(range: series.indices.map { SeriesPalette.color(at: $0) })
            .chartLegend(series.count > 1 ? .visible : .hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: dynamicTypeSize.thinnedAxisCount(compact ? 4 : 8))) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartYAxis {
                // Deliberately not thinned, for the reason given on the time
                // series' y-axis: vertical room scales with the text.
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: (compact ? 150 : 240) * min(textScale, 1.5))
            .accessibilityChartDescriptor(StickinessDescriptor(series: series))

            Text("Days active in the period")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Ranked user-flow edges.
///
/// A real Sankey is unreadable at phone width, so the same information is shown
/// as a ranked list of transitions with proportional bars — which is also easier
/// to scan for the one path that dominates.
struct PathsFlowView: View {
    let graph: PathsGraph
    var compact: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The bar is the only non-textual reading of an edge's weight, so it scales
    /// with the row rather than staying a 5pt hairline under 32pt text.
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 5

    private var visible: [PathEdge] {
        Array(graph.edges.prefix(compact ? 5 : 25))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(visible) { edge in
                VStack(alignment: .leading, spacing: 4) {
                    edgeLabels(edge)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(SeriesPalette.color(at: 0))
                                .frame(width: max(2, geo.size.width * fraction(edge)))
                        }
                    }
                    .frame(height: barHeight)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(display(edge.source)) to \(display(edge.target)), \(Int(edge.value)) users"
                )
            }

            if graph.edges.count > visible.count {
                Text("+\(graph.edges.count - visible.count) more transitions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Source, target and the count for one edge.
    ///
    /// Both ends shared a row and both were clipped to one line, and `display()`
    /// has already thrown the host away — so the characters that got cut were
    /// the ones saying which step this is. Two lines each, and past the
    /// accessibility threshold the two ends stop competing for one row at all:
    /// four things across a phone leaves each of them a few characters.
    @ViewBuilder
    private func edgeLabels(_ edge: PathEdge) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    stepBadge(edge)
                    node(edge.source)
                    Spacer(minLength: 6)
                    total(edge)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    node(edge.target)
                }
            }
        } else {
            HStack(spacing: 6) {
                stepBadge(edge)
                node(edge.source)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                node(edge.target)
                Spacer(minLength: 6)
                total(edge)
            }
        }
    }

    @ViewBuilder
    private func stepBadge(_ edge: PathEdge) -> some View {
        if let step = edge.step {
            Text("\(step)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 14)
        }
    }

    private func node(_ value: String) -> some View {
        Text(display(value))
            .font(.caption)
            .lineLimit(2)
    }

    private func total(_ edge: PathEdge) -> some View {
        Text(edge.value.compactFormatted)
            .font(.caption.weight(.semibold).monospacedDigit())
    }

    private func fraction(_ edge: PathEdge) -> Double {
        graph.busiest > 0 ? edge.value / graph.busiest : 0
    }

    /// Full URLs dominate the row; the path is the part that identifies a step.
    private func display(_ node: String) -> String {
        guard node.hasPrefix("http"), let url = URL(string: node) else { return node }
        let path = url.path.isEmpty ? "/" : url.path
        return path
    }
}

struct StickinessDescriptor: AXChartDescriptorRepresentable {
    let series: [StickinessSeries]

    func makeChartDescriptor() -> AXChartDescriptor {
        let all = series.flatMap { $0.buckets }
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Days active",
            range: Double(all.map(\.intervals).min() ?? 0)...Double(max(all.map(\.intervals).max() ?? 1, 1)),
            gridlinePositions: []
        ) { "\(Int($0)) days" }

        let yAxis = AXNumericDataAxisDescriptor(
            title: "Users",
            range: 0...(max(all.map(\.count).max() ?? 1, 1)),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0))) }

        return AXChartDescriptor(
            title: "Stickiness",
            summary: series.map { "\($0.label): \($0.total.formatted()) users" }
                .joined(separator: ", "),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series.map { s in
                AXDataSeriesDescriptor(
                    name: s.label,
                    isContinuous: false,
                    dataPoints: s.buckets.map {
                        AXDataPoint(x: Double($0.intervals), y: $0.count)
                    }
                )
            }
        )
    }
}
