import GetHogKit
import GetHogUI
import SwiftUI
import WidgetKit

// The one widget in this bundle that answers a question rather than reporting a
// number: *is my data still arriving?*
//
// It exists because that question is the reason somebody checks an analytics
// tool from a queue or a car, and because neither of the answers is visible
// anywhere else on a phone's Home Screen. It reads the same `SharedSnapshot`
// every other surface here reads — no network, ever — and it says how old that
// answer is on every family, because the snapshot may be hours old and a health
// verdict that hides its age is worse than none.

// MARK: - Timeline

struct HealthEntry: TimelineEntry {
    let date: Date
    let projectName: String
    /// `nil` until the app has written its first snapshot.
    let snapshot: SharedSnapshot?

    var freshness: WidgetFreshness { WidgetFreshness(capturedAt: snapshot?.capturedAt, now: date) }
    var verdict: SharedSnapshot.HealthVerdict { snapshot?.healthVerdict ?? .unchecked }
    var headline: String { snapshot?.healthHeadline ?? "Not synced yet" }
    /// The unsynced fallback is cause-aware: see `WidgetCache.noDataMessage`.
    /// Byte-identical on iOS, honest on a Mac build with no App Group.
    var detail: String { snapshot?.healthDetail ?? WidgetCache.noDataMessage }

    /// What this entry claims in a Smart Stack.
    ///
    /// This is the widget the rotation exists for: a card that spends most of its
    /// life saying "nothing to report" is exactly the card you want promoted on
    /// the morning a quota blocks or an ingestion error starts, and buried on
    /// every other morning. `SnapshotRelevance.health` returns a hard zero for
    /// both `.clear` and `.unchecked` for that reason, so the promotion is spent
    /// on a finding rather than on this widget's existence.
    ///
    /// A `duration` of one timeline step rather than the default. The default —
    /// zero — means "valid until the next entry", and the *last* entry in a
    /// timeline has no next entry: if WidgetKit is late calling the provider back,
    /// a stale alarm would keep its rank indefinitely. Expiring with the step
    /// makes a claim lapse into silence rather than into a lie.
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(
            score: SnapshotRelevance.health(snapshot, now: date),
            duration: WidgetRefresh.step
        )
    }

    /// Verdict, fact, scope and age, in that order — the same order the visual
    /// hierarchy puts them in, so VoiceOver and sight agree.
    var spokenLabel: String {
        guard let snapshot else { return "GetHog project health, not synced yet" }
        return "\(snapshot.projectName). \(snapshot.healthSpokenLabel) \(freshness.spokenLabel)."
    }

    static func sample(at date: Date = Date()) -> HealthEntry {
        HealthEntry(date: date, projectName: WidgetCache.sample.projectName, snapshot: WidgetCache.sample)
    }

    static func empty(at date: Date = Date()) -> HealthEntry {
        HealthEntry(date: date, projectName: "GetHog", snapshot: nil)
    }
}

/// No configuration: there is nothing to choose. The project is whichever one
/// the app is looking at, and the checks are not opt-out — a health widget that
/// let you hide the failing half would be a worse lie than showing nothing.
struct HealthProvider: TimelineProvider {

    func placeholder(in context: Context) -> HealthEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        completion(context.isPreview ? .sample() : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        let now = Date()
        // One read, many entries: the values never change across a timeline, only
        // the dates do, which is what keeps "Updated 40m ago" honest without
        // waking the provider again. See `WidgetRefresh`.
        let snapshot = WidgetCache.snapshot()
        completion(WidgetRefresh.timeline(from: now) { date in entry(at: date, snapshot: snapshot) })
    }

    private func entry(at date: Date, snapshot: SharedSnapshot? = WidgetCache.snapshot()) -> HealthEntry {
        guard let snapshot else { return .empty(at: date) }
        return HealthEntry(date: date, projectName: snapshot.projectName, snapshot: snapshot)
    }
}

// MARK: - Widget

struct HealthWidget: Widget {

