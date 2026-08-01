import Foundation
import Testing

@testable import GetHog

/// Column arithmetic for the dashboard grid.
///
/// Written after a crash, not before it: `columnCount` divided an infinite
/// proposed width and fed the result to `Int()`, which is a trap rather than a
/// large number. It took the app down the first time a tile was tapped on iPad,
/// because collapsing the sidebar makes the parent re-measure with an unbounded
/// proposal.
@Suite("Masonry column count")
struct MasonryLayoutTests {

    /// Deliberately uses the shipped `minColumnWidth` rather than passing one.
    /// An earlier version of this suite supplied its own, which meant it proved
    /// something true of a number the app never uses — and passed while the real
    /// grid collapsed to a single column.
    private let layout = MasonryLayout(columns: 2, spacing: Theme.Space.l)

    @Test("an infinite proposal does not trap")
    func infiniteWidth() {
        // The bug. `Int(.infinity)` is a runtime trap, and a `width > 0` guard
        // sails straight past it.
        #expect(layout.columnCount(for: .infinity) == 2)
    }

    @Test("a NaN proposal does not trap")
    func nanWidth() {
        // NaN reaches Int() the same way. It escaped the original guard for a
        // different reason: every comparison against NaN is false, so
        // `width > 0` rejected it by luck rather than by intent.
        #expect(layout.columnCount(for: .nan) == 2)
    }

    @Test("a width that fits two readable columns uses two")
    func twoColumns() {
        // 490pt is the measured detail-pane width on an 11-inch iPad in
        // portrait with the sidebar showing.
        #expect(layout.columnCount(for: 490) == 2)
    }

    @Test("a width too narrow for two readable columns drops to one")
    func oneColumn() {
        // Rather than two columns of ~150pt, where titles clip to a single
        // character and axis labels overlap.
        #expect(layout.columnCount(for: 320) == 1)
    }

    @Test("never exceeds the caller's ceiling however wide the canvas")
    func respectsCeiling() {
        // A 13-inch iPad could fit four columns at this minimum; four columns
        // of charts read as postage stamps, which is why the ceiling exists.
        #expect(layout.columnCount(for: 4000) == 2)
    }

    @Test("degenerate widths fall back rather than producing zero columns")
    func zeroWidth() {
        // Zero columns would divide by zero one line later.
        #expect(layout.columnCount(for: 0) >= 1)
        #expect(layout.columnCount(for: -50) >= 1)
    }
}
