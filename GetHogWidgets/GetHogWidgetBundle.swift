import SwiftUI
import WidgetKit

@main
struct GetHogWidgetBundle: WidgetBundle {
    var body: some Widget {
        MetricWidget()
    }
}

/// Placeholder so the extension target builds; the real timeline provider and
/// families land next.
struct MetricWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MetricWidget", provider: PlaceholderProvider()) { _ in
            Text("GetHog")
        }
        .configurationDisplayName("Metric")
        .description("A PostHog metric at a glance.")
    }
}

struct PlaceholderProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