    static let kind = "app.gethog.widget.health"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HealthProvider()) { entry in
            HealthWidgetView(entry: entry)
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("Project Health")
        .description("Ingestion warnings and quota from your last sync. GetHog refreshes it — the widget never calls the API itself.")
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

struct HealthWidgetView: View {

    let entry: HealthEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
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
        case .accessoryInline: inline
        #endif
        @unknown default: small
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            VerdictBadge(verdict: entry.verdict)
            Text(entry.headline)
                .font(.system(.headline, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.6)
            Text(entry.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            FreshnessFooter(freshness: entry.freshness)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spokenLabel)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VerdictBadge(verdict: entry.verdict)
                Text(entry.headline)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.verdict.title). \(entry.headline)")

            IngestionRow(digest: entry.snapshot?.ingestion, snapshot: entry.snapshot, now: entry.date)
            QuotaRow(digest: entry.snapshot?.quota, snapshot: entry.snapshot, now: entry.date)

            Spacer(minLength: 0)
            FreshnessFooter(freshness: entry.freshness)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.projectName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .top, spacing: 8) {
                VerdictBadge(verdict: entry.verdict)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.headline)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(entry.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.verdict.title). \(entry.headline). \(entry.detail)")

            Divider()
            IngestionRow(
                digest: entry.snapshot?.ingestion, snapshot: entry.snapshot, now: entry.date,
                showsTrend: true
            )
            Divider()
            QuotaRow(digest: entry.snapshot?.quota, snapshot: entry.snapshot, now: entry.date, expanded: true)

            Spacer(minLength: 0)
            FreshnessFooter(freshness: entry.freshness)
        }
    }

    // MARK: Lock Screen

    // Compiled only where the surface exists: the accessory cases above cannot
    // be named on macOS, so these views would be unreachable there.
    #if os(iOS)

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Project health", systemImage: entry.verdict.symbolName)
                .font(.caption2)
                .lineLimit(1)
                // Accented rendering splits the view in two layers; the label
                // and its glyph are the half worth tinting.
                .widgetAccentable()
            Text(entry.headline)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(entry.detail) · \(entry.freshness.shortLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spokenLabel)
    }

    /// The smallest surface in the app, so it carries the two things that fit:
    /// what kind of problem, and how many. Never a bare colour.
    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: entry.verdict.symbolName)
                .font(.caption2)
            Text(circularCount)
                .font(.system(.headline, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spokenLabel)
    }

    /// The count of things asking for attention, or a dash when the honest answer
    /// is "none" — a "0" beside a warning glyph reads as a failed render.
    private var circularCount: String {
        guard let snapshot = entry.snapshot else { return "–" }
        let blocked = snapshot.quota?.blockedCount ?? 0
        let ingestion = snapshot.ingestion.map { $0.errorCount + $0.warningCount + $0.unratedCount } ?? 0
        let total = blocked + ingestion
        return total > 0 ? String(total) : "–"
    }

    private var inline: some View {
        Label {
            Text("\(entry.headline) · \(entry.freshness.shortLabel)")
        } icon: {
            Image(systemName: entry.verdict.symbolName)
        }
        .accessibilityLabel(entry.spokenLabel)
    }

    #endif
}

// MARK: - Building blocks

/// Glyph, word and tint together. The word is what survives greyscale.
struct VerdictBadge: View {
    let verdict: SharedSnapshot.HealthVerdict

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Label(verdict.title, systemImage: verdict.symbolName)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(
                renderingMode == .fullColor
                    ? AnyShapeStyle(WidgetPalette.tint(for: verdict))
                    : AnyShapeStyle(.primary)
            )
            .accessibilityHidden(true)
    }
}

/// One ingestion line: what the worst warning is, how loud it is, and — when
/// there is room — the server's own trend for it.
struct IngestionRow: View {
    let digest: SharedSnapshot.IngestionDigest?
    let snapshot: SharedSnapshot?
    let now: Date
    var showsTrend = false

