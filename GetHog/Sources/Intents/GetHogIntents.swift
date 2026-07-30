import AppIntents
import Foundation
import GetHogKit
import SwiftUI

// MARK: - Open a dashboard

struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Dashboard"
    static let description = IntentDescription(
        "Opens one of your PostHog dashboards in GetHog.",
        categoryName: "Dashboards"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Dashboard")
    var dashboard: DashboardEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$dashboard)")
    }

    init() {}

    init(dashboard: DashboardEntity) {
        self.dashboard = dashboard
    }

    func perform() async throws -> some IntentResult {
        // The intent can't push a view itself, so it leaves the destination for
        // the app to pick up as it comes to the foreground.
        IntentNavigationTarget.request(.dashboard(id: dashboard.id))
        return .result()
    }
}

// MARK: - Read a metric

struct GetMetricValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Metric Value"
    static let description = IntentDescription(
        "Reads the current value of a PostHog insight and shows it as a chart.",
        categoryName: "Insights"
    )

    @Parameter(title: "Insight")
    var insight: InsightEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the value of \(\.$insight)")
    }

    init() {}

    init(insight: InsightEntity) {
        self.insight = insight
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let deps = try await IntentDependencies.resolve()
        let metric = try await Self.metric(for: insight, deps: deps)

        return .result(
            dialog: IntentDialog("\(metric.title) is \(metric.spokenValue)."),
            view: MetricSnippetView(metric: metric)
        )
    }

    private static func metric(
        for insight: InsightEntity,
        deps: IntentDependencies
    ) async throws -> IntentMetric {
        // Cached first: recomputation is charged against an organisation-wide
        // budget shared with the user's other integrations, and "what is it now"
        // is answered well enough by PostHog's own cache.
        let cached: Insight
        do {
            cached = try await deps.client.send(
                PostHogAPI.insight(projectID: deps.projectID, insightID: insight.id)
            )
        } catch {
            throw IntentError.from(error, action: "read \(insight.name)")
        }

        if let metric = IntentMetric(insight: cached, fallbackTitle: insight.name) {
            return metric
        }

        // Cold cache. One escalation to a real computation, then an honest
        // answer — never a silent zero.
        let refreshed: Insight
        do {
            refreshed = try await deps.client.send(
                PostHogAPI.insight(projectID: deps.projectID, insightID: insight.id, refresh: true)
            )
        } catch {
            throw IntentError.from(error, action: "read \(insight.name)")
        }

        if let metric = IntentMetric(insight: refreshed, fallbackTitle: insight.name) {
            return metric
        }
        if case .unsupported(let kind) = refreshed.renderModel {
            throw IntentError.unsupportedInsight(
                name: insight.name,
                kind: InsightEntity.readableKind(kind)
            )
        }
        throw IntentError.failed(
            action: "read \(insight.name)",
            detail: "PostHog hasn't computed it recently. Open it in GetHog to refresh."
        )
    }
}

// MARK: - Flip a feature flag

struct SetFeatureFlagIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Feature Flag"
    static let description = IntentDescription(
        "Enables or disables a PostHog feature flag you have opted in to quick toggling.",
        categoryName: "Feature Flags"
    )

    /// Biometrics can only be evaluated with a foreground UI, and `LAContext` is
    /// not `Sendable` — it can't be handed to whatever process the system picked
    /// to run this. So when the user has asked for the extra check, the intent
    /// opens the app and the check happens there. Silently skipping it would
    /// turn a security setting into decoration.
    static var openAppWhenRun: Bool { BiometricGate.isEnabled }

    @Parameter(title: "Feature Flag")
    var flag: FeatureFlagEntity

    @Parameter(title: "Enabled")
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$flag) to \(\.$enabled)")
    }

    init() {}

    init(flag: FeatureFlagEntity, enabled: Bool) {
        self.flag = flag
        self.enabled = enabled
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let verb = enabled ? "enable" : "disable"

        // The quick-toggle gate. Opting a flag in is a decision that can only be
        // made in the app, where its rollout conditions are visible; out here
        // there is nothing to read and no dialog to confirm against. So a flag
        // that hasn't been opted in is refused, not flipped.
        guard FlagQuickToggle.isAllowed(flagID: flag.id) else {
            return .result(dialog: IntentDialog(
                "\(flag.key) isn't set up for quick toggling. Open GetHog, find the flag, and turn on “Allow quick toggle” to change it from here."
            ))
        }

        var notice = ""
        if BiometricGate.isEnabled {
            // `openAppWhenRun` is true in this configuration, so this runs
            // foregrounded. The context is created, used and discarded inside
            // `BiometricGate` and never crosses an isolation boundary.
            switch await BiometricGate.evaluate() {
            case .passed:
                break
            case .unavailable(let detail):
                // Mirrors the in-app behaviour: proceed, but say the gate
                // didn't actually run rather than implying it passed.
                notice = " Device authentication wasn't available (\(detail))."
            case .denied(let detail):
                throw IntentError.authenticationDenied(flagKey: flag.key, detail: detail)
            }
        }

        let deps = try await IntentDependencies.resolve()
        do {
            _ = try await deps.client.data(
                for: PostHogAPI.setFlagActive(
                    projectID: deps.projectID,
                    flagID: flag.id,
                    active: enabled
                )
            )
        } catch {
            throw IntentError.from(
                error,
                action: "\(verb) \(flag.key)",
                writeScope: "feature_flag:write"
            )
        }

        return .result(dialog: IntentDialog(
            "\(flag.key) is now \(enabled ? "enabled" : "disabled").\(notice)"
        ))
    }
}

