import AppIntents
import GetHogKit
import GetHogUI
import SwiftUI
import WidgetKit

// MARK: - Configuration

/// The metric the user picks when adding the complication.
///
/// The candidate list is read from the cached snapshot rather than the API.
/// That is forced — this process must not make network calls — but it is also
/// the right answer: offering a metric that isn't cached would let the user
/// configure a complication that can only ever say "no data".
///
/// A watch-local twin of the iOS `WidgetMetricEntity`. Intent types cannot be
/// shared across extension targets — each appex registers its own — so the two
/// dozen lines are restated rather than imported.
struct WatchMetricEntity: AppEntity {

    let id: String
    let title: String
    let subtitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Metric" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    static var defaultQuery: WatchMetricQuery { WatchMetricQuery() }

    init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    init(_ metric: SharedSnapshot.Metric) {
        id = metric.id
        title = metric.title
        subtitle = WidgetNumber.compact(metric.value, unit: metric.unit)
    }
}

struct WatchMetricQuery: EntityQuery {

    func entities(for identifiers: [WatchMetricEntity.ID]) async throws -> [WatchMetricEntity] {
        let snapshot = WatchWidgetCache().snapshot()
        return identifiers.compactMap { id in
            snapshot?.metric(id: id).map(WatchMetricEntity.init)
        }
    }

    func suggestedEntities() async throws -> [WatchMetricEntity] {
        (WatchWidgetCache().snapshot()?.metrics ?? []).map(WatchMetricEntity.init)
    }

    /// A complication added from the face editor without being configured still
    /// shows something real.
    func defaultResult() async -> WatchMetricEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectWatchMetricIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource { "Select Metric" }
    static var description: IntentDescription {
        IntentDescription("Choose which of your synced metrics this complication shows.")
    }

    @Parameter(title: "Metric")
    var metric: WatchMetricEntity?

    init() {}

    init(metric: WatchMetricEntity?) {
        self.metric = metric
    }
}

// MARK: - Provider

struct WatchMetricProvider: AppIntentTimelineProvider {

    private let cache = WatchWidgetCache()

    /// The watch gallery lists one entry per recommendation, so this is what
    /// turns "GetHog" in the complication picker into the user's actual metric
    /// names. A protocol requirement on watchOS — unlike iOS, there is no
    /// default implementation — and returning an empty array would leave the
    /// complication unofferable.
    func recommendations() -> [AppIntentRecommendation<SelectWatchMetricIntent>] {
        let metrics = cache.snapshot()?.metrics ?? []
        guard !metrics.isEmpty else {
            // Nothing cached yet: still offer the complication, unconfigured.
            // It will say "not synced" until the app runs, which is the honest
            // state and better than being absent from the picker entirely.
            return [
                AppIntentRecommendation(
                    intent: SelectWatchMetricIntent(metric: nil), description: Text("Metric")
                ),
            ]
        }
        return metrics.map { metric in
            AppIntentRecommendation(
                intent: SelectWatchMetricIntent(metric: WatchMetricEntity(metric)),
                description: Text(metric.title)
            )
        }
    }

    func placeholder(in context: Context) -> WatchMetricEntry {
        // Redacted by WidgetKit, so the numbers never reach the screen — but the
        // layout has to be the real one or the placeholder is the wrong shape.
        WatchWidgetSample.metricEntry()
    }

    func snapshot(
        for configuration: SelectWatchMetricIntent, in context: Context
    ) async -> WatchMetricEntry {
        // The gallery preview runs before the user has chosen anything; sample
        // data there beats an empty rectangle.
        context.isPreview
            ? WatchWidgetSample.metricEntry()
            : entry(for: configuration, at: Date())
    }

