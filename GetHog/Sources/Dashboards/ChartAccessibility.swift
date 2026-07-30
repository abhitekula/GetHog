import Accessibility
import Foundation
import GetHogKit
import SwiftUI

/// Chart descriptors so VoiceOver can navigate the actual data series with the
/// rotor, rather than reading a single summary label.
///
/// Rarely implemented, and the highest-value accessibility win available in an
/// analytics app: without it a blind user gets "chart" and nothing else.
///
/// Every descriptor here takes the insight's own name, because without one they
/// cannot be told apart. Each title used to be a constant — `"User lifecycle"`,
/// `"Ranked values"`, `"N series over time"` — so the four charted tiles of the
/// demo dashboard ("Daily active users (DAUs)", "Weekly active users (WAUs)",
/// "Growth accounting", "Referring domain (last 14 days)") opened the rotor
/// under names that said only what shape they were, and the two trends tiles,
/// having the same series count, opened under the *same* name. Nothing tied any
/// of them to the tile the reader had just swiped past.

// MARK: - Naming

/// The two things a descriptor cannot invent for itself: which insight it
/// belongs to, and what its value axis counts.
enum ChartNaming {

    /// `"<insight>, <shape>"`, or the shape alone when the caller has no name to
    /// give.
    ///
    /// The shape is kept rather than replaced: "Growth accounting" says which
    /// tile this is, "user lifecycle" says what kind of thing is about to be
    /// navigated, and the rotor is the one place both matter at once.
    static func title(insight: String, shape: String) -> String {
        insight.isEmpty ? shape : "\(insight), \(shape)"
    }

    /// What the value axis counts, read off the series labels.
    ///
    /// PostHog's series label *is* the measure: the demo dashboard's DAU tile
    /// labels its one series `$pageview`, and "Growth accounting" labels its four
    /// `$pageview - new`, `$pageview - returning`, and so on. One series means
    /// that label is the measure outright; several usually share a stem, and the
    /// stem is the thing all of them count.
    ///
    /// A breakdown shares nothing — "www.google.com" and "$direct" have no
    /// measure between them — so there is none anywhere in the payload to find,
    /// and the insight's own name is the closest thing left. Either beats the
    /// literal `"Value"` this replaced, which named nothing at all.
    static func measure(of labels: [String], fallback: String) -> String {
        stem(of: labels.filter { !$0.isEmpty }) ?? (fallback.isEmpty ? "Value" : fallback)
    }

    /// Characters PostHog joins a measure to a qualifier with, and the ones a
    /// stem is allowed to end on.
    private static let separators = CharacterSet(charactersIn: " -–—:,·_/")

    /// The longest prefix every label shares — but only when it is a whole token
    /// in all of them.
    ///
    /// The token rule is what stops a coincidence being read as a name:
    /// "Signups" and "Sessions" share the letter "S", which measures nothing.
    private static func stem(of labels: [String]) -> String? {
        guard let first = labels.first else { return nil }
        guard labels.count > 1 else { return first }

        let shared = labels.dropFirst().reduce(first) { prefix, label in
            String(zip(prefix, label).prefix { $0 == $1 }.map(\.0))
        }
        let stem = shared.trimmingCharacters(in: separators)
        guard !stem.isEmpty else { return nil }

        let endsOnABoundary = labels.allSatisfy { label in
            guard label.hasPrefix(stem) else { return false }
            guard let next = label.dropFirst(stem.count).unicodeScalars.first else { return true }
            return separators.contains(next)
        }
        return endsOnABoundary ? stem : nil
    }
}

// MARK: - Summaries

/// One line saying what an insight actually shows.
///
/// Shared by the chart descriptors and by the dashboard tile's button label, so
/// the sentence a reader hears on the grid is the same one the rotor gives them
/// inside the chart. Two texts saying the same thing in different words is how
/// they drift apart.
enum InsightSummary {

    static func spoken(_ model: InsightRenderModel) -> String {
        switch model {
        case .timeSeries(let series, _): timeSeries(series)
        case .barValue(let bars): barValue(bars)
        case .bigNumber(let number): "\(number.label): \(number.value.formatted())"
        case .funnel(let groups): funnel(groups)
        case .lifecycle(let series): lifecycle(series)
        case .retention(let grid): retention(grid)
        case .stickiness(let series): stickiness(series)
        case .paths(let graph): paths(graph)
        case .unsupported(let kind):
            "\(kind.replacingOccurrences(of: "Query", with: "")) insights aren't drawn on mobile yet"
        }
    }

    /// Plain `joined`, not `joinedAsSentences()`: every fragment here ends in a
    /// formatted number, so none of them can arrive already punctuated. The
    /// server-supplied string in each one — the series label — sits in the
    /// middle, where a full stop of its own does no harm. The caller that *does*
    /// need the helper is `TileCard.spokenLabel`, which leads with the insight's
    /// name.
    static func timeSeries(_ series: [Series]) -> String {
        series
            .map { "\($0.label) totals \($0.total.formatted())" }
            .joined(separator: ". ")
    }

