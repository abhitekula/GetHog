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
    /// Owned by `RootView` and injected, not `@State` here, for the reason
    /// `OpenDetails` is: this sheet is presented from above the size-class
    /// boundary, and the list underneath it needs to show the same status word
    /// this screen just wrote. A controller scoped to the sheet would leave the
    /// row reading "Running" behind a sheet that says "Paused".
    @Environment(ExperimentLifecycleController.self) private var lifecycle
    @State private var store = ExperimentResultsStore()

    /// The end-experiment form, revealed rather than always present: it is five
    /// radio rows and a text field, and an experiment nobody is ending should not
    /// pay that much of the screen for it.
    @State private var isChoosingConclusion = false
    @State private var conclusion: ExperimentConclusion = .won
    @State private var conclusionComment = ""
    @State private var isConfirmingEnd = false
    /// Direction of the pause/resume being confirmed. Never cleared on dismissal,
    /// so the dialog's wording doesn't flicker while it animates away — the same
    /// reason `FlagDetailView` keeps `requestedActivation`.
    @State private var requestedPause = true
    @State private var isConfirmingPause = false

    /// The detail payload once it has arrived, falling back to the list row the
    /// sheet was opened from so the setup section renders immediately.
    private var current: Experiment { store.detail ?? experiment }

    /// The linked flag's key, named in every dialog that changes it. A pause with
    /// no flag key in its wording is a pause that does not say what it turns off.
    private var flagKey: String? {
        guard let key = current.featureFlagKey, !key.isEmpty else { return nil }
        return key
    }

    var body: some View {
        DetailSheetContainer {
            List {
                resultsSections
                lifecycleSection
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
            // Sheet chrome, and only the sheet has it: on the Mac this detail is
            // pushed, where Done would duplicate the Back button.
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .refreshable { await load() }
            .task { await load() }
            .confirmationDialog(
                requestedPause ? "Pause \(current.name)?" : "Resume \(current.name)?",
                isPresented: $isConfirmingPause,
                titleVisibility: .visible
            ) {
                Button(
                    requestedPause ? "Pause and turn the flag off" : "Resume and turn the flag on",
                    role: .destructive
                ) {
                    commitPause(requestedPause)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(pauseConfirmationDetail)
            }
            .confirmationDialog(
                "End \(current.name) as \(conclusion.displayName)?",
                isPresented: $isConfirmingEnd,
                titleVisibility: .visible
            ) {
                Button("End the experiment") { commitEnd() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(endConfirmationDetail)
            }
            .sensoryFeedback(.success, trigger: lifecycle.successCount)
            .sensoryFeedback(.error, trigger: lifecycle.failureCount)
            // Neither of the two above. A write that came back
            // `approval_required` did not fail — the experiment is unchanged and a
            // change request is waiting for a colleague — and it did not succeed
            // either.
            .sensoryFeedback(.warning, trigger: lifecycle.filedCount)
        }
    }

    // MARK: - Lifecycle
    //
    // The write surface, and the reason it is three separate controls with three
    // separate dialogs rather than one "Stop" button:
    //
    //   End    writes end_date and the conclusion. Does NOT touch the feature
    //          flag. People already in a variant keep seeing it.
    //   Pause  calls set_flag_active on the linked flag. Nobody sees a variant.
    //          Writes nothing on the experiment row at all.
    //
    // "Stop the experiment" is a reasonable thing to say and it means either of
    // those. A dialog that does not distinguish them is worse than no button, so
    // both dialogs name the feature flag explicitly and say what happens to it.

    @ViewBuilder
    private var lifecycleSection: some View {
        if lifecycle.canEnd(current) || lifecycle.canPause(current) || lifecycle.canResume(current) {
            Section {
                // Buttons on the detail sheet, never a swipe action on the list.
                // Reaching something that changes what production serves should
                // cost a deliberate tap into the thing being changed — the same
                // rule the flags and error-triage screens follow.
                if lifecycle.canPause(current) {
                    lifecycleButton(
                        "Pause",
                        systemImage: "pause.circle",
                        tint: Theme.accentWarm,
                        hint: "Turns off the linked feature flag, so nobody is served a variant."
                    ) {
                        requestedPause = true
                        isConfirmingPause = true
                    }
                }

                if lifecycle.canResume(current) {
                    lifecycleButton(
                        "Resume",
                        systemImage: "play.circle",
                        tint: Theme.accent,
                        hint: "Turns the linked feature flag back on, so variants are served again."
                    ) {
                        requestedPause = false
                        isConfirmingPause = true
                    }
                }

                if lifecycle.canEnd(current) {
                    if isChoosingConclusion {
                        conclusionForm
                    } else {
                        lifecycleButton(
                            "End experiment",
                            systemImage: "flag.checkered",
                            tint: Color.secondary,
                            hint: "Records a conclusion and closes the results window. Does not change the feature flag."
                        ) {
                            conclusion = current.conclusion ?? .won
                            conclusionComment = lifecycle.effectiveConclusionComment(current) ?? ""
                            isChoosingConclusion = true
                        }
                    }
                }

                if let message = lifecycle.message {
                    WriteOutcomeMessageView(message: message) { lifecycle.dismissMessage() }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Lifecycle", systemImage: "slider.horizontal.3")
                    Spacer(minLength: 8)
                    if lifecycle.isBusy(current) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving change")
                    }
                }
            } footer: {
                Text(lifecycleFooter)
            }
        }
    }

    private func lifecycleButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .disabled(lifecycle.isBusy(current))
        .accessibilityHint(hint)
    }

    /// The conclusion is a required choice, not a defaulted one.
    ///
    /// `end_experiment` assigns `conclusion` unconditionally, and the serializer
    /// defaults an absent field to `None` — so ending an experiment without
    /// naming one writes `null` over whatever a colleague had already recorded.
    /// `PostHogAPI.endExperiment` therefore cannot express "no conclusion", and
    /// this form is what makes that a deliberate answer rather than an obstacle.
    ///
    /// An inline picker, not a menu: five options with a sentence each do not fit
    /// in a menu label, the sentences are the whole reason a stranger to the word
    /// "inconclusive" can pick correctly, and a borderless `Menu`'s tap target is
    /// its label's bounds rather than the row's.
    @ViewBuilder
    private var conclusionForm: some View {
        Picker("Conclusion", selection: $conclusion) {
            ForEach(ExperimentConclusion.allCases, id: \.self) { value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.displayName)
                    Text(value.meaning)
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                .tag(value)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()

        TextField("Why (optional)", text: $conclusionComment, axis: .vertical)
            .lineLimit(1...4)
            .font(.subheadline)
            // Real prose: wins over the app-wide `.never` that protects
            // search queries from autocapitalisation.
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .accessibilityLabel("Conclusion comment, optional")

        Button {
            isConfirmingEnd = true
        } label: {
            Label("End as \(conclusion.displayName)", systemImage: "flag.checkered")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accentWarm)
        .disabled(lifecycle.isBusy(current))

        Button("Cancel") { isChoosingConclusion = false }
            .font(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }

    /// States the distinction once, where the controls are, so it is not only in
    /// the dialogs somebody may tap through.
    private var lifecycleFooter: String {
        let flag = flagKey.map { "“\($0)”" } ?? "the linked feature flag"
        return """
            Pausing turns \(flag) off, so nobody is served a variant. Ending records your \
            conclusion and closes the results window but leaves \(flag) exactly as it is — people \
            already in a variant keep seeing it. You'll be asked to confirm either way.
            """
    }

    private var pauseConfirmationDetail: String {
        let target = model.selectedProject.map { " in \($0.name)" } ?? ""
        let flag = flagKey.map { "the feature flag “\($0)”" } ?? "this experiment's feature flag"
        if requestedPause {
            return """
                This turns \(flag) off\(target), immediately. Everyone currently being served a \
                variant stops being served one. Results already collected are kept, and resuming \
                turns the flag back on.
                """
        }
        return """
            This turns \(flag) back on\(target), immediately. People will start being assigned \
            variants again and exposures will resume counting.
            """
    }

    private var endConfirmationDetail: String {
        let target = model.selectedProject.map { " in \($0.name)" } ?? ""
        let flag = flagKey.map { "“\($0)”" } ?? "the linked feature flag"
        return """
            Records “\(conclusion.displayName)” against this experiment\(target) and closes its \
            results window. \(flag) is not changed — anyone already in a variant keeps seeing it. \
            Pause the experiment as well if you want that to stop.
            """
    }

    private func commitPause(_ paused: Bool) {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            await lifecycle.setPaused(
                paused, experiment: current, client: client, projectID: projectID
            )
        }
    }

    private func commitEnd() {
        guard let client = model.client, let projectID = model.projectID else { return }
        let chosen = conclusion
        let comment = conclusionComment
        Task {
            await lifecycle.end(
                current,
                conclusion: chosen,
                comment: comment,
                client: client,
                projectID: projectID
            )
            isChoosingConclusion = false
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

            if let conclusion = lifecycle.effectiveConclusion(current) {
                // A recorded conclusion is a human judgement, not a statistic.
                // Kept visually apart from the verdict so the two are not read
                // as the same claim.
                LabeledContent("Team's conclusion") {
                    StatusPill(text: conclusion.displayName, tint: conclusionTint(conclusion))
                }
                if let comment = lifecycle.effectiveConclusionComment(current), !comment.isEmpty {
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
                // The effective word, so the pill cannot say "Running" a beat
                // after the Pause button was answered.
                StatusPill(
                    text: lifecycle.effectiveStatusText(current),
                    tint: experimentStatusTint(lifecycle.effectiveStatusText(current))
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
            if let end = lifecycle.effectiveEndDate(current) {
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
