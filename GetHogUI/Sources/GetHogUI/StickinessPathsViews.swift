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
    var title: String = ""

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// See `TimeSeriesChart.textScale`; this chart carried the same fixed height
    /// and the same fixed axis count.
    @ScaledMetric(relativeTo: .caption2) private var textScale: CGFloat = 1

    private var buckets: [(seriesIndex: Int, bucket: StickinessBucket)] {
        series.enumerated().flatMap { index, s in
            s.buckets.map { (index, $0) }
        }
    }

    /// Halved at accessibility sizes rather than thinned to `thinnedAxisCount`'s
    /// floor of two.
    ///
    /// That floor is calibrated for the dates on a time series, which are three
    /// times as wide at the top of the scale. This axis counts days active, so
    /// its labels are one or two digits and cost almost nothing — and at the
    /// floor Swift Charts chose a stride whose only mark inside a 1...8 domain
    /// was "0". Measured at AX5: one label, which by the same helper's rule is
    /// not an axis.
    private var xAxisTickCount: Int {
        let base = compact ? 4 : 8
        return dynamicTypeSize.isAccessibilitySize ? max(3, base / 2) : base
    }

    /// Past the accessibility threshold the legend leaves the chart's frame —
    /// see `InsightLegend`. This chart shares the lifecycle tile's capped height
    /// and the same in-frame legend, so with a breakdown it collapses the same
    /// way: two series at AX5 take ~100pt of a 225pt frame, and what is left
    /// after the x-axis labels is not a plot.
    private var legendBelowChart: Bool {
        series.count > 1 && dynamicTypeSize.isAccessibilitySize
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
            .chartLegend(series.count > 1 && !legendBelowChart ? .visible : .hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: xAxisTickCount)) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartYAxis {
                // Thinned, like the x-axis beside it. The note that used to
                // stand here — that vertical room scales with the text — was
                // borrowed from the time series' y-axis, and it was wrong there
                // too: the height it refers to is capped at 1.5× while
                // `.caption2` grows about 4.3× by AX5. Three labels in a 225pt
                // frame minus its axis row is the same pile-up the lifecycle
                // tile showed.
                AxisMarks(
                    position: .leading,
                    values: .automatic(desiredCount: dynamicTypeSize.thinnedAxisCount(compact ? 3 : 4))
                ) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: (compact ? 150 : 240) * min(textScale, 1.5))
            .accessibilityChartDescriptor(StickinessDescriptor(series: series, title: title))

            Text("Days active in the period")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)

            if legendBelowChart {
                InsightLegend(
                    entries: series.enumerated().map { index, s in
                        InsightLegend.Entry(label: s.label, slot: index, total: s.total)
                    },
                    unit: "users"
                )
            }
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
                    // Clipped by the track, for the reason spelled out on the
                    // identical bar in `FunnelStepRow`: a 2pt-wide `Capsule`
                    // rounds at 1pt and escapes a track rounding at
                    // `barHeight / 2`. A rare path edge is precisely the case
                    // that hits the floor.
                    .clipShape(.capsule)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(display(edge.source)) to \(display(edge.target)), \(Int(edge.value)) users"
                )
            }

            if graph.edges.count > visible.count {
                Text("+\(graph.edges.count - visible.count) more transitions")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
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
                        .foregroundStyle(Theme.neutralMark)
                    node(edge.target)
                }
            }
        } else {
            HStack(spacing: 6) {
                stepBadge(edge)
                node(edge.source)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.neutralMark)
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
                .foregroundStyle(Theme.Ink.secondary)
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
    /// The insight's own name — see `ChartNaming`.
    var title: String = ""

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
            title: ChartNaming.title(insight: title, shape: "stickiness distribution"),
            summary: InsightSummary.stickiness(series),
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
