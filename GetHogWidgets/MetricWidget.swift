import AppIntents
import Foundation
import GetHogKit
import GetHogUI
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
    /// Paired with the metric's dashboard id so a tap cannot resolve the
    /// cached value against whichever project happens to be selected later.
    let projectID: Int?
    let projectName: String
    /// `nil` until the app has written its first snapshot.
    let capturedAt: Date?
    /// The configured metric first, then the rest — the multi-metric families
    /// read straight off this list.
    let metrics: [SharedSnapshot.Metric]
    /// Computed in the provider, where the user's watch list is one App Group read
    /// away, rather than here: an entry is a value WidgetKit copies around and
    /// re-reads, and touching the file system from a property it reads would turn
    /// one file read into one per render.
    let relevanceScore: Float

    var primary: SharedSnapshot.Metric? { metrics.first }
    var hasData: Bool { capturedAt != nil && !metrics.isEmpty }
    /// A synced project with nothing to show is a different problem from a
    /// project that has never synced, and it needs different words.
    var isEmptyProject: Bool { capturedAt != nil && metrics.isEmpty }
    var freshness: WidgetFreshness { WidgetFreshness(capturedAt: capturedAt, now: date) }

    /// What this entry claims in a Smart Stack. See `HealthEntry.relevance` for
    /// why the duration is a step rather than the default zero.
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: relevanceScore, duration: WidgetRefresh.step)
    }

    /// Zero for both, and deliberately. These feed the gallery and the redacted
    /// placeholder, which are not a ranking — a sample that claimed urgency would
    /// be this widget arguing for the top of a stack on data belonging to nobody.
    static func sample(at date: Date = Date()) -> MetricEntry {
        MetricEntry(
            date: date,
            projectID: nil,
            projectName: WidgetCache.sample.projectName,
            capturedAt: date,
            metrics: WidgetCache.sample.metrics,
            relevanceScore: 0
        )
    }

    static func empty(at date: Date = Date()) -> MetricEntry {
        MetricEntry(
            date: date,
            projectID: nil,
            projectName: "GetHog",
            capturedAt: nil,
            metrics: [],
            relevanceScore: 0
        )
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
        await WidgetSnapshotRefresh.run(.automaticWidget)
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
            projectID: snapshot.projectID,
            projectName: snapshot.projectName,
            capturedAt: snapshot.capturedAt,
            metrics: ordered,
            // Scored against the configured metric — `ordered.first` — because
            // that is the one every family leads with and the only one the small
            // and accessory families draw at all. The score decays with `date`, so
            // the four entries in a timeline rank lower as the snapshot behind
            // them ages, without the provider being woken to say so.
            relevanceScore: SnapshotRelevance.metric(ordered.first, in: snapshot, now: date)
        )
    }
}

// MARK: - Widget

struct MetricWidget: Widget {

    static let kind = "app.gethog.widget.metric"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectMetricIntent.self, provider: MetricProvider()) { entry in
            MetricWidgetView(entry: entry)
                // A populated metric opens the exact dashboard that produced
                // it. WidgetKit foregrounding alone would land at the generic
                // shell and could not prove the cached card still names its
                // source. An empty widget has no invented destination.
                .widgetURL(WidgetMetricRoute.url(
                    projectID: entry.projectID,
                    dashboardID: entry.primary?.dashboardID
                ))
                // Required from iOS 17: without it the widget draws its own
                // background and the system renders it clipped and inset wrong.
                //
                // The app's card tone rather than `.fill.tertiary`. A widget is
                // a card floating on the wallpaper, which is the same thing a
                // card is in the app, and it is the ground `Theme.Status`'s ink
                // tokens were actually measured against — 5.70:1 on card. The
                // system fill was never in that table. On the accessory families
                // the system discards the background and renders vibrant, so
                // this only takes effect where it was chosen.
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("Metric")
        .description("A metric from PostHog, refreshed directly without opening GetHog.")
        #if os(iOS)
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
        #else
        // The same widget minus the Lock Screen. Not a styling choice: macOS
        // marks every accessory family unavailable, while visionOS does not
        // declare those cases at all.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
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
        #if os(visionOS)
        case .systemExtraLargePortrait: large
        #endif
        #if os(iOS)
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .accessoryInline: InlineMetricView(metric: entry.primary)
        #endif
        @unknown default: small
        }
    }

    /// Accessory families have no room for a call to action and no button
    /// support, so they state the problem in the space they have.
    @ViewBuilder
    private var noData: some View {
        switch family {
        #if os(iOS)
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
        #endif
        default:
            NoDataView(
                message: entry.isEmptyProject
                    ? "No metrics cached yet. Open a dashboard in GetHog."
                    // Cause-aware: on a Mac build with no App Group, opening the
                    // app cannot fill this widget, so the words must not say it
                    // will. Unchanged on iOS. See `WidgetCache.noDataMessage`.
                    : WidgetCache.noDataMessage
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

    // Compiled only where the surface exists. `rectangular`, `circular` and
    // `accessoryLabel` are reachable only from the accessory arms above, and
    // those cases cannot be named on macOS at all — leaving the views behind
    // would be dead code the compiler is entitled to warn about.
    #if os(iOS)

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

    #endif
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

#if os(iOS)
#Preview("Rectangular", as: .accessoryRectangular) {
    MetricWidget()
} timeline: {
    MetricEntry.sample()
}
#endif
