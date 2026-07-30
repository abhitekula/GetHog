import GetHogKit
import SwiftUI

/// What the iPad detail pane shows before a flag is picked.
///
/// Replaces `ContentUnavailableView("Select a flag")`, which held two thirds of
/// an 11-inch canvas — the largest surface in the app spent on a sentence.
///
/// **Cost:** nothing. The flags endpoint returns the whole set in one page, so
/// unlike the paged screens every figure here is a true project total, and all
/// of it is already in memory. The rate-limit budget is organisation-wide; a
/// summary nobody asked for must not spend a request of it.
///
/// It reads groups through the store rather than off `FeatureFlag.active`, so an
/// optimistic toggle made in the detail pane is reflected here immediately
/// instead of the two panes disagreeing until the next load.
struct FlagsOverview: View {
    let store: FlagsStore
    @Binding var selection: FeatureFlag?

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            header
            statusSection
            rolloutSection
            multivariateSection
            FreshnessLabel(date: store.loadedAt)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Feature flags", systemImage: "flag")

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip {
                MetricTile(label: "Flags", value: "\(store.flags.count)", compact: true)
                MetricTile(label: "Enabled", value: "\(count(of: .enabled))", compact: true)
                if !multivariate.isEmpty {
                    MetricTile(
                        label: "Multivariate",
                        value: "\(multivariate.count)",
                        compact: true
                    )
                }
            }
            .padding(.horizontal, -Theme.Space.l)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "By status", systemImage: "circle.lefthalf.filled")

            Card {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    ForEach(FlagStatusGroup.allCases) { group in
                        // The word is carried by the pill, never the tint alone
                        // — disabled and archived share a colour on purpose, and
                        // only the label separates them.
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            StatusPill(text: group.title, tint: group.tint)
                            Text("\(count(of: group))")
                                .font(Theme.Typography.metricSmall)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(count(of: group)) \(group.title.lowercased())")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rolloutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Mid-rollout", systemImage: "dial.medium")

            if partialRollouts.isEmpty {
                // Said as a fact rather than left as a gap: "no flag is
                // half-released" and "we did not check" look identical when the
                // section simply disappears.
                Card {
                    Label(
                        count(of: .enabled) == 0
                            ? "No flag is enabled, so nothing is rolling out."
                            : "Every enabled flag is released to everyone it targets.",
                        systemImage: "checkmark.circle"
                    )
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("Enabled, but not released to everyone yet. Lowest first.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: Theme.Space.s) {
                    ForEach(partialRollouts) { flag in
                        flagRow(
                            flag,
                            metric: FlagFormat.percent(flag.rolloutPercentage ?? 0),
                            spokenMetric: "\(FlagFormat.percent(flag.rolloutPercentage ?? 0)) rollout"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var multivariateSection: some View {
        if !multivariate.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Multivariate", systemImage: "arrow.triangle.branch")

                Text("These serve a variant, not an on/off answer.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: Theme.Space.s) {
                    ForEach(multivariate) { flag in
                        flagRow(
                            flag,
                            metric: "\(flag.variants.count)",
                            spokenMetric: "\(flag.variants.count) variants"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func flagRow(
        _ flag: FeatureFlag,
        metric: String,
        spokenMetric: String
    ) -> some View {
        let group = store.group(for: flag)
        return Button {
            selection = flag
        } label: {
            Card(padding: Theme.Space.m) {
                DataRow(
                    glyph: flag.isMultivariate ? "arrow.triangle.branch" : "flag.fill",
                    tint: flag.isMultivariate ? Theme.accentWarm : Theme.accent,
                    title: flag.displayName,
                    // The key is what a developer copies verbatim, so it takes
                    // the monospaced line — unless it is already the title.
                    subtitle: flag.displayName == flag.key ? nil : flag.key,
                    footnote: group.title,
                    isSubtitleMonospaced: true,
                    accessory: .metric(metric)
                )
            }
        }
        .buttonStyle(.plain)
        .pointerHighlight(cornerRadius: Theme.Radius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(flag.key), \(group.title), \(spokenMetric)")
    }

    // MARK: - Data

    private func count(of group: FlagStatusGroup) -> Int {
        store.flags.filter { store.group(for: $0) == group }.count
    }

    /// Enabled flags whose highest release condition is below 100%.
    ///
    /// Archived flags are excluded even when they carry a percentage: an
    /// archived flag is not something anyone is currently rolling out.
    private var partialRollouts: [FeatureFlag] {
        Array(
            store.flags
                .filter { store.group(for: $0) == .enabled }
                .filter { ($0.rolloutPercentage ?? 100) < 100 }
                .sorted { ($0.rolloutPercentage ?? 0) < ($1.rolloutPercentage ?? 0) }
                .prefix(6)
        )
    }

    private var multivariate: [FeatureFlag] {
        Array(store.flags.filter { $0.isMultivariate && !$0.archived }.prefix(5))
    }
}
