import AppIntents
import GetHogKit
import SwiftUI
import WidgetKit

// MARK: - Configuration

/// The metric the user picks in the widget's edit sheet.
///
/// The candidate list is read from the snapshot rather than the API. That is
/// forced — an extension must not make network calls — but it is also the right
/// answer: offering a metric that isn't cached would let the user configure a
/// widget that can only ever render "no data".
struct WidgetMetricEntity: AppEntity {

    let id: String
    let title: String
    let subtitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Metric" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    static var defaultQuery: WidgetMetricQuery { WidgetMetricQuery() }

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

struct WidgetMetricQuery: EntityQuery {

    func entities(for identifiers: [WidgetMetricEntity.ID]) async throws -> [WidgetMetricEntity] {
        let snapshot = WidgetCache.snapshot()
        return identifiers.compactMap { id in
            snapshot?.metric(id: id).map(WidgetMetricEntity.init)
        }
    }

    func suggestedEntities() async throws -> [WidgetMetricEntity] {
        (WidgetCache.snapshot()?.metrics ?? []).map(WidgetMetricEntity.init)
    }

    /// A widget dropped on the Home Screen without being configured still shows
    /// something real.
    func defaultResult() async -> WidgetMetricEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectMetricIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource { "Select Metric" }
    static var description: IntentDescription {
        IntentDescription("Choose which of your synced metrics this widget shows.")
    }

    @Parameter(title: "Metric")
    var metric: WidgetMetricEntity?

    init() {}

    init(metric: WidgetMetricEntity?) {
        self.metric = metric
    }
}

// MARK: - Timeline

struct MetricEntry: TimelineEntry {
    let date: Date
    let projectName: String
    /// `nil` until the app has written its first snapshot.
    let capturedAt: Date?
    /// The configured metric first, then the rest — the multi-metric families
    /// read straight off this list.
    let metrics: [SharedSnapshot.Metric]

    var primary: SharedSnapshot.Metric? { metrics.first }
    var hasData: Bool { capturedAt != nil && !metrics.isEmpty }
    /// A synced project with nothing to show is a different problem from a
    /// project that has never synced, and it needs different words.
    var isEmptyProject: Bool { capturedAt != nil && metrics.isEmpty }
    var freshness: WidgetFreshness { WidgetFreshness(capturedAt: capturedAt, now: date) }

    static func sample(at date: Date = Date()) -> MetricEntry {
        MetricEntry(
            date: date,
            projectName: WidgetCache.sample.projectName,
            capturedAt: date,
            metrics: WidgetCache.sample.metrics
        )
    }

    static func empty(at date: Date = Date()) -> MetricEntry {
        MetricEntry(date: date, projectName: "GetHog", capturedAt: nil, metrics: [])
    }
}

struct MetricProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> MetricEntry {
        // Redacted by WidgetKit, so the numbers never reach the screen — but the
        // layout has to be the real one or the placeholder is the wrong shape.
        MetricEntry.sample()
    }

    func snapshot(for configuration: SelectMetricIntent, in context: Context) async -> MetricEntry {
        // The gallery preview runs before the user has chosen anything; showing
        // sample data there beats showing an empty rectangle.
        context.isPreview ? MetricEntry.sample() : entry(for: configuration, at: Date())
    }

    func timeline(for configuration: SelectMetricIntent, in context: Context) async -> Timeline<MetricEntry> {
        let now = Date()
        // Every entry carries the same cached values; only `date` moves, so the
        // "Updated Xm ago" line stays truthful without another provider call.
        // See `WidgetRefresh` for why this is not a 15-minute reload loop.
        let snapshot = WidgetCache.snapshot()
        return WidgetRefresh.timeline(from: now) { date in
            entry(for: configuration, at: date, snapshot: snapshot)
        }
    }

    private func entry(
        for configuration: SelectMetricIntent,
        at date: Date,
        snapshot: SharedSnapshot? = WidgetCache.snapshot()
    ) -> MetricEntry {
        guard let snapshot else { return .empty(at: date) }
        let chosen = configuration.metric?.id
        let ordered: [SharedSnapshot.Metric] = {
            guard let chosen, let match = snapshot.metric(id: chosen) else { return snapshot.metrics }
            return [match] + snapshot.metrics.filter { $0.id != chosen }
        }()
        return MetricEntry(
            date: date,
            projectName: snapshot.projectName,
            capturedAt: snapshot.capturedAt,
            metrics: ordered
        )
    }
}

// MARK: - Widget

struct MetricWidget: Widget {

