import GetHogKit
import GetHogUI
import SwiftUI
import WidgetKit

// The complication that answers a question rather than reporting a number:
// *is anything I asked to be told about over its line right now?*
//
// **Watch-local evaluation only, and the words are chosen to say no more than
// that.** The snapshot the wrist writes carries no `ingestion` and no `quota`
// — two requests the watch deliberately does not spend — so
// `SharedSnapshot.healthVerdict` is always `.unchecked` on it, and there is no
// honest way to draw "healthy". The app's error pulse is not visible here
// either: it lives in memory in the app process and is never persisted.
//
// So this face never says "healthy" or "all clear". Its four claims are
// "N firing", "quiet", "no metric watches on this watch", and "not synced yet"
// — each one a fact this process can actually check.

struct WatchHealthProvider: TimelineProvider {

    private let cache = WatchWidgetCache()

    func placeholder(in context: Context) -> WatchHealthEntry {
        WatchWidgetSample.healthEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchHealthEntry) -> Void) {
        completion(context.isPreview ? WatchWidgetSample.healthEntry() : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchHealthEntry>) -> Void) {
        let now = Date()
        // One pair of reads, four entries: the verdict never changes across a
        // timeline, only the dates do, which is what keeps the age label honest
        // without waking the provider again.
        let snapshot = cache.snapshot()
        let watches = cache.watches()
        completion(
            WatchWidgetRefresh.timeline(from: now) { date in
                WatchComplicationCore.healthEntry(
                    snapshot: snapshot, watches: watches, date: date
                )
            }
        )
    }

    private func entry(at date: Date) -> WatchHealthEntry {
        WatchComplicationCore.healthEntry(
            snapshot: cache.snapshot(), watches: cache.watches(), date: date
        )
    }
}

/// No configuration: there is nothing to choose. The watch list is whatever the
/// phone handed over, and a complication that let you hide the firing half
/// would be a worse lie than showing nothing.
struct WatchHealthComplication: Widget {

    static let kind = "app.gethog.watch.health"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchHealthProvider()) { entry in
            WatchHealthComplicationView(entry: entry)
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("Metric Watches")
        .description(
            "Your metric thresholds, firing or quiet. GetHog refreshes them — the widget never calls the API itself."
        )
        .supportedFamilies([
            .accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct WatchHealthComplicationView: View {

    let entry: WatchHealthEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryRectangular: rectangular
        case .accessoryInline: Text(inlineText).accessibilityLabel(spokenLabel)
        @unknown default: circular
        }
    }

    // MARK: State

    /// The glyph, chosen so a quiet watch face never wears an alarm and a
    /// never-synced one is not mistaken for a calm one.
    private var symbol: String {
        guard entry.hasSynced else { return "arrow.down.circle.dotted" }
        if entry.firingCount > 0 { return "bell.badge.fill" }
        return entry.watchCount == 0 ? "bell.slash" : "bell"
    }

    private var tint: Color {
        entry.firingCount > 0 ? Theme.Status.criticalInk : Theme.Ink.secondary
    }

    // MARK: Faces

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(tint)
                if entry.hasSynced {
                    // The count is the number that matters, and "0" beside a
                    // calm bell reads as quiet rather than as an alarm at zero.
                    Text("\(entry.firingCount > 0 ? entry.firingCount : entry.watchCount)")
                        .font(.system(.headline, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var corner: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tint)
            .widgetLabel { Text(cornerLabel) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !entry.hasSynced {
                WatchNoDataView(
                    headline: "Metric watches",
                    detail: "Open GetHog on this watch to sync"
                )
            } else {
                Text(headline)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                if entry.firingCount > 0 {
                    // Two titles is what the row height affords; the count in
                    // the headline already says how many there are in total.
                    ForEach(entry.firingRows.prefix(2)) { row in
                        Text(row.title)
                            .font(.caption2)
                            .foregroundStyle(Theme.Ink.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                WatchAgeFooter(freshness: entry.freshness)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Words

    /// Never a verdict. Every one of these is something this process checked.
    private var headline: String {
        guard entry.hasSynced else { return "Not synced yet" }
        if entry.firingCount > 0 { return "\(entry.firingCount) firing" }
        return entry.watchCount == 0 ? "No metric watches" : "Quiet"
    }

    private var detail: String {
        guard entry.hasSynced else { return "Open GetHog on this watch to sync" }
        if entry.watchCount == 0 {
            // The *observable* fact. Whether the thresholds failed to transfer
            // or were never made is app-side knowledge this process does not
            // have, and guessing would send the user to the wrong place.
            return "No metric watches on this watch"
        }
        return "\(entry.watchCount) watching, none over its line"
    }

    private var cornerLabel: String {
        guard entry.hasSynced else { return "Not synced" }
        return entry.firingCount > 0 ? "\(entry.firingCount) firing" : headline
    }

    private var inlineText: String {
        guard entry.hasSynced else { return "GetHog: not synced" }
        if entry.firingCount > 0 { return "GetHog: \(entry.firingCount) firing" }
        return entry.watchCount == 0 ? "GetHog: no watches" : "GetHog: quiet"
    }

    private var spokenLabel: String {
        guard entry.hasSynced else { return "GetHog metric watches, not synced yet" }
        let state = entry.firingCount > 0
            ? "\(entry.firingCount) firing: "
                + entry.firingRows.prefix(2).map(\.title).joined(separator: ", ")
            : detail
        return "GetHog metric watches, \(state), \(entry.freshness.spokenLabel)"
    }
}

#Preview("Circular", as: .accessoryCircular) {
    WatchHealthComplication()
} timeline: {
    WatchWidgetSample.healthEntry()
}

#Preview("Rectangular", as: .accessoryRectangular) {
    WatchHealthComplication()
} timeline: {
    WatchWidgetSample.healthEntry()
}