// MARK: - Search recent events

struct SearchEventsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Recent Events"
    static let description = IntentDescription(
        "Finds recent PostHog events matching a term.",
        categoryName: "Events"
    )

    @Parameter(title: "Search Term", requestValueDialog: "What should I look for?")
    var term: String

    @Parameter(title: "Number of Events", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$limit) recent events matching \(\.$term)")
    }

    init() {}

    init(term: String, limit: Int = 10) {
        self.term = term
        self.limit = limit
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let deps = try await IntentDependencies.resolve()

        let response: QueryResponse
        do {
            response = try await deps.client.send(
                PostHogAPI.events(
                    projectID: deps.projectID,
                    limit: limit,
                    // Bounded like the feed's own first page. Unbounded, this
                    // query ran a median 8.53s and failed 4 runs in 5 — and a
                    // Siri intent has less patience for that than a screen does.
                    since: EventFeedPager().floor(now: Date()),
                    search: needle
                )
            )
        } catch {
            throw IntentError.from(error, action: "search events for “\(needle)”")
        }

        let rows = response.rows.compactMap(EventRow.init(row:))
        // Says "in the last week" because that is what was searched. A bare
        // "no recent events" would imply a search this never made.
        let dialog: IntentDialog = rows.isEmpty
            ? IntentDialog("No events in the last week match “\(needle)”.")
            : IntentDialog("Found \(rows.count) event\(rows.count == 1 ? "" : "s") in the last week matching “\(needle)”.")

        return .result(
            dialog: dialog,
            view: EventsSnippetView(term: needle, rows: rows)
        )
    }
}

// MARK: - Metric model

/// A single insight reduced to what a snippet and a spoken answer need.
///
/// The reduction lives here rather than in the view so the same rules apply to
/// what Siri says and what the snippet draws — they must never disagree.
struct IntentMetric: Sendable {
    let title: String
    /// Compact form for the snippet's headline ("12.4K").
    let displayValue: String
    /// Long form for speech — Siri saying "twelve point four K" is not an answer.
    let spokenValue: String
    let caption: String?
    /// Empty unless the insight is a time series worth drawing.
    let series: [Double]

    init?(insight: Insight, fallbackTitle: String) {
        let title = insight.title == "Untitled" ? fallbackTitle : insight.title

        switch insight.renderModel {
        case .bigNumber(let number):
            self.init(
                title: title,
                value: number.value,
                caption: number.label.isEmpty ? nil : number.label,
                series: []
            )

        case .timeSeries(let series, _):
            guard let primary = series.first, !primary.points.isEmpty else { return nil }
            self.init(
                title: title,
                value: primary.total,
                caption: primary.label.isEmpty ? nil : primary.label,
                series: primary.points.map(\.value)
            )

        case .barValue(let bars):
            guard let top = bars.max(by: { $0.value < $1.value }) else { return nil }
            self.init(
                title: title,
                value: top.value,
                caption: top.label.isEmpty ? nil : "Top: \(top.label)",
                series: []
            )

        case .funnel(let groups):
            guard let group = groups.first, let first = group.steps.first,
                  let last = group.steps.last, first.count > 0
            else { return nil }
            self.init(
                title: title,
                percent: group.conversionRate,
                caption: "\(first.name) → \(last.name)"
            )

        case .lifecycle(let series):
            guard let new = series.first(where: { $0.status == .new }) ?? series.first,
                  !new.points.isEmpty
            else { return nil }
            self.init(
                title: title,
                value: new.total,
                caption: "\(new.status.title) users",
                series: new.points.map(\.value)
            )

        case .retention(let grid):
            guard let cohort = grid.cohorts.first, grid.intervalCount > 1 else { return nil }
            self.init(
                title: title,
                percent: cohort.rate(at: 1),
                caption: "Retained after 1 interval · \(cohort.label)"
            )

        case .stickiness(let series):
            guard let primary = series.first, !primary.buckets.isEmpty else { return nil }
            // The buckets are a distribution over interval counts, not a time
            // series, but the shape still reads correctly as a sparkline.
            self.init(
                title: title,
                value: primary.total,
                caption: primary.label.isEmpty ? "Users by active intervals" : primary.label,
                series: primary.buckets.map(\.count)
            )

        case .paths(let graph):
            guard let busiest = graph.edges.first else { return nil }
            self.init(
                title: title,
                value: busiest.value,
                caption: "Busiest path: \(busiest.source) → \(busiest.target)",
                series: []
            )

        case .unsupported:
            return nil
        }
    }

