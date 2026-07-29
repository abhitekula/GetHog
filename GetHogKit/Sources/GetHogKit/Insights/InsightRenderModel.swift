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
    /// New / returning / resurrecting / dormant user composition over time.
    case lifecycle([LifecycleSeries])
    /// Cohort retention grid.
    case retention(RetentionGrid)
    /// Recognised, but deliberately not drawn on mobile yet.
    case unsupported(kind: String)
}

public enum LifecycleStatus: String, Sendable, CaseIterable {
    case new, returning, resurrecting, dormant, other

    public var title: String {
        self == .other ? "Other" : rawValue.capitalized
    }

    /// Dormant is churn — a loss, drawn below the axis.
    public var isNegative: Bool { self == .dormant }

    /// Fixed palette slot, so a status keeps its colour regardless of the order
    /// PostHog happens to return the series in.
    public var paletteSlot: Int {
        switch self {
        case .new: 2          // green-ish
        case .returning: 0    // blue
        case .resurrecting: 3 // yellow
        case .dormant: 7      // red
        case .other: 6
        }
    }
}

public struct LifecycleSeries: Sendable, Equatable {
    public let status: LifecycleStatus
    public let label: String
    public let total: Double
    public let points: [Point]

    public init(status: LifecycleStatus, label: String, total: Double, points: [Point]) {
        self.status = status
        self.label = label
        self.total = total
        self.points = points
    }
}

public struct RetentionGrid: Sendable, Equatable {
    public let cohorts: [RetentionCohort]

    public init(cohorts: [RetentionCohort]) {
        self.cohorts = cohorts
    }

    /// Widest cohort, so the grid can size a consistent number of columns.
    public var intervalCount: Int {
        cohorts.map(\.counts.count).max() ?? 0
    }
}

public struct RetentionCohort: Sendable, Equatable, Identifiable {
    public let label: String
    public let date: Date?
    public let counts: [Double]

    public var id: String { label }

    public init(label: String, date: Date?, counts: [Double]) {
        self.label = label
        self.date = date
        self.counts = counts
    }

    /// Retention relative to this cohort's own first interval, 0...1.
    public func rate(at index: Int) -> Double {
        guard let base = counts.first, base > 0, index < counts.count else { return 0 }
        return counts[index] / base
    }
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
