import GetHogKit
import SwiftUI

// MARK: - Quota and spend

/// What the project is consuming, and what it is being charged for.
///
/// The question this answers is "are we about to blow the quota", asked away
/// from a desk. Quota payloads can contain many mostly quiet resources, so an
/// alphabetical table makes the answer harder to find. The card leads with the one
/// resource nearest its limit and files the rest behind a disclosure, which is
/// where `QuotaLimits` already splits them.
///
/// Spend shares the card rather than getting its own because it is the same
/// story from the other side: quota is what has been used, spend is what it
/// cost. Two cards would put a fact and its price tag in different places.
struct QuotaSpendCard: View {
    @Environment(AppModel.self) private var model
    let store: QuotaStore

    /// Only what is pressing plus the leader; the rest are behind the disclosure.
    ///
    /// Uncapped on purpose. Capping at three would push a fourth pressed
    /// resource into the group the card labels "none near a limit", and a
    /// disclosure that lies about its contents is worse than a long card.
    private var featured: [QuotaResource] {
        guard let quota = store.quota else { return [] }
        if !quota.pressing.isEmpty { return quota.pressing }
        // Nothing is close. Showing the closest anyway beats an empty card that
        // reads as a failed load — and it is still the honest answer to the
        // question, which was "how close are we", not "what is broken".
        return quota.headline.map { [$0] } ?? []
    }

    private var quiet: [QuotaResource] {
        guard let quota = store.quota else { return [] }
        return quota.resources.filter { resource in
            !featured.contains { $0.key == resource.key }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            summaryStrip

            if let failure = store.quotaFailure {
                SectionEmptyState(
                    text: failure.summary,
                    systemImage: "lock",
                    detail: failure.detail,
                    actionTitle: "Try again"
                ) {
                    Task { await store.reload(client: model.client, projectID: model.projectID) }
                }
                .padding(.horizontal, Theme.Space.l)
            } else {
                quotaRows
            }

            spendBreakdown

            FreshnessLabel(date: store.loadedAt)
                .padding(.horizontal, Theme.Space.l)
        }
        .padding(.vertical, Theme.Space.s)
        .skeleton(store.isLoading && store.quota == nil && store.spend == nil)
        // On the *row*, not on the screen. `List` realises rows lazily, so this
        // fires the first time the section is genuinely on screen — not every
        // time Settings is opened to switch project or read the API key. The
        // budget being spent is the organisation's, shared with the user's
        // production integrations, and these are two extra requests against it.
        .task { await store.loadIfNeeded(client: model.client, projectID: model.projectID) }
    }

    // MARK: Summary

    @ViewBuilder
    private var summaryStrip: some View {
        StatStrip {
            MetricTile(
                label: "Nearest limit",
                value: store.quota?.headline.map(Self.percentText) ?? "—",
                compact: true
            )
            MetricTile(
                label: spendLabel,
                value: store.spend?.formattedTotal() ?? (store.spendFailure == nil ? "—" : "Unavailable"),
                compact: true
            )
        }
    }

    /// The window is read off the response rather than assumed. The default is
    /// 30 days, but the label should not claim it if the server sent another.
    private var spendLabel: String {
        guard let spend = store.spend,
              let from = spend.dateFrom,
              let to = spend.dateTo
        else { return "AI spend" }
        let days = Int((to.timeIntervalSince(from) / 86_400).rounded())
        return days > 0 ? "AI spend · \(days)d" : "AI spend"
    }

    // MARK: Quota

