import GetHogKit
import SwiftUI

// MARK: - Offering the affordance

/// What a chart needs in order to offer "show me these people".
///
/// Passed through the environment rather than as a parameter on every chart
/// view, because the charts are nested three deep and most of them offer nothing
/// — threading an argument through `InsightChartView` into `FunnelChart` into
/// `FunnelStepRow` would touch every call site to serve two of them.
///
/// **`nil` is the whole degradation strategy.** A screen that cannot drill never
/// puts one of these in the environment, and every affordance below is written
/// so that it simply does not exist when the context is absent or when its
/// `axis` is not the one this chart draws. There is no path where a chart offers
/// a tap that then fails.
public struct InsightDrillContext {
    /// The insight's saved query subtree, verbatim.
    public let source: JSONValue
    /// Which axis this insight can actually be drilled along, from
    /// `InsightDrilldown.axis`.
    public let axis: InsightDrillAxis
    public let open: (InsightDrillRequest) -> Void

    public init(
        source: JSONValue,
        axis: InsightDrillAxis,
        open: @escaping (InsightDrillRequest) -> Void
    ) {
        self.source = source
        self.axis = axis
        self.open = open
    }

    /// Builds a context for an insight, or `nil` when it cannot be drilled.
    ///
    /// Costs nothing — every input is already on the screen. No request is made
    /// to find out whether a drill is possible, which matters because the
    /// rate-limit budget is organisation-wide.
    public init?(insight: Insight, open: @escaping (InsightDrillRequest) -> Void) {
        guard let source = insight.rawSource,
              let axis = InsightDrilldown.axis(
                  sourceKind: insight.sourceKind,
                  display: insight.displayType,
                  hasBreakdown: InsightDrilldown.hasBreakdown(source: source)
              )
        else { return nil }
        self.source = source
        self.axis = axis
        self.open = open
    }
}

extension EnvironmentValues {
    @Entry public var insightDrill: InsightDrillContext?
}

/// One tap, plus the other answers to the same question.
///
/// A chart element is almost never a single drill: a funnel step is two
/// populations, a lifecycle band is one per interval, a scrubbed day is one per
/// series. Those alternatives used to live in a `Menu` hung off the chart row,
/// which put a UIKit control in the middle of a chart — impossible to render for
/// review, and a `Menu`'s label takes the accent tint, so every funnel step
/// would have been drawn in teal.
///
/// So the chart row is a plain button that opens the most useful answer, and the
/// alternatives are offered inside the sheet, where a picker is ordinary. One
/// tap to the common case, and no request is ever made for a sibling the reader
/// did not ask for.
///
/// `Sendable` is spelled out rather than inferred: every member already
/// satisfies it, but a public struct does not get the conformance for free the
/// way an internal one does, and losing it silently across a module boundary is
/// exactly what Swift 6 mode exists to surface.
public struct InsightDrillRequest: Identifiable, Hashable, Sendable {
    public let selected: InsightDrill
    /// Every drill on the same axis, including `selected`. One entry means no
    /// picker is drawn.
    public let siblings: [InsightDrill]
    /// What the picker is picking, in the reader's words — "Step", "Week".
    public let axisLabel: String

    public var id: InsightDrillKind { selected.kind }

    public init(selected: InsightDrill, siblings: [InsightDrill] = [], axisLabel: String) {
        self.selected = selected
        self.siblings = siblings.isEmpty ? [selected] : siblings
        self.axisLabel = axisLabel
    }
}
