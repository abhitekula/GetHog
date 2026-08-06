import CoreGraphics
import Foundation
import GetHogKit

/// The arithmetic under chart scrubbing, kept free of SwiftUI so it can be
/// tested as plain functions.
///
/// Two callers share it: the iOS touch path (`.chartXSelection` writes a
/// date, `TimeSeriesChart.selectedPoints` resolves it) and the macOS hover
/// path (`chartHoverSelection` converts the pointer location, then resolves
/// through the same property). One copy is what keeps the value a hover shows
/// and the value a finger reaches identical by construction.
public enum ChartScrubMath {

    /// The dated point nearest to `date`, or `nil` when no point carries one.
    ///
    /// Moved verbatim from `TimeSeriesChart.selectedPoints`, so the behavior
    /// is the shipped one, now stated as a testable fact. Ties resolve to the
    /// earlier point: `min(by:)` keeps the first of two equal elements, and
    /// trends points arrive in chronological order.
    public static func nearestDatedPoint(in points: [Point], to date: Date) -> Point? {
        points.filter({ $0.date != nil }).min(by: {
            abs(($0.date ?? .distantPast).timeIntervalSince(date))
                < abs(($1.date ?? .distantPast).timeIntervalSince(date))
        })
    }

    /// A hover location as an x-offset into the plot, or `nil` when the
    /// pointer is outside the plot area — over an axis label, the legend, or
    /// the scale padding — where a scrub would resolve to a point nobody is
    /// pointing at.
    ///
    /// Both arguments are in the same coordinate space (the chart overlay's);
    /// the result is relative to the plot's leading edge, which is the
    /// coordinate `ChartProxy.value(atX:)` expects.
    public static func plotX(of location: CGPoint, in plotFrame: CGRect) -> CGFloat? {
        guard plotFrame.contains(location) else { return nil }
        return location.x - plotFrame.minX
    }
}
