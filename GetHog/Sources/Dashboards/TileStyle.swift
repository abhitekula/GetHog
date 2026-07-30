import GetHogKit
import SwiftUI

/// Identity for an insight *kind* — its symbol, its spine colour, and how much
/// room it wants on a wide canvas.
///
/// Deliberately keyed to the kind of question the tile answers, never to the
/// data inside it. Two dashboards showing different numbers should still look
/// like the same dashboard, and a funnel should be findable at a glance without
/// reading its title.
enum TileStyle {

    static func symbol(for model: InsightRenderModel) -> String {
        switch model {
        case .timeSeries(_, let style):
            switch style {
            case .line: "chart.xyaxis.line"
            case .area: "chart.line.uptrend.xyaxis"
            case .bar, .stackedBar: "chart.bar"
            }
        case .barValue: "chart.bar.doc.horizontal"
        case .bigNumber: "number"
        case .funnel: "line.3.horizontal.decrease"
        case .lifecycle: "arrow.triangle.2.circlepath"
        case .retention: "square.grid.3x3"
        case .stickiness: "calendar.badge.clock"
        case .paths: "point.topleft.down.to.point.bottomright.curvepath"
        case .unsupported: "questionmark.square.dashed"
        }
    }

    /// Spine colour. Drawn from the validated series palette so it is already
    /// colourblind-safe and dark-mode-correct, but assigned by kind rather than
    /// by series index, so it never implies the tile's first series.
    static func accent(for model: InsightRenderModel) -> Color {
        switch model {
        case .timeSeries: SeriesPalette.color(at: 0)   // blue
        case .barValue: SeriesPalette.color(at: 6)     // violet
        case .bigNumber: SeriesPalette.color(at: 2)    // aqua
        case .funnel: SeriesPalette.color(at: 1)       // orange
        case .lifecycle: SeriesPalette.color(at: 5)    // green
        case .retention: SeriesPalette.color(at: 4)    // magenta
        case .stickiness: SeriesPalette.color(at: 3)   // yellow
        case .paths: SeriesPalette.color(at: 7)        // red
        case .unsupported: Color.secondary
        }
    }

    /// How many grid columns the tile would like on a wide canvas.
    ///
    /// Only the genuinely wide forms ask for two. A retention grid has one
    /// column per interval and wraps into nonsense when narrow; a paths edge
    /// list carries two node names per row. Everything else — including time
    /// series — reads fine in half an iPad, and letting charts span too was
    /// worse than not spanning at all: on a two-column grid it made every tile
    /// full width and collapsed the layout back into one tall column.
    static func preferredColumns(for model: InsightRenderModel) -> Int {
        switch model {
        // Wide by nature: a retention grid is a table, a paths graph is a
        // flow, and lifecycle stacks four series with a four-item legend —
        // squeezed into one column its category labels collide into mush.
        case .retention, .paths, .lifecycle: 2
        case .timeSeries, .barValue, .funnel, .stickiness, .bigNumber, .unsupported: 1
        }
    }
}