    func timeline(
        for configuration: SelectWatchMetricIntent, in context: Context
    ) async -> Timeline<WatchMetricEntry> {
        let now = Date()
        // Read once for the whole timeline: four entries from one pair of file
        // reads. Only `date` moves between them, which is what keeps the age
        // label truthful without another provider call. See
        // `WatchWidgetRefresh`.
        let snapshot = cache.snapshot()
        let watches = cache.watches()
        return WatchWidgetRefresh.timeline(from: now) { date in
            entry(for: configuration, at: date, snapshot: snapshot, watches: watches)
        }
    }

    private func entry(
        for configuration: SelectWatchMetricIntent,
        at date: Date,
        snapshot: SharedSnapshot? = nil,
        watches: [MetricWatch] = []
    ) -> WatchMetricEntry {
        WatchComplicationCore.metricEntry(
            snapshot: snapshot ?? cache.snapshot(),
            chosenMetricID: configuration.metric?.id,
            watches: watches,
            date: date
        )
    }
}

// MARK: - Widget

struct WatchMetricComplication: Widget {

    static let kind = "app.gethog.watch.metric"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: SelectWatchMetricIntent.self,
            provider: WatchMetricProvider()
        ) { entry in
            WatchMetricComplicationView(entry: entry)
                // Required from watchOS 10: without it the system renders the
                // complication clipped and inset wrong. Accessory families
                // discard the colour and render vibrant, so this is the shape
                // contract rather than a styling choice.
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("Metric")
        .description(
            "A metric from your last sync. GetHog refreshes it — the widget never calls the API itself."
        )
        .supportedFamilies([
            .accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct WatchMetricComplicationView: View {

    let entry: WatchMetricEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.hasData {
            content
        } else {
            noData
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        @unknown default: circular
        }
    }

    // MARK: Faces

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                if let metric = entry.primary {
                    Image(systemName: WatchWidgetDirection.symbol(for: metric.direction))
                        .font(.caption2)
                    Text(WidgetNumber.compact(metric.value, unit: metric.unit))
                        .font(.system(.headline, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// The corner face draws one thing and curves a label around the bezel, so
    /// the value goes in the middle and the title runs around it.
    private var corner: some View {
        Group {
            if let metric = entry.primary {
                Text(WidgetNumber.compact(metric.value, unit: metric.unit))
                    .font(.system(.title3, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .widgetLabel {
                        Text(metric.title)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let metric = entry.primary {
                Text(metric.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // Accented rendering splits the view into two layers; the
                    // title is the part worth tinting.
                    .widgetAccentable()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(WidgetNumber.compact(metric.value, unit: metric.unit))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    WatchDeltaLine(metric: metric)
                }
                WatchAgeFooter(freshness: entry.freshness)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var inline: some View {
        Group {
            if let metric = entry.primary {
                Text("\(metric.title) \(WidgetNumber.compact(metric.value, unit: metric.unit))")
            }
        }
        .accessibilityLabel(spokenLabel)
    }

    // MARK: No data

    /// Never a sample number: a face that draws invented figures while unsynced
    /// is indistinguishable from one drawing the user's own.
    @ViewBuilder private var noData: some View {
        switch family {
        case .accessoryInline:
            Text(entry.isEmptyProject ? "GetHog: no metrics" : "GetHog: not synced")
        case .accessoryCircular, .accessoryCorner:
            WatchNoDataGlyph(label: spokenLabel)
        default:
            WatchNoDataView(
                headline: "GetHog",
                detail: entry.isEmptyProject
                    ? "No metrics cached"
                    : "Open GetHog on this watch to sync"
            )
        }
    }

    private var spokenLabel: String {
        guard let metric = entry.primary else {
            return entry.isEmptyProject
                ? "GetHog, no metrics cached"
                : "GetHog, not synced yet"
        }
        return WatchWidgetDirection.spokenLabel(for: metric) + ", " + entry.freshness.spokenLabel
    }
}

#Preview("Circular", as: .accessoryCircular) {
    WatchMetricComplication()
} timeline: {
    WatchWidgetSample.metricEntry()
}

#Preview("Rectangular", as: .accessoryRectangular) {
    WatchMetricComplication()
} timeline: {
    WatchWidgetSample.metricEntry()
}
