import Accessibility
import GetHogKit
import SwiftUI

/// Chart descriptors so VoiceOver can navigate the actual data series with the
/// rotor, rather than reading a single summary label.
///
/// Rarely implemented, and the highest-value accessibility win available in an
/// analytics app: without it a blind user gets "chart" and nothing else.
struct TimeSeriesDescriptor: AXChartDescriptorRepresentable {
    let series: [Series]

    func makeChartDescriptor() -> AXChartDescriptor {
        let allValues = series.flatMap { $0.points.map(\.value) }
        let days = series.first?.points.map(\.day) ?? []

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Date",
            categoryOrder: days
        )

        let yAxis = AXNumericDataAxisDescriptor(
            title: "Value",
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
            title: series.count == 1 ? series[0].label : "\(series.count) series over time",
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: dataSeries
        )
    }

    private var summary: String {
        series
            .map { "\($0.label) totals \($0.total.formatted())" }
            .joined(separator: ". ")
    }
}

struct BarValueDescriptor: AXChartDescriptorRepresentable {
    let bars: [BarValue]

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = bars.map(\.value)

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Category",
            categoryOrder: bars.map(\.label)
        )

        let yAxis = AXNumericDataAxisDescriptor(
            title: "Value",
            range: 0...(max(values.max() ?? 1, 1)),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0...1))) }

        let series = AXDataSeriesDescriptor(
            name: "Values",
            isContinuous: false,
            dataPoints: bars.map { AXDataPoint(x: $0.label, y: $0.value) }
        )

        return AXChartDescriptor(
            title: "Ranked values",
            summary: "\(bars.count) categories, highest \(bars.first?.label ?? "")",
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
