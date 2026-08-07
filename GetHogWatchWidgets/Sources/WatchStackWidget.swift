import GetHogKit
import GetHogUI
import RelevanceKit
import SwiftUI
import WidgetKit

// The Smart Stack card.
//
// On watchOS the Smart Stack shows **rectangular** widgets, so this widget's
// single supported family is not a limitation to work around — it *is* what
// makes it the Smart Stack widget. The two complications next door are for a
// watch face; this is for the card that rotates up under one.
//
// It asks the system for promotion through **both** relevance APIs, because
// both are real on this SDK and they answer different questions:
//
// - `TimelineEntryRelevance` on every entry ranks this widget against its own
//   other entries, and decays as the snapshot ages.
// - `WidgetRelevance` (watchOS 11+) hands the system a *context* — here a date
//   interval — in which the card deserves a place in the rotation.
//
// They agree by construction: both come from
// `WatchComplicationCore`'s one firing derivation and expire on the same
// `SnapshotRelevance.decayHorizon` clock. There is no "alert" context in
// `RelevantContext` — a date interval while firing is the entire vocabulary —
// so the honest translation of "something is over its line" is "relevant from
// now until this snapshot's claim would have decayed to nothing".

struct WatchStackProvider: TimelineProvider {

    private let cache = WatchWidgetCache()

    func placeholder(in context: Context) -> WatchStackEntry {
        WatchWidgetSample.stackEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStackEntry) -> Void) {
        completion(context.isPreview ? WatchWidgetSample.stackEntry() : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStackEntry>) -> Void) {
        let now = Date()
        // Three reads for four entries. The feed is read here, once, and its
        // own `capturedAt` travels into the entry — the card ages the event
        // line by that stamp, never by the snapshot's.
        let snapshot = cache.snapshot()
        let watches = cache.watches()
        let activity = cache.activity()
        completion(
            WatchWidgetRefresh.timeline(from: now) { date in
                WatchComplicationCore.stackEntry(
                    snapshot: snapshot, watches: watches, activity: activity, date: date
                )
            }
        )
    }

    /// The coarse, system-facing claim. Quiet returns an empty
    /// `WidgetRelevance`, which is this widget declining the rotation rather
    /// than arguing for it on the strength of existing.
    func relevance() async -> WidgetRelevance<Void> {
        guard let window = WatchComplicationCore.stackRelevanceWindow(
            snapshot: cache.snapshot(), watches: cache.watches(), now: Date()
        ) else { return WidgetRelevance([]) }

        return WidgetRelevance([
            // `.informational` rather than `.scheduled`: nothing here is an
            // appointment the user made. A threshold went over a line, and the
            // card is worth seeing while that is still true.
            .init(context: .date(interval: window, kind: .informational)),
        ])
    }

    private func entry(at date: Date) -> WatchStackEntry {
        WatchComplicationCore.stackEntry(
            snapshot: cache.snapshot(),
            watches: cache.watches(),
            activity: cache.activity(),
            date: date
        )
    }
}

struct WatchStackWidget: Widget {

    static let kind = "app.gethog.watch.stack"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchStackProvider()) { entry in
            WatchStackWidgetView(entry: entry)
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("GetHog Alerts")
        .description(
            "Rises in the Smart Stack when one of your metric watches fires. GetHog refreshes it — the widget never calls the API itself."
        )
        // Rectangular only: that is the shape the watchOS Smart Stack shows.
        .supportedFamilies([.accessoryRectangular])
    }
}

struct WatchStackWidgetView: View {

    let entry: WatchStackEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder private var content: some View {
        switch entry.mode {
        case .alert(let title, let count):
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "bell.badge.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.Status.criticalInk)
                    Text(count == 1 ? "1 firing" : "\(count) firing")
                        .font(.headline)
                        .lineLimit(1)
                        .widgetAccentable()
                }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                WatchAgeFooter(freshness: entry.freshness)
            }

        case .quiet(let metricTitle, let valueText, let latestEvent, _):
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(valueText ?? "—")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(metricTitle ?? "No metrics")
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .widgetAccentable()
                }
                if let latestEvent, let eventFreshness = entry.eventFreshness {
                    // The event line carries the **feed's** age, which is not
                    // the snapshot's: a wake whose events query alone failed
                    // keeps the old feed, and one stamp for both would claim it
                    // had been re-read.
                    Text("\(latestEvent) · \(eventFreshness.shortLabel)")
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    WatchAgeFooter(freshness: entry.freshness)
                }
            }

        case .unsynced:
            WatchNoDataView(
                headline: "GetHog",
                detail: "Open GetHog on this watch to sync"
            )
        }
    }

    private var spokenLabel: String {
        switch entry.mode {
        case .alert(let title, let count):
            return "GetHog, \(count) metric \(count == 1 ? "watch" : "watches") firing, "
                + "\(title), \(entry.freshness.spokenLabel)"
        case .quiet(let metricTitle, let valueText, let latestEvent, _):
            var parts: [String] = ["GetHog, no metric watches firing"]
            if let metricTitle, let valueText { parts.append("\(metricTitle) \(valueText)") }
            if let latestEvent, let eventFreshness = entry.eventFreshness {
                parts.append("latest event \(latestEvent), \(eventFreshness.spokenLabel)")
            }
            parts.append(entry.freshness.spokenLabel)
            return parts.joined(separator: ", ")
        case .unsynced:
            return "GetHog, not synced yet. Open GetHog on this watch to sync."
        }
    }
}

#Preview("Smart Stack", as: .accessoryRectangular) {
    WatchStackWidget()
} timeline: {
    WatchWidgetSample.stackEntry()
}
