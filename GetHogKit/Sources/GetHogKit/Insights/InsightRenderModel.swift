import Foundation

/// A closed set of things GetHog knows how to draw.
///
/// PostHog has far more insight/display permutations than a phone should try to
/// render. Anything outside this set decodes to `.unsupported`, which renders as
/// an honest card linking to the web console rather than a broken chart.
public enum InsightRenderModel: Sendable, Equatable {
    /// Trends over time — line, bar, or area.
    case timeSeries([Series])
    /// Trends aggregated per breakdown value (`ActionsBarValue`); no time axis.
    case barValue([BarValue])
    /// A single headline figure (`BoldNumber`).
    case bigNumber(BigNumber)
    /// Funnel steps, one group per breakdown value (a single group when unbroken).
    case funnel([FunnelGroup])
    /// Recognised, but deliberately not drawn on mobile yet.
    case unsupported(kind: String)
}

public struct Series: Sendable, Equatable {
    public let label: String
    public let total: Double
    public let points: [Point]

    public init(label: String, total: Double, points: [Point]) {
        self.label = label
        self.total = total
        self.points = points
    }
}

public struct Point: Sendable, Equatable {
    public let day: String
    public let value: Double

    public init(day: String, value: Double) {
        self.day = day
        self.value = value
    }
}

public struct BarValue: Sendable, Equatable {
    public let label: String
    public let value: Double

    public init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

public struct BigNumber: Sendable, Equatable {
    public let label: String
    public let value: Double

    public init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

public struct FunnelGroup: Sendable, Equatable {
    /// `nil` when the funnel has no breakdown.
    public let breakdownValue: String?
    public let steps: [FunnelStep]

    public init(breakdownValue: String?, steps: [FunnelStep]) {
        self.breakdownValue = breakdownValue
        self.steps = steps
    }

    /// Overall conversion from the first step to the last, 0...1.
    public var conversionRate: Double {
        guard let first = steps.first, first.count > 0, let last = steps.last else { return 0 }
        return last.count / first.count
    }
}

public struct FunnelStep: Sendable, Equatable {
    public let name: String
    public let count: Double
    public let order: Int
    public let averageConversionTime: Double?

    public init(name: String, count: Double, order: Int, averageConversionTime: Double?) {
        self.name = name
        self.count = count
        self.order = order
        self.averageConversionTime = averageConversionTime
    }
}
