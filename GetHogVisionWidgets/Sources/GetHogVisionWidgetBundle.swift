import SwiftUI
import WidgetKit

/// visionOS widgets: a placeholder bundle only — the real widgets arrive
/// with the platform shell in a later task. The file exists so the appex
/// plumbing (bundle id, embed, entitlements) can be verified now. The rule
/// the iOS and Mac bundles document applies here unchanged: widgets render
/// the App Group snapshot and never call the PostHog API.
@main
struct GetHogVisionWidgetBundle: WidgetBundle {
    var body: some Widget {
        VisionPlaceholderWidget()
    }
}

struct VisionPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "GetHogVisionPlaceholder",
            provider: PlaceholderProvider()
        ) { _ in
            Text("GetHog")
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("GetHog")
        .description("Placeholder until the visionOS widgets land.")
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