    static func barValue(_ bars: [BarValue]) -> String {
        "\(bars.count) categories, highest \(bars.first?.label ?? "")"
    }

    static func lifecycle(_ series: [LifecycleSeries]) -> String {
        series
            .map { "\($0.status.title) \($0.total.formatted())" }
            .joined(separator: ", ")
    }

    static func stickiness(_ series: [StickinessSeries]) -> String {
        series
            .map { "\($0.label): \($0.total.formatted()) users" }
            .joined(separator: ", ")
    }

    static func funnel(_ groups: [FunnelGroup]) -> String {
        let primary = groups.first
        let conversion = (primary?.conversionRate ?? 0)
            .formatted(.percent.precision(.fractionLength(0...1)))
        return "Funnel with \(primary?.steps.count ?? 0) steps, \(conversion) overall conversion"
    }

    static func retention(_ grid: RetentionGrid) -> String {
        "\(grid.cohorts.count) cohorts over \(grid.intervalCount) intervals"
    }

    static func paths(_ graph: PathsGraph) -> String {
        guard let busiest = graph.edges.first else { return "No transitions" }
        return "\(graph.edges.count) transitions, busiest \(busiest.source) to \(busiest.target)"
    }
}

// MARK: - Descriptors

struct TimeSeriesDescriptor: AXChartDescriptorRepresentable {
    let series: [Series]
    /// The insight's own name, threaded down from the tile that draws it.
    var title: String = ""

    func makeChartDescriptor() -> AXChartDescriptor {
        let allValues = series.flatMap { $0.points.map(\.value) }
        let days = series.first?.points.map(\.day) ?? []

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Date",
            categoryOrder: days
        )

        let yAxis = AXNumericDataAxisDescriptor(
            title: ChartNaming.measure(of: series.map(\.label), fallback: title),
            range: (allValues.min() ?? 0)...(max(allValues.max() ?? 1, 1)),
            gridlinePositions: []
        ) { value in
            value.formatted(.number.precision(.fractionLength(0...1)))
        }

        let dataSeries = series.map { s in
            AXDataSeriesDescriptor(
                name: s.label,
                isContinuous: true,
                dataPoints: s.points.map {
                    AXDataPoint(x: $0.day, y: $0.value)
                }
            )
        }

        return AXChartDescriptor(
            title: ChartNaming.title(insight: title, shape: shape),
            summary: InsightSummary.timeSeries(series),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: dataSeries
        )
    }

    private var shape: String {
        series.count == 1 ? "one series over time" : "\(series.count) series over time"
    }
}

struct LifecycleDescriptor: AXChartDescriptorRepresentable {
    let series: [LifecycleSeries]
    var title: String = ""

    func makeChartDescriptor() -> AXChartDescriptor {
        let allValues = series.flatMap { $0.points.map(\.value) }
        let days = series.first?.points.map(\.day) ?? []

        let xAxis = AXCategoricalDataAxisDescriptor(title: "Date", categoryOrder: days)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Users",
            range: (allValues.min() ?? 0)...(max(allValues.max() ?? 1, 1)),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0))) }

        return AXChartDescriptor(
            title: ChartNaming.title(insight: title, shape: "user lifecycle"),
            summary: InsightSummary.lifecycle(series),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series.map { s in
                AXDataSeriesDescriptor(
                    name: s.status.title,
                    isContinuous: false,
                    dataPoints: s.points.map { AXDataPoint(x: $0.day, y: $0.value) }
                )
            }
        )
    }
}

struct BarValueDescriptor: AXChartDescriptorRepresentable {
    let bars: [BarValue]
    var title: String = ""

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = bars.map(\.value)

        // The categories *are* the breakdown, so the insight's name is the name
        // of this axis: "Referring domain (last 14 days)" says what the list of
        // domains under it is a list of, where "Category" said only that they
        // were categories of something.
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: title.isEmpty ? "Category" : title,
            categoryOrder: bars.map(\.label)
        )

        // "Total", not a unit. An aggregated trends display carries its figure
        // in `aggregated_value` with nothing anywhere in the payload saying what
        // was counted — calling it events or users would be a guess dressed as a
        // fact. "Total" at least says these are aggregates rather than a series,
        // which is the one thing the display type does tell us.
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Total",
            range: 0...(max(values.max() ?? 1, 1)),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0...1))) }

        let series = AXDataSeriesDescriptor(
            name: title.isEmpty ? "Values" : title,
            isContinuous: false,
            dataPoints: bars.map { AXDataPoint(x: $0.label, y: $0.value) }
        )

        return AXChartDescriptor(
            title: ChartNaming.title(insight: title, shape: "ranked values"),
            summary: InsightSummary.barValue(bars),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