    @ViewBuilder
    private var quotaRows: some View {
        if let quota = store.quota {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if quota.blockedCount > 0 {
                    Label(
                        "\(quota.blockedCount) resource\(quota.blockedCount == 1 ? " is" : "s are") at their limit. PostHog has stopped accepting them.",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(Theme.Status.criticalInk)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(featured) { QuotaMeter(resource: $0) }

                if !quiet.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(quiet) { resource in
                                DataRow(
                                    glyph: resource.limit == nil ? "infinity" : "gauge.with.dots.needle.33percent",
                                    tint: Theme.accent,
                                    title: resource.title,
                                    subtitle: resource.usageDescription(),
                                    accessory: .metric(Self.percentText(resource))
                                )
                            }
                        }
                    } label: {
                        Text(Self.quietLabel(count: quiet.count, hasFeatured: !featured.isEmpty))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .tint(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.Space.l)
        } else if !store.isLoading {
            SectionEmptyState(text: "No metered resources reported.", systemImage: "gauge")
                .padding(.horizontal, Theme.Space.l)
        }
    }

    /// The disclosure has to describe what is actually inside it.
    ///
    /// "17 more" is wrong when nothing was shown above it, and a project whose
    /// resources are all unmetered has nothing to be near a limit at all — so
    /// neither phrasing is safe to use unconditionally.
    static func quietLabel(count: Int, hasFeatured: Bool) -> String {
        guard hasFeatured else {
            return "\(count) resource\(count == 1 ? "" : "s"), none with a published limit"
        }
        return count == 1 ? "1 more, not near a limit" : "\(count) more, none near a limit"
    }

    /// `—` for an unmetered resource, never `0%`. There is no denominator, so
    /// any percentage would be invented.
    static func percentText(_ resource: QuotaResource) -> String {
        guard let fraction = resource.fraction else { return "—" }
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Spend

    @ViewBuilder
    private var spendBreakdown: some View {
        if let failure = store.spendFailure {
            SectionEmptyState(
                text: failure.summary,
                systemImage: "lock",
                detail: failure.detail,
                actionTitle: "Try again"
            ) {
                Task { await store.reload(client: model.client, projectID: model.projectID) }
            }
            .padding(.horizontal, Theme.Space.l)
        } else if let spend = store.spend, !spend.byProduct.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(text: "Where the AI spend went", systemImage: "dollarsign.circle")

                // Capped so an organisation billing across many products cannot
                // turn a Settings row into a page.
                ForEach(spend.byProduct.prefix(6)) { product in
                    DataRow(
                        glyph: "sparkles",
                        tint: Theme.accentWarm,
                        title: product.title,
                        subtitle: "\(product.eventCount.formatted()) events",
                        accessory: .metric(product.formattedCost())
                    )
                }

                // The server summary is authoritative and rows may differ in
                // scope or precision; the UI rounds both as currency instead of
                // recomputing the headline.
                Text("Costs are PostHog's, rounded to the cent for display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }
}

/// One resource's allowance, as a bar and as words.
///
/// The tint comes from `Theme.Status`, never from `SeriesPalette`. A usage bar
/// is arguably data and the palette is the app's data colour, so the choice is
/// real — but the palette's hues mean *which series*, so a legend can be matched
/// to a mark. There is one series here, and its colour means *how bad*. Handing
/// eighteen resources eighteen palette hues would claim they are comparable
/// series on one axis, which events, megabytes and credits are not, and would
/// leave no colour free to mean "you are about to be cut off". It also has to
/// agree with `RateLimitUsageView`, which sits directly beneath it: two
/// consumption meters that disagreed about what red means would be worse than
/// either alone.
///
/// Colour is never the only encoding. The percentage and the state word carry
/// the same fact in greyscale.
private struct QuotaMeter: View {
    let resource: QuotaResource

    private var tint: Color {
        switch resource.pressure {
        case .blocked, .critical: Theme.Status.critical
        case .watch: Theme.accentWarm
        case .clear: Theme.Status.good
        // No limit, so no verdict. The app's own chrome colour says "this is a
        // number, not a judgement".
        case .unmetered: Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: resource.title)
                Spacer(minLength: Theme.Space.s)
                Text(QuotaSpendCard.percentText(resource))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tint)
                StatusPill(text: resource.stateWord, tint: tint)
            }

            // Drawn only when there is a denominator. A bar for an unmetered
            // resource would have to pick between empty and full, and both are
            // claims the response never made.
            if let fraction = resource.fraction {
                ProgressView(value: min(fraction, 1))
                    .progressViewStyle(.linear)
                    .tint(tint)
            }

            Text(resource.usageDescription())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(resource.title) quota")
        .accessibilityValue(
            "\(QuotaSpendCard.percentText(resource)) used, \(resource.stateWord). \(resource.usageDescription())"
        )
    }
}

// MARK: - SDK health

/// PostHog's verdict on the project's SDK versions.
///
/// One card, not a table, because the endpoint is already the answer: PostHog
/// has applied its grace periods, minor-count thresholds, age rules and traffic
/// shares server-side and returns the judgement plus the sentence behind it.
/// Re-deriving any of that here would eventually disagree with the web console,
/// and the console is what the user checks next.
///
/// So the card's job is to relay, not to assess. The verdict is PostHog's word,
/// the count is PostHog's number, and the explanation is PostHog's prose,
/// verbatim.
struct SDKHealthCard: View {
    @Environment(AppModel.self) private var model
    let store: SDKHealthStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let failure = store.failure {
                SectionEmptyState(
                    text: failure.summary,
                    systemImage: "lock",
                    detail: failure.detail,
                    actionTitle: "Try again"
                ) {
                    Task { await store.reload(client: model.client, projectID: model.projectID) }
                }
            } else if let report = store.report {
                verdictRow(report)
                ForEach(report.flagged) { SDKHealthRow(entry: $0) }
                if report.flagged.isEmpty {
                    Text("Nothing is flagged. PostHog re-runs this check roughly daily, so a version you have just deployed can take a day to clear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !store.isLoading {
                SectionEmptyState(text: "PostHog hasn't reported on this project's SDKs.", systemImage: "shippingbox")
            }

            FreshnessLabel(date: store.loadedAt)
        }
        .padding(.vertical, Theme.Space.xs)
        .skeleton(store.isLoading && store.report == nil)
        // Same rule as the quota card: on the row, so the request is made when
        // the section is genuinely shown rather than on every Settings visit.
        .task { await store.loadIfNeeded(client: model.client, projectID: model.projectID) }
    }

    private func verdictRow(_ report: SDKHealthReport) -> some View {
        // The level is stated three ways — glyph, colour, word — so severity
        // never rests on hue. `Theme.Status` because this is chrome carrying a
        // judgement, the same reason the quota bars use it.
        let tint = Self.tint(for: report.level)

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                RowGlyph(systemName: report.level.symbolName, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.verdict.title)
                        .font(Theme.Typography.title)
                    Text(Self.updatingText(report.needsUpdatingCount))
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Theme.Space.s)
                StatusPill(text: report.level.title, tint: tint)
            }

            if let reason = report.reason, !reason.isEmpty {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// PostHog's count, phrased. Not `flagged.count` — if the two ever disagree,
    /// the server's number is the one the console shows.
    private static func updatingText(_ count: Int) -> String {
        switch count {
        case 0: "No SDKs need updating"
        case 1: "1 SDK needs updating"
        default: "\(count) SDKs need updating"
        }
    }

    static func tint(for level: SDKHealthLevel) -> Color {
        switch level {
        case .healthy: Theme.Status.good
        case .info: .secondary
        case .warning: Theme.accentWarm
        case .danger, .critical: Theme.Status.critical
        // Concerning, but not quantified — the warm secondary says "look at
        // this" without claiming a band PostHog never named.
        case .unknown: Theme.accentWarm
        }
    }
}

/// One flagged SDK, in PostHog's own words.
private struct SDKHealthRow: View {
    let entry: SDKHealthEntry

    private var versions: String? {
        guard let current = entry.currentVersion, let latest = entry.latestVersion else { return nil }
        return "\(current) → \(latest)"
    }

    var body: some View {
        let tint = SDKHealthCard.tint(for: entry.severity)

        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: entry.severity.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .font(Theme.Typography.title)
                Spacer(minLength: Theme.Space.s)
                StatusPill(text: entry.severity.title, tint: tint)
            }

            if let versions {
                Text(versions)
                    .font(Theme.Typography.body.monospaced())
                    .foregroundStyle(.secondary)
            }

            // Verbatim. PostHog wrote the sentence that explains why this row
            // exists; paraphrasing it would put a second, quieter judgement on
            // screen beside the one the console shows.
            if let reason = entry.reason, !reason.isEmpty {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // Absent on a healthy SDK, and often absent on a flagged one. An
            // empty array must render nothing rather than an unexplained gap.
            ForEach(entry.banners, id: \.self) { banner in
                Label(banner, systemImage: "megaphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        // Nothing here is prose: SDK names and semver strings pick up invented
        // hyphens if they are typeset as language. Same reason as `DataRow`.
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
    }
}
