import SwiftUI

/// Column layout that places each tile in whichever column is currently
/// shortest, and lets a tile claim more than one column.
///
/// `LazyVGrid` fills strictly left-to-right and gives every cell in a row the
/// height of the tallest one, so a short retention grid next to a tall chart
/// left a visible hole and the whole dashboard stopped halfway down an iPad
/// with nothing below it. Placing by shortest column removes the holes; letting
/// a time series claim two columns stops a month of dates being crushed into a
/// third of the width.
struct MasonryLayout: Layout {
    /// Upper bound on columns. The layout uses fewer when the width cannot give
    /// each one `minColumnWidth`.
    var columns: Int
    var spacing: CGFloat = Theme.Space.l

    /// Narrowest a tile may get before a column is dropped.
    ///
    /// Column count is derived from the width actually granted rather than
    /// fixed by the caller, because the caller does not know it: opening the
    /// inspector or the sidebar changes the detail pane's width underneath the
    /// grid. A fixed count meant two columns of roughly 150pt each, in which
    /// titles clipped to one character and axis labels drew on top of each
    /// other. Below this width a chart has stopped being readable, so the grid
    /// gives up a column instead of the data.
    /// Measured, not guessed: on an 11-inch iPad in portrait with the sidebar
    /// showing, the detail pane is about 490pt, and two columns at ~237pt each
    /// render a month of dates with legible axis labels.
    ///
    /// The value has to sit *below* that 237, not at it — two columns need
    /// `width + spacing >= 2 * (minColumnWidth + spacing)`, so 240 was still one
    /// point too greedy and collapsed the very pane it was chosen for. The test
    /// suite pins the 490pt case for exactly this reason.
    var minColumnWidth: CGFloat = 230

    /// Columns that actually fit in `width`.
    ///
    /// The finiteness check is load-bearing, not defensive. A `Layout` is
    /// routinely proposed an **infinite** width while the parent is measuring —
    /// here it happened the moment the sidebar collapsed — and `Int(.infinity)`
    /// is a hard trap, not a large number. It crashed the app on the first
    /// tile tap.
    ///
    /// This is the same trap as `JSONValue.stringValue`, fixed earlier in this
    /// project for the same reason: a `> 0` guard does not exclude infinity.
    func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return columns }
        let fitting = Int((width + spacing) / (minColumnWidth + spacing))
        return max(1, min(columns, fitting))
    }

    struct Cache {
        var heights: [CGFloat] = []
        var placements: [(x: CGFloat, y: CGFloat, width: CGFloat)] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let solved = solve(width: width, subviews: subviews)
        cache = solved
        return CGSize(width: width, height: solved.heights.max() ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        // Re-solve against the real width: `sizeThatFits` may have been asked
        // about a different proposal than the one finally granted.
        let solved = solve(width: bounds.width, subviews: subviews)
        cache = solved
        for (index, subview) in subviews.enumerated() {
            guard index < solved.placements.count else { break }
            let spot = solved.placements[index]
            subview.place(
                at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y),
                proposal: ProposedViewSize(width: spot.width, height: nil)
            )
        }
    }

    private func solve(width rawWidth: CGFloat, subviews: Subviews) -> Cache {
        // Same reason as `columnCount`: an infinite proposal reaches here
        // during measurement, and an infinite column width poisons every
        // placement derived from it.
        let width = rawWidth.isFinite ? rawWidth : 0
        let count = columnCount(for: rawWidth)
        let totalSpacing = spacing * CGFloat(count - 1)
        let columnWidth = max(1, (width - totalSpacing) / CGFloat(count))

        var heights = [CGFloat](repeating: 0, count: count)
        var placements: [(x: CGFloat, y: CGFloat, width: CGFloat)] = []

        for subview in subviews {
            // A tile states how many columns it wants; clamp so a 2-column tile
            // on a 1-column phone simply becomes full width rather than
            // overflowing off-screen.
            let span = min(max(1, subview[TileSpanKey.self]), count)
            let start = startColumn(for: span, in: heights)
            let tileWidth = columnWidth * CGFloat(span) + spacing * CGFloat(span - 1)
            let height = subview.sizeThatFits(
                ProposedViewSize(width: tileWidth, height: nil)
            ).height

            // A spanning tile begins below every column it covers, otherwise it
            // would overlap whichever of them is taller.
            let top = (start..<(start + span)).map { heights[$0] }.max() ?? 0
            placements.append((
                x: CGFloat(start) * (columnWidth + spacing),
                y: top,
                width: tileWidth
            ))
            for column in start..<(start + span) {
                heights[column] = top + height + spacing
            }
        }

        // Trim the trailing spacing so the layout doesn't report a phantom row.
        return Cache(
            heights: heights.map { max(0, $0 - spacing) },
            placements: placements
        )
    }

    /// The run of `span` adjacent columns whose deepest point is highest up.
    private func startColumn(for span: Int, in heights: [CGFloat]) -> Int {
        guard span < heights.count else { return 0 }
        var best = 0
        var bestTop = CGFloat.greatestFiniteMagnitude
        for start in 0...(heights.count - span) {
            let top = (start..<(start + span)).map { heights[$0] }.max() ?? 0
            if top < bestTop {
                bestTop = top
                best = start
            }
        }
        return best
    }
}

/// How many columns a tile wants. Read by `MasonryLayout` during placement.
private struct TileSpanKey: LayoutValueKey {
    static let defaultValue: Int = 1
}

extension View {
    func tileSpan(_ span: Int) -> some View {
        layoutValue(key: TileSpanKey.self, value: span)
    }
}
