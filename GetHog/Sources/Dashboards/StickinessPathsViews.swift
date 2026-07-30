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
                AxisMarks(values: .automatic(desiredCount: compact ? 4 : 8)) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: compact ? 150 : 240)
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

    private var visible: [PathEdge] {
        Array(graph.edges.prefix(compact ? 5 : 25))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(visible) { edge in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let step = edge.step {
                            Text("\(step)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 14)
                        }
                        Text(display(edge.source))
                            .font(.caption)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(display(edge.target))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(edge.value.compactFormatted)
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(SeriesPalette.color(at: 0))
                                .frame(width: max(2, geo.size.width * fraction(edge)))
                        }
                    }
                    .frame(height: 5)
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