    static let kind = "app.gethog.widget.metric"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectMetricIntent.self, provider: MetricProvider()) { entry in
            MetricWidgetView(entry: entry)
                // Required from iOS 17: without it the widget draws its own
                // background and the system renders it clipped and inset wrong.
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Metric")
        .description("A metric from your last sync. GetHog refreshes it — the widget never calls the API itself.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

struct MetricWidgetView: View {

    let entry: MetricEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.hasData {
            content
        } else {
            noData
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        case .systemLarge, .systemExtraLarge: large
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .accessoryInline: InlineMetricView(metric: entry.primary)
        @unknown default: small
        }
    }

    /// Accessory families have no room for a call to action and no button
    /// support, so they state the problem in the space they have.
    @ViewBuilder
    private var noData: some View {
        switch family {
        case .accessoryInline: Text("GetHog: no data")
        case .accessoryCircular:
            Image(systemName: "arrow.down.circle.dotted")
                .accessibilityLabel("GetHog has no synced data yet")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("GetHog").font(.headline)
                Text(entry.isEmptyProject ? "No metrics cached" : "Open the app to sync").font(.caption)
            }
            .accessibilityElement(children: .combine)
        default:
            NoDataView(
                message: entry.isEmptyProject
                    ? "No metrics cached yet. Open a dashboard in GetHog."
                    : "Open GetHog to sync"
            )
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let metric = entry.primary {
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                // The sparkline is the first thing sacrificed when the text
                // needs the room — at accessibility sizes it is the least
                // informative element on screen.
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        headline(metric)
                        Sparkline(points: metric.sparkline).frame(height: 24)
                    }
                    headline(metric)
                }
                Spacer(minLength: 2)
                FreshnessFooter(freshness: entry.freshness)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(_ metric: SharedSnapshot.Metric) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(WidgetNumber.compact(metric.value, unit: metric.unit))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            DeltaBadge(metric: metric)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetAccessibility.label(for: metric))
    }

    /// One metric gets a chart with a legend; without a specific choice the
    /// space is better spent on three metrics than on one large number.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                if let metric = entry.primary, metric.sparkline.count >= 2 {
                    VStack(alignment: .leading, spacing: 2) {
                        MetricTile(metric: metric, valueFont: .title, showsSparkline: false)
                        Spacer(minLength: 0)
                        legend(for: metric)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Sparkline(points: metric.sparkline)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.metrics.prefix(3)) { metric in
                            MetricTile(metric: metric, valueFont: .body, showsSparkline: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            FreshnessFooter(freshness: entry.freshness)
        }
    }

    private func legend(for metric: SharedSnapshot.Metric) -> some View {
        HStack(spacing: 6) {
            legendItem("low", value: metric.sparkline.min())
            legendItem("high", value: metric.sparkline.max())
            if let previous = metric.previous {
                legendItem("prev", value: previous)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func legendItem(_ label: String, value: Double?) -> some View {
        if let value {
            Text("\(label) \(WidgetNumber.compact(value))")
                .accessibilityLabel("\(label) \(WidgetNumber.full(value))")
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.projectName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Two columns of tiles, four to six of them. `LazyVGrid` rather than
            // a fixed layout so a project with only two cached metrics doesn't
            // render two empty holes.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(entry.metrics.prefix(6)) { metric in
                    MetricTile(metric: metric)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            FreshnessFooter(freshness: entry.freshness)
        }
    }

    // MARK: Lock Screen

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
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    DeltaBadge(metric: metric, compact: true)
                }
                Text(entry.freshness.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessoryLabel)
    }

    private var circular: some View {
        VStack(spacing: 0) {
            if let metric = entry.primary {
                Image(systemName: WidgetPalette.symbol(for: metric.direction))
                    .font(.caption2)
                Text(WidgetNumber.compact(metric.value, unit: metric.unit))
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessoryLabel)
    }

    private var accessoryLabel: String {
        guard let metric = entry.primary else { return "GetHog, no data" }
        return WidgetAccessibility.label(for: metric) + ", " + entry.freshness.spokenLabel
    }
}

#Preview("Small", as: .systemSmall) {
    MetricWidget()
} timeline: {
    MetricEntry.sample()
    MetricEntry.empty()
}

#Preview("Medium", as: .systemMedium) {
    MetricWidget()
} timeline: {
    MetricEntry.sample()
}

#Preview("Large", as: .systemLarge) {
    MetricWidget()
} timeline: {
    MetricEntry.sample()
}

#Preview("Rectangular", as: .accessoryRectangular) {
    MetricWidget()
} timeline: {
    MetricEntry.sample()
}
