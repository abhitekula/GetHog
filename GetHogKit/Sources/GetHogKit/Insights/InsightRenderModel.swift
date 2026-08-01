import Foundation

/// A closed set of things GetHog knows how to draw.
///
/// PostHog has far more insight/display permutations than a phone should try to
/// render. Anything outside this set decodes to `.unsupported`, which renders as
/// an honest card linking to the web console rather than a broken chart.
public enum InsightRenderModel: Sendable, Equatable {
    /// Trends over time, drawn in the style the insight actually specifies.
    case timeSeries([Series], style: TimeSeriesStyle)
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
    /// How many intervals users were active in — a distribution, not a series.
    case stickiness([StickinessSeries])
    /// User flow between steps, as a ranked edge list.
    case paths(PathsGraph)
    /// Recognised, but deliberately not drawn on mobile yet.
    case unsupported(kind: String)
}

/// How a trends insight should be drawn.
///
/// PostHog stores this per insight; ignoring it would render a stacked-bar
/// insight as overlapping lines, which reads as a completely different result.
public enum TimeSeriesStyle: Sendable, Equatable {
    case line
    case area
    case bar
    case stackedBar

    /// The full vocabulary, straight from the API's own validation error, is
    ///
    ///     Auto, ActionsLineGraph, ActionsBar, ActionsUnstackedBar,
    ///     ActionsStackedBar, ActionsAreaGraph, ActionsLineGraphCumulative,
    ///     BoldNumber, Metric, ActionsPie, ActionsBarValue, ActionsTable,
    ///     WorldMap, CalendarHeatmap, TwoDimensionalHeatmap, BoxPlot, SlopeGraph
    ///
    /// Only the ones that reach here are handled here; the aggregated and
    /// undrawable ones are diverted by `Insight.renderModel` before this is
    /// reached. For the remaining public display modes:
    ///
    /// - `Auto`, `ActionsLineGraph` — plain series, a line.
    /// - `ActionsLineGraphCumulative` — the server returns the running total
    ///   already summed, so a line is the right mark.
    /// - `SlopeGraph` — the server returns exactly two points, the ends of the
    ///   range, which a line between them draws correctly.
    /// - `Metric` — comparison series use `compare_label` to remain distinct.
    /// - `TwoDimensionalHeatmap` — when it reaches this decoder it carries
    ///   ordinary trends rows, so the fallback is a line.
    init(display: String?) {
        switch display {
        case "ActionsAreaGraph": self = .area
        // Both bar forms, and `ActionsUnstackedBar` deliberately: it returns
        // ordinary time-series data and used to fall through to `.line`, which
        // drew a bar insight as a line — the same class of mistake as ignoring
        // the display type altogether.
        case "ActionsBar", "ActionsUnstackedBar": self = .bar
        case "ActionsStackedBar": self = .stackedBar
        default: self = .line
        }
    }
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

public struct StickinessSeries: Sendable, Equatable {
    public let label: String
    public let total: Double
    public let buckets: [StickinessBucket]

    public init(label: String, total: Double, buckets: [StickinessBucket]) {
        self.label = label
        self.total = total
        self.buckets = buckets
    }
}

/// "`count` users were active on exactly `intervals` days."
///
/// The x-axis is an interval count, not a date, which is why stickiness cannot
/// share the trends renderer.
public struct StickinessBucket: Sendable, Equatable, Identifiable {
    public let intervals: Int
    public let count: Double

    public var id: Int { intervals }

    public init(intervals: Int, count: Double) {
        self.intervals = intervals
        self.count = count
    }
}

public struct PathsGraph: Sendable, Equatable {
    /// Ranked by traffic, busiest first.
    public let edges: [PathEdge]

    public init(edges: [PathEdge]) {
        self.edges = edges.sorted { $0.value > $1.value }
    }

    public var busiest: Double { edges.first?.value ?? 0 }
}

public struct PathEdge: Sendable, Equatable, Identifiable {
    public let source: String
    public let target: String
    public let value: Double
    public let averageConversionTime: Double?
    /// The step index PostHog prefixes onto the source node name.
    public let step: Int?

    public var id: String { "\(source)→\(target)" }

    public init(rawSource: String, rawTarget: String, value: Double, averageConversionTime: Double?) {
        let (step, source) = Self.split(rawSource)
        self.source = source
        self.target = Self.split(rawTarget).name
        self.value = value
        self.averageConversionTime = averageConversionTime
        self.step = step
    }

    /// PostHog encodes a node as `"<step>_<name>"`. The prefix is layout
    /// metadata for its Sankey, not something to show a user.
    static func split(_ raw: String) -> (step: Int?, name: String) {
        guard let underscore = raw.firstIndex(of: "_"),
              let step = Int(raw[raw.startIndex..<underscore])
        else { return (nil, raw) }
        return (step, String(raw[raw.index(after: underscore)...]))
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
    /// Parsed from `day`. Charts need a real `Date` on the x-axis so the axis can
    /// thin its own labels — plotting the day strings categorically forces a
    /// label per category and turns a month of data into unreadable overlap.
    public let date: Date?

    public init(day: String, value: Double) {
        self.day = day
        self.value = value
        self.date = PostHogDate.parseDay(day)
    }
}

public extension Series {
    /// Points with usable dates, or `nil` when the labels aren't dates at all
    /// (some breakdowns are plain strings), in which case the caller falls back
    /// to a categorical axis.
    var datedPoints: [(date: Date, value: Double)]? {
        let dated = points.compactMap { point in
            point.date.map { (date: $0, value: point.value) }
        }
        return dated.count == points.count && !dated.isEmpty ? dated : nil
    }
}

public struct BarValue: Sendable, Equatable {
    /// What to draw beside the bar.
    public let label: String
    public let value: Double

    /// The breakdown value exactly as PostHog sent it, which is what an actors
    /// query has to be given.
    ///
    /// Separate from `label` because the two genuinely differ: the sentinel
    /// `$$_posthog_breakdown_null_$$` is shown as "(no value)" but must be sent
    /// back verbatim. Defaults to `label`, so a bar that is not a breakdown is
    /// unaffected.
    public let rawValue: String

    public init(label: String, value: Double, rawValue: String? = nil) {
        self.label = label
        self.value = value
        self.rawValue = rawValue ?? label
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
