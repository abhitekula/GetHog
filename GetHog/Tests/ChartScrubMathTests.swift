import CoreGraphics
import Foundation
import GetHogKit
import GetHogUI
import Testing

@testable import GetHog

/// The pure arithmetic under chart scrubbing: nearest-point resolution shared
/// by the iOS touch path and the macOS hover path, and the hover-only
/// plot-frame clamp.
///
/// Extracted and pinned for Task 7 (Mac hover scrubbing): the hover pipeline
/// is pointer → plot offset → `ChartProxy.value(atX:)` → nearest sample, and
/// the two ends of that pipeline are the parts that are pure.
@Suite("Chart scrub math")
struct ChartScrubMathTests {

    // Weekly points, deliberately uneven in value, even in spacing.
    private let points = [
        Point(day: "2026-06-01", value: 10),
        Point(day: "2026-06-08", value: 51),
        Point(day: "2026-06-15", value: 28),
    ]

    @Test("an exact hit resolves to its own point")
    func exactHit() {
        let hit = ChartScrubMath.nearestDatedPoint(in: points, to: points[1].date!)
        #expect(hit == points[1])
    }

    @Test("a date between samples resolves to the closer one")
    func nearestWins() {
        // A day past June 8 is six days short of June 15.
        let nearJune8 = points[1].date!.addingTimeInterval(86_400)
        #expect(ChartScrubMath.nearestDatedPoint(in: points, to: nearJune8) == points[1])
    }

    @Test("an exact midpoint resolves to the earlier point")
    func midpointTakesTheEarlier() {
        // `min(by:)` with a strict `<` keeps the first of two equal elements,
        // and the points arrive chronologically. Pinned because the hover
        // path inherits whichever way this falls.
        let midpoint = points[0].date!.addingTimeInterval(
            points[1].date!.timeIntervalSince(points[0].date!) / 2
        )
        #expect(ChartScrubMath.nearestDatedPoint(in: points, to: midpoint) == points[0])
    }

    @Test("a date before the range clamps to the first point")
    func clampsToFirst() {
        let early = points[0].date!.addingTimeInterval(-30 * 86_400)
        #expect(ChartScrubMath.nearestDatedPoint(in: points, to: early) == points[0])
    }

    @Test("a date after the range clamps to the last point")
    func clampsToLast() {
        let late = points[2].date!.addingTimeInterval(30 * 86_400)
        #expect(ChartScrubMath.nearestDatedPoint(in: points, to: late) == points[2])
    }

    @Test("points whose labels are not dates are skipped, not matched")
    func datelessSkipped() {
        // Some breakdowns label points with plain strings; `Point` parses
        // those to a nil date and the scrub must look straight past them.
        let mixed = [Point(day: "Chrome", value: 4), points[1]]
        #expect(ChartScrubMath.nearestDatedPoint(in: mixed, to: points[0].date!) == points[1])
    }

    @Test("a series with no dated points resolves to nothing")
    func allDateless() {
        let none = [Point(day: "Chrome", value: 4), Point(day: "Safari", value: 2)]
        #expect(ChartScrubMath.nearestDatedPoint(in: none, to: points[0].date!) == nil)
    }

    @Test("an empty series resolves to nothing")
    func empty() {
        #expect(ChartScrubMath.nearestDatedPoint(in: [], to: points[0].date!) == nil)
    }

    // The frame the plot occupies inside the chart overlay: the y-axis labels
    // sit in the 40pt to its left, the x-axis labels below its 170pt.
    private let plot = CGRect(x: 40, y: 0, width: 300, height: 170)

    @Test("a location inside the plot becomes an offset from its leading edge")
    func insideThePlot() {
        #expect(ChartScrubMath.plotX(of: CGPoint(x: 100, y: 50), in: plot) == 60)
    }

    @Test("the leading edge itself is inside")
    func leadingEdge() {
        #expect(ChartScrubMath.plotX(of: CGPoint(x: 40, y: 50), in: plot) == 0)
    }

    @Test("a location over the y-axis labels does not scrub")
    func overTheAxisLabels() {
        #expect(ChartScrubMath.plotX(of: CGPoint(x: 10, y: 50), in: plot) == nil)
    }

    @Test("a location below the plot does not scrub")
    func belowThePlot() {
        #expect(ChartScrubMath.plotX(of: CGPoint(x: 100, y: 200), in: plot) == nil)
    }

    @Test("the trailing edge is outside, as CGRect defines containment")
    func trailingEdge() {
        // `CGRect.contains` is half-open — maxX is out. Fine here: the last
        // rendered column ends a fraction of a point inside, and `.ended`
        // arriving as the pointer leaves would stop updates anyway.
        #expect(ChartScrubMath.plotX(of: CGPoint(x: 340, y: 50), in: plot) == nil)
    }
}
