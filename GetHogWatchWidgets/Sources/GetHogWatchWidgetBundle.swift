import SwiftUI
import WidgetKit

/// watchOS complications: a placeholder bundle only — the real complications
/// arrive with the platform shell in a later task. The file exists so the
/// appex plumbing (bundle id, embed, entitlements) can be verified now. The
/// rule the iOS and Mac bundles document applies here unchanged: widgets
/// render the App Group snapshot and never call the PostHog API.
@main
struct GetHogWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchPlaceholderWidget()
    }
}

struct WatchPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "GetHogWatchPlaceholder",
            provider: PlaceholderProvider()
        ) { _ in
            Text("GetHog")
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("GetHog")
        .description("Placeholder until the watchOS complications land.")
    }
}

struct PlaceholderProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
