import GetHogKit
import SwiftUI

/// The experiment readout.
///
/// Presented by `RootView.DetailSheetView`, which constructs it as
/// `ExperimentDetailSheet(experiment:webURL:)` — that signature is fixed, so the
/// results store is `@State` here and the client comes from the environment
/// rather than being passed in.
///
/// Section order is the order a reader wants the answer in on a phone: the
/// verdict, then whether the traffic split can be trusted, then the per-metric
/// deltas, then how far through the experiment is. Setup comes last because it
/// is reference material, not news.
struct ExperimentDetailSheet: View {
    let experiment: Experiment
    let webURL: URL?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = ExperimentResultsStore()

    /// The detail payload once it has arrived, falling back to the list row the
    /// sheet was opened from so the setup section renders immediately.
    private var current: Experiment { store.detail ?? experiment }

    var body: some View {
        NavigationStack {
            List {
                resultsSections
                setupSection
                if let description = current.description, !description.isEmpty {
                    Section {
                        Text(description).font(.callout)
                    } header: {
                        SectionLabel(text: "Description", systemImage: "text.alignleft")
                    }
                }
                variantsSection
                linkSection
            }
            .pageSurface()
            .navigationTitle(current.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSections: some View {
        if let error = store.error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await load() } }
            } header: {
                SectionLabel(text: "Results", systemImage: "chart.bar")
            }
        } else if !current.hasLaunched {
            // A draft is not a failure and not an empty result. It has never
            // been shown to anyone, and saying anything else would be false.
            Section {
                ExperimentVerdictCard(
                    verdict: .notStarted,
                    method: current.configuredStatsMethod,
                    metricName: nil
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                SectionLabel(text: "Results", systemImage: "chart.bar")
            }
        } else {
            verdictSection
            exposureSection
            metricsSection
            progressSection
        }
    }

    @ViewBuilder
    private var verdictSection: some View {
        Section {
            ExperimentVerdictCard(
                // Before the detail lands there are no metric definitions and so
                // no readout. The card is skeletoned in that window, so what it
                // says underneath is never read as an answer.
                verdict: headlineReadout?.verdict ?? .noResults,
                method: store.method,
                metricName: store.primaryMetrics.first?.displayName
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .skeleton(store.isLoading && headlineReadout == nil)

            if let conclusion = current.conclusion {
                // A recorded conclusion is a human judgement, not a statistic.
                // Kept visually apart from the verdict so the two are not read
                // as the same claim.
                LabeledContent("Team's conclusion") {
                    StatusPill(text: conclusion.displayName, tint: conclusionTint(conclusion))
                }
                if let comment = current.conclusionComment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            SectionLabel(text: "Verdict", systemImage: "flag.checkered")
        }
    }

    @ViewBuilder
    private var exposureSection: some View {
        Section {
            // `isLoading` is passed rather than left to the `.skeleton`
            // modifier alone: the skeleton covers the section's content but does
            // not replace it, so without this the couldn't-be-loaded warning
            // was underneath it and read through the crossfade.
            ExperimentExposureSection(
                exposures: store.exposures,
                isUnavailable: store.exposuresUnavailable,
                isLoading: store.isLoading
            )
            .skeleton(store.isLoading && store.exposures == nil && !store.exposuresUnavailable)
        } header: {
            SectionLabel(text: "Exposure", systemImage: "person.2")
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        if store.primaryMetrics.isEmpty, !store.isLoading {
            Section {
                SectionEmptyState(
                    text: "No metrics",
                    systemImage: "chart.bar.doc.horizontal",
                    detail: "This experiment has no metrics attached, so there is nothing to measure."
                )
            } header: {
                SectionLabel(text: "Metrics", systemImage: "chart.bar.doc.horizontal")
            }
        } else {
            ForEach(store.primaryMetrics) { metric in
                Section {
                    metricSection(metric)
                } header: {
                    SectionLabel(text: metric.displayName, systemImage: metricSymbol(metric))
                }
            }
            ForEach(store.secondaryMetrics) { metric in
                Section {
                    metricSection(metric)
                } header: {
                    SectionLabel(
                        text: "\(metric.displayName) (secondary)",
                        systemImage: metricSymbol(metric)
                    )
                }
            }
        }
    }

    private func metricSection(_ metric: ExperimentMetric) -> some View {
        ExperimentMetricSection(
            metric: metric,
            readout: store.readout(for: metric, experiment: current),
            didFail: store.didFail(for: metric),
            isLoading: store.isLoading && !store.hasResult(for: metric) && !store.didFail(for: metric),
            webURL: webURL
        )
    }

    @ViewBuilder
    private var progressSection: some View {
        Section {
            ExperimentProgressSection(
                experiment: current,
                totalExposures: store.exposures.map { Int($0.totalExposures) }
            )
        } header: {
            SectionLabel(text: "Progress", systemImage: "clock")
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section {
            LabeledContent("Status") {
                StatusPill(
                    text: current.statusText,
                    tint: experimentStatusTint(current.statusText)
                )
            }
            if let key = current.featureFlagKey, !key.isEmpty {
                LabeledContent("Feature flag") {
                    Text(key)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let start = current.startDate {
                LabeledContent("Started") {
                    Text(start, format: .dateTime.year().month().day())
                }
            }
            if let end = current.endDate {
                LabeledContent("Ended") {
                    Text(end, format: .dateTime.year().month().day())
                }
            }
            if let method = store.method {
                LabeledContent("Statistics") { Text(method.displayName) }
            }
        } header: {
            SectionLabel(text: "Setup", systemImage: "gearshape")
        }
    }

    @ViewBuilder
    private var variantsSection: some View {
        if !current.variants.isEmpty {
            Section {
                ForEach(current.variants) { variant in
                    LabeledContent {
                        Text(variant.rolloutPercentage.map { "\($0)%" } ?? "—")
                            .font(.subheadline)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(variant.key)
                                .font(.subheadline.monospaced())
                            if let name = variant.name, !name.isEmpty, name != variant.key {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Ink.secondary)
                            }
                            if current.excludedVariants.contains(variant.key) {
                                Text("Excluded from analysis")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Status.warningInk)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SectionLabel(text: "Variants", systemImage: "arrow.triangle.branch")
            } footer: {
                if current.baselineVariant != nil {
                    Text("Deltas are measured against \(current.baselineVariant?.key ?? "the control arm").")
                }
            }
        }
    }

    @ViewBuilder
    private var linkSection: some View {
        Section {
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
            }
            FreshnessLabel(date: store.loadedAt)
        }
    }

    // MARK: - Helpers

    private var headlineReadout: ExperimentReadout? {
        guard !store.primaryMetrics.isEmpty else { return nil }
        return store.headlineReadout(for: current)
    }

    private func metricSymbol(_ metric: ExperimentMetric) -> String {
        switch metric.type {
        case .funnel: "line.3.horizontal.decrease"
        case .mean: "function"
        case .ratio: "divide"
        case .retention: "arrow.counterclockwise"
        case nil: "questionmark.square.dashed"
        }
    }

    private func conclusionTint(_ conclusion: ExperimentConclusion) -> Color {
        switch conclusion {
        case .won: Theme.Status.good
        case .lost, .invalid: Theme.Status.critical
        case .inconclusive, .stoppedEarly: Color.secondary
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, experiment: experiment)
    }
}
