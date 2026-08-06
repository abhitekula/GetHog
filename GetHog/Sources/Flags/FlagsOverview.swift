import GetHogKit
import GetHogUI
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
    /// The open flag's id, so a reload that replaces the decoded rows leaves
    /// the selection standing. Matches `FlagsRoot.selectedID`.
    @Binding var selection: Int?

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            summaryScene
            rolloutSection
            multivariateSection
            FreshnessLabel(date: store.loadedAt)
        }
    }

    // MARK: - Sections

    private var facts: FlagOverviewFacts { FlagOverviewFacts(store: store) }

    private var summaryScene: some View {
        Card(accent: Theme.SignalChrome.ink) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.xxl) {
                    flagIdentity
                    flagStateSummary.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    flagIdentity
                    SignalRule(mark: .flag)
                    flagStateSummary
                }
            }
        }
        .accessibilityIdentifier("gethog.signal-summary.flags")
        .signalConfirmation(trigger: store.loadedAt)
    }

    private var flagIdentity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Rollout signal", productMark: .flag)

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip(stacksAtAccessibilitySizes: true) {
                MetricTile(label: "Flags", value: "\(facts.flagCount)", compact: true)
                MetricTile(label: "Enabled", value: "\(facts.enabledCount)", compact: true)
                if facts.multivariateCount > 0 {
                    MetricTile(
                        label: "Multivariate",
                        value: "\(facts.multivariateCount)",
                        compact: true
                    )
                }
            }
            .padding(.horizontal, -Theme.Space.l)
        }
    }

    private var flagStateSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                ForEach(FlagStatusGroup.allCases) { statusCell($0) }
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(FlagStatusGroup.allCases) { statusCell($0) }
            }
        }
    }

    private func statusCell(_ group: FlagStatusGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            StatusPill(text: group.title, tint: group.tint)
            Text("\(facts.statusCounts[group, default: 0])")
                .font(Theme.Typography.metricSmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(facts.statusCounts[group, default: 0]) \(group.title.lowercased())"
        )
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
                        facts.enabledCount == 0
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
            selection = flag.id
        } label: {
            Card(padding: Theme.Space.m) {
                DataRow(
                    glyph: flag.isMultivariate ? "arrow.triangle.branch" : "flag.fill",
                    brandGlyph: FlagBrandAppearance.glyph(
                        isMultivariate: flag.isMultivariate,
                        isArchived: group == .archived
                    ),
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

    private var partialRollouts: [FeatureFlag] {
        facts.partialRollouts
    }

    private var multivariate: [FeatureFlag] {
        Array(store.flags.filter { $0.isMultivariate && !$0.archived }.prefix(5))
    }
}
