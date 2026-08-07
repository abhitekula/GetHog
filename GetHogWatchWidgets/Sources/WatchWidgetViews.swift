import GetHogKit
import GetHogUI
import SwiftUI
import WidgetKit

// The drawing helpers the three complications share.
//
// Everything here needs `SwiftUI`, which is exactly why none of it is in
// `WatchWidgetCore.swift`: that file is compiled into the app target so
// `GetHogWatchTests` can run it, and naming a SwiftUI `View` type from a test
// on this platform crashes the watchOS test host (measured — see
// `WatchSparklineMath`). The split is load-bearing, not tidiness.

// MARK: - Direction

/// Direction as a glyph, never as a colour alone.
///
/// Deliberately not painted good-green / bad-red: the snapshot records how a
/// number moved, not whether moving that way is desirable — a rise in errors
/// and a rise in signups are the same field. `WidgetPalette` on iOS refuses the
/// same temptation for the same reason, and on an accessory family the system
/// flattens colour anyway.
enum WatchWidgetDirection {

    static func symbol(for direction: SharedSnapshot.Metric.Direction) -> String {
        switch direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        case .unknown: "minus"
        }
    }

    /// The change as a complication shows it: a percentage when there is a
    /// usable baseline, the raw move when the baseline was zero, and nothing at
    /// all when there is no comparison. "No baseline" is a fact worth omitting
    /// on a screen this size, not worth spelling.
    static func changeLabel(for metric: SharedSnapshot.Metric) -> String? {
        if let fraction = metric.deltaFraction {
            return MetricWatch.format(abs(fraction * 100)) + "%"
        }
        if let delta = metric.delta {
            return WatchWidgetNumber.compact(abs(delta), unit: metric.unit)
        }
        return nil
    }

    /// Value *and* direction in one phrase. A face that reads out only
    /// "12.5 thousand" has hidden the half of the information the arrow carries.
    static func spokenLabel(for metric: SharedSnapshot.Metric) -> String {
        var parts = [metric.title, WatchWidgetNumber.full(metric.value, unit: metric.unit)]
        let change = changeLabel(for: metric)
        switch metric.direction {
        case .up: parts.append("up \(change ?? "")")
        case .down: parts.append("down \(change ?? "")")
        case .flat: parts.append("unchanged")
        case .unknown: parts.append("no comparison available")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Arrow and change, sized for a rectangular accessory row.
struct WatchDeltaLine: View {
    let metric: SharedSnapshot.Metric

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: WatchWidgetDirection.symbol(for: metric.direction))
                .imageScale(.small)
                .font(.caption2.weight(.bold))
            if let change = WatchWidgetDirection.changeLabel(for: metric) {
                Text(change)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityHidden(true)
    }
}

// MARK: - Age

/// The age line, which every rectangular face carries.
///
/// A complication whose numbers may be hours old and does not say so is worse
/// than none — the wrist gives no other clue. Where there is no room to draw it
/// (circular, corner, inline) the age travels in the accessibility label
/// instead, never nowhere.
struct WatchAgeFooter: View {
    let freshness: WatchFreshness

    var body: some View {
        Text(freshness.shortLabel)
            .font(.caption2)
            .foregroundStyle(freshness.isStale ? Theme.accentWarm : Theme.Ink.tertiary)
            .accessibilityLabel(freshness.spokenLabel)
    }
}

// MARK: - Empty states

/// The words for a complication with nothing to show, on a face with room for
/// words. Honest about which of the two problems it is: a project that has
/// never synced is not a project with nothing in it.
struct WatchNoDataView: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The circular and corner faces have room for one glyph, so the glyph *is* the
/// message and the label carries the rest.
struct WatchNoDataGlyph: View {
    var symbol = "arrow.down.circle.dotted"
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .font(.headline)
            .accessibilityLabel(label)
    }
}