    private init(title: String, value: Double, caption: String?, series: [Double]) {
        self.title = title
        self.displayValue = IntentValueFormat.compact(value)
        self.spokenValue = IntentValueFormat.spoken(value)
        self.caption = caption
        self.series = series.count > 1 ? series : []
    }

    private init(title: String, percent: Double, caption: String?) {
        self.title = title
        self.displayValue = IntentValueFormat.percent(percent)
        self.spokenValue = IntentValueFormat.percent(percent)
        self.caption = caption
        self.series = []
    }
}

/// Number formatting for intent surfaces.
///
/// Deliberately local rather than reusing the app's `Double.compactFormatted`:
/// these files are the extension-facing contract and must not reach into the
/// app's view layer to render a number.
enum IntentValueFormat {
    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func spoken(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

// MARK: - Snippet views

/// The app accent, restated.
///
/// **Keep in sync with `Theme.accent` by hand.** This is not preference: this
/// whole directory is compiled into `GetHogWidgets` as well as the app (see
/// `project.yml`), and that extension target's sources are only `GetHogWidgets`,
/// `GetHog/Sources/Intents` and `FlagToggleController.swift` — it does not
/// include `GetHog/Sources/Common`, so `Theme` does not exist here and naming
/// it breaks the extension build, which breaks the app bundle with it.
///
/// The values are `Theme.accent`'s, resolved the same way so light and dark
/// still come free.
private enum SnippetStyle {
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.243, green: 0.773, blue: 0.808, alpha: 1)  // #3EC5CE
            : UIColor(red: 0.043, green: 0.431, blue: 0.459, alpha: 1)  // #0B6E75
    })
}

struct MetricSnippetView: View {
    let metric: IntentMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(metric.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Semantic size, built the way `Theme.Typography.metric` is: snippets
            // honour Dynamic Type, and a fixed 48pt only ever shrank — a reader
            // at an accessibility size got the caption above it scaled up and the
            // number itself left behind.
            Text(metric.displayValue)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if let caption = metric.caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !metric.series.isEmpty {
                IntentSparkline(values: metric.series)
                    .stroke(SnippetStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .bottom) {
                        IntentSparkline(values: metric.series, closed: true)
                            .fill(SnippetStyle.accent.opacity(0.15))
                    }
                    // A sparkline is decoration on top of the number that is
                    // already spoken; VoiceOver gets the summary, not the shape.
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title): \(metric.spokenValue)")
    }
}

struct EventsSnippetView: View {
    let term: String
    let rows: [EventRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Events matching “\(term)”")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if rows.isEmpty {
                Text("Nothing in the last events for this project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Snippets are small; show the freshest handful and say so
                // rather than clipping an unbounded list.
                ForEach(rows.prefix(6)) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.event)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let timestamp = row.timestamp {
                            Text(timestamp, format: .relative(presentation: .numeric))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                if rows.count > 6 {
                    Text("+\(rows.count - 6) more in GetHog")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal line chart for a snippet. Hand-drawn rather than a `Chart`, because
/// a snippet has no axes, no legend and no interaction — everything a chart
/// library would bring costs layout it can't use.
private struct IntentSparkline: Shape {
    let values: [Double]
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }

        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 0
        let span = maximum - minimum
        let step = rect.width / CGFloat(values.count - 1)

        func point(_ index: Int) -> CGPoint {
            // A flat series draws along the middle rather than collapsing onto
            // the baseline, which would read as "zero".
            let normalized = span > 0 ? (values[index] - minimum) / span : 0.5
            return CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - CGFloat(normalized) * rect.height
            )
        }

        path.move(to: point(0))
        for index in 1..<values.count {
            path.addLine(to: point(index))
        }

        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
