import GetHogKit
import GetHogUI
import SwiftUI
import WidgetKit

// The Smart Stack card.
//
// On watchOS the Smart Stack shows **rectangular** widgets, so this widget's
// single supported family is not a limitation to work around — it *is* what
// makes it the Smart Stack widget. The two complications next door are for a
// watch face; this is for the card that rotates up under one.
//
// `TimelineEntryRelevance` follows headline metric movement and decays as the
// snapshot ages. The card makes no coarse system-level alert claim.

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
        // Two reads for four entries. The feed is read here, once, and its
        // own `capturedAt` travels into the entry — the card ages the event
        // line by that stamp, never by the snapshot's.
        let snapshot = cache.snapshot()
        let activity = cache.activity()
        completion(
            WatchWidgetRefresh.timeline(from: now) { date in
                WatchComplicationCore.stackEntry(
                    snapshot: snapshot, activity: activity, date: date
                )
            }
        )
    }

    private func entry(at date: Date) -> WatchStackEntry {
        WatchComplicationCore.stackEntry(
            snapshot: cache.snapshot(),
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
        .configurationDisplayName("GetHog Glance")
        .description(
            "Your headline metric and newest cached event in the Smart Stack."
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
        case .quiet(let metricTitle, let valueText, let latestEvent, _):
            var parts: [String] = ["GetHog"]
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
