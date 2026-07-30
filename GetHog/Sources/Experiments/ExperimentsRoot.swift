import GetHogKit
import SwiftUI

@MainActor
@Observable
final class ExperimentsStore {
    var experiments: [Experiment] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// Lifecycle order, not alphabetical: what is live matters most.
    ///
    /// Covers all five states `ExperimentStatusEnum` declares, plus the archived
    /// flag which overrides them. `Paused` and `Exposure frozen` are virtual
    /// states PostHog derives from the feature flag rather than storing, and
    /// neither can be inferred from the start and end dates alone.
    private static let statusOrder = [
        "Running", "Paused", "Exposure frozen", "Draft", "Complete", "Archived",
    ]

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<Experiment> = try await client.send(
                PostHogAPI.experiments(projectID: projectID)
            )
            experiments = page.results
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    var groups: [(status: String, experiments: [Experiment])] {
        let grouped = Dictionary(grouping: experiments, by: \.statusText)
        var result: [(status: String, experiments: [Experiment])] = Self.statusOrder.compactMap { status in
            guard let items = grouped[status], !items.isEmpty else { return nil }
            let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return (status: status, experiments: sorted)
        }
        // Any status PostHog adds later still appears rather than vanishing.
        for status in grouped.keys.sorted() where !Self.statusOrder.contains(status) {
            result.append((status: status, experiments: grouped[status] ?? []))
        }
        return result
    }
}

struct ExperimentsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = ExperimentsStore()

    /// The open experiment. No second column: the detail is a sheet because the
    /// numbers that would justify one aren't computed on device. The sheet
    /// itself is presented by `RootView` — a sheet driven from inside a
    /// secondary screen is dismissed by a size-class change and cannot be put
    /// back, see `RootView.presentedDetail`.
    private var selected: Experiment? {
        get { openDetails[.experiments] as? Experiment }
        nonmutating set { openDetails[.experiments] = newValue.map(AnyHashable.init) }
    }

    var body: some View {
        content
            .navigationTitle("Experiments")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.experiments.isEmpty {
            EmptyStateView(
                title: "Couldn't load experiments",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await load() }
            }
        } else if store.experiments.isEmpty && !store.isLoading {
            // Says what the product is, not only that it is empty — the standard
            // Notebooks, Actions and Pipelines already set on this app's empty
            // states.
            EmptyStateView(
                title: "No experiments",
                systemImage: "flask",
                message: "An experiment splits traffic behind a feature flag and measures one metric against a control. None have been created in this project; they are set up in PostHog and appear here once they exist."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(store.groups, id: \.status) { group in
                Section {
                    ForEach(group.experiments) { experiment in
                        Button {
                            selected = experiment
                        } label: {
                            ExperimentRowView(experiment: experiment)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this experiment's setup")
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    SectionLabel(text: group.status, systemImage: experimentStatusSymbol(group.status))
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.experiments.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

struct ExperimentRowView: View {
    let experiment: Experiment

    var body: some View {
        DataRow(
            glyph: "flask.fill",
            tint: experimentStatusTint(experiment.statusText),
            title: experiment.name,
            subtitle: flagKey ?? "No feature flag linked",
            footnote: experimentRangeText(start: experiment.startDate, end: experiment.endDate),
            // The flag key is an identifier developers copy verbatim, so it is
            // set in a monospaced face to keep it unambiguous. The stand-in
            // sentence is prose and stays in the body face.
            isSubtitleMonospaced: flagKey != nil,
            accessory: .pill(experiment.statusText, experimentStatusTint(experiment.statusText))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var flagKey: String? {
        guard let key = experiment.featureFlagKey, !key.isEmpty else { return nil }
        return key
    }

    /// Keeps the spoken "Feature flag …" prefix that the key's own label used to
    /// carry, now that the row reads as a single element.
    private var accessibilityDescription: String {
        [
            experiment.name,
            experiment.statusText,
            flagKey.map { "Feature flag \($0)" } ?? "No feature flag linked",
            experimentRangeText(start: experiment.startDate, end: experiment.endDate),
        ].joined(separator: ", ")
    }
}

// MARK: - Formatting
//
// Shared with `ExperimentDetailView.swift`, which is why these are internal
// rather than file-private: the detail sheet paints the same status pill as the
// row that opened it, and two copies of this mapping would drift.

/// Chrome tint for a lifecycle status. The status word always travels with it —
/// in the pill, the section header and the accessibility label — so the colour
/// is never the only thing saying what state an experiment is in.
func experimentStatusTint(_ status: String) -> Color {
    switch status {
    case "Running": Theme.Status.good
    case "Draft", "Paused", "Exposure frozen": Theme.accentWarm
    default: Color.secondary
    }
}

func experimentStatusSymbol(_ status: String) -> String {
    switch status {
    case "Running": "play.circle"
    case "Draft": "pencil"
    case "Paused": "pause.circle"
    case "Exposure frozen": "snowflake"
    case "Complete": "checkmark.circle"
    case "Archived": "archivebox"
    // Any status PostHog adds later still gets a header rather than a gap.
    default: "circle"
    }
}

private func experimentRangeText(start: Date?, end: Date?) -> String {
    let format = Date.FormatStyle.dateTime.year().month(.abbreviated).day()
    switch (start, end) {
    case (nil, _):
        return "Not started"
    case (let start?, nil):
        return "Running since \(start.formatted(format))"
    case (let start?, let end?):
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }
}
