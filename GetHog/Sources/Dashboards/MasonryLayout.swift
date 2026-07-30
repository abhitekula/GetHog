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
    var columns: Int
    var spacing: CGFloat = Theme.Space.l

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

    private func solve(width: CGFloat, subviews: Subviews) -> Cache {
        let count = max(1, columns)
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