    var body: some View {
        HealthSection(
            title: "Ingestion",
            symbol: "arrow.down.to.line",
            carriedForwardAge: carriedForwardAge
        ) {
            if let digest {
                if digest.typeCount == 0 {
                    // A project with clean ingestion is the commonest case and
                    // the one an empty rectangle would misrepresent as a bug.
                    Text("No warnings in \(digest.windowTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(digest.topTitle ?? "Warnings")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(summary(digest))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if showsTrend, digest.hasTrend {
                        Sparkline(points: digest.topSparkline).frame(height: 22)
                    }
                }
            } else {
                Text("Not checked in this sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func summary(_ digest: SharedSnapshot.IngestionDigest) -> String {
        var parts = ["\(WidgetNumber.compact(Double(digest.affectedEvents))) events"]
        if digest.typeCount > 1 { parts.append("\(digest.typeCount) types") }
        if let severity = digest.topSeverity { parts.append(severity.title.lowercased()) }
        return parts.joined(separator: " · ")
    }

    private var carriedForwardAge: WidgetFreshness? {
        guard let digest, let snapshot, snapshot.isCarriedForward(digest.capturedAt) else { return nil }
        return WidgetFreshness(capturedAt: digest.capturedAt, now: now)
    }

    private var accessibilityLabel: String {
        guard let digest else { return "Ingestion, not checked in this sync" }
        guard digest.typeCount > 0 else { return "Ingestion, no warnings in \(digest.windowTitle)" }
        let severity = digest.topSeverity?.title ?? "unrated"
        var label = "Ingestion, \(digest.typeCount) warning types, worst is \(digest.topTitle ?? "unnamed"), "
            + "severity \(severity), \(digest.affectedEvents) events affected in \(digest.windowTitle)"
        if let carriedForwardAge { label += ", \(carriedForwardAge.spokenLabel)" }
        return label
    }
}

/// One quota line: which allowance is closest to running out, and how close.
struct QuotaRow: View {
    let digest: SharedSnapshot.QuotaDigest?
    let snapshot: SharedSnapshot?
    let now: Date
    var expanded = false

    var body: some View {
        HealthSection(title: "Quota", symbol: "gauge.with.dots.needle.33percent", carriedForwardAge: carriedForwardAge) {
            if let digest {
                if let title = digest.topTitle {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let fraction = digest.topFraction {
                        QuotaBar(fraction: fraction)
                    }
                    Text(usage(digest))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if expanded, digest.resourceCount > 1 {
                        Text("\(digest.resourceCount) metered resources · \(digest.pressingCount) pressing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    Text("No metered resources reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text("Not checked in this sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// `3,000 of 4,500 · Watch`, or the no-limit form.
    ///
    /// Never "3,000 of 0": a missing limit is not a limit of zero, and rendering
    /// one claims an overage PostHog never reported.
    private func usage(_ digest: SharedSnapshot.QuotaDigest) -> String {
        let state = digest.topState?.title
        guard let usage = digest.topUsage else { return state ?? "" }
        guard let limit = digest.topLimit else {
            return [WidgetNumber.compact(usage) + " used", "no limit reported"].joined(separator: " · ")
        }
        let numbers = "\(WidgetNumber.compact(usage)) of \(WidgetNumber.compact(limit))"
        // The state is always spelled out beside the bar: fill height and tint
        // are the two encodings a greyscale or colour-blind reader cannot use.
        return state.map { "\(numbers) · \($0)" } ?? numbers
    }

    private var carriedForwardAge: WidgetFreshness? {
        guard let digest, let snapshot, snapshot.isCarriedForward(digest.capturedAt) else { return nil }
        return WidgetFreshness(capturedAt: digest.capturedAt, now: now)
    }

    private var accessibilityLabel: String {
        guard let digest else { return "Quota, not checked in this sync" }
        guard let title = digest.topTitle else { return "Quota, no metered resources reported" }
        var label = "Quota, \(title), \(usage(digest))"
        if digest.blockedCount > 0 { label += ", \(digest.blockedCount) resources already at their limit" }
        if let carriedForwardAge { label += ", \(carriedForwardAge.spokenLabel)" }
        return label
    }
}

/// A labelled block with an optional "this part is older than the rest" note.
struct HealthSection<Content: View>: View {
    let title: String
    let symbol: String
    /// Non-nil only when this section was carried forward from an earlier
    /// refresh, which is the ordinary state of quota.
    var carriedForwardAge: WidgetFreshness?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let relativeCaption = carriedForwardAge?.relativeCaption {
                    // The footer's age belongs to the metrics. This section was
                    // fetched on a slower clock, so it states its own rather
                    // than letting the footer speak for it.
                    Text("· as of \(relativeCaption)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Share of an allowance consumed. Always beside a number and a state word.
struct QuotaBar: View {
    let fraction: Double

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(shade)
                    // Clamped for drawing only: an overage stays visible in the
                    // numbers beside it rather than running off the end of a bar.
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
        // Clipped to the track. A `Capsule` rounds by half its smaller side, so
        // any fraction narrow enough to make the fill under 5pt wide — a few per
        // cent of an allowance, which is the ordinary state of a fresh quota —
        // gives the fill a tighter cap than the track and it paints past the
        // track's leading end. Measured at 8× on the same geometry: 1.5pt out.
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }

    private var shade: Color {
        renderingMode == .fullColor ? WidgetPalette.accent : .primary
    }
}

#Preview("Small", as: .systemSmall) {
    HealthWidget()
} timeline: {
    HealthEntry.sample()
    HealthEntry.empty()
}

#Preview("Medium", as: .systemMedium) {
    HealthWidget()
} timeline: {
    HealthEntry.sample()
}

#Preview("Large", as: .systemLarge) {
    HealthWidget()
} timeline: {
    HealthEntry.sample()
}

#if os(iOS)
#Preview("Rectangular", as: .accessoryRectangular) {
    HealthWidget()
} timeline: {
    HealthEntry.sample()
}
#endif
