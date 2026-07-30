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
    private static let statusOrder = ["Running", "Draft", "Complete", "Archived"]

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
    @State private var store = ExperimentsStore()
    @State private var selected: Experiment?

    var body: some View {
        // No second column: the detail is a sheet because the numbers that
        // would justify one aren't computed on device. The stack this pushes
        // into belongs to the container — see `RootView`.
        content
            .navigationTitle("Experiments")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
            .sheet(item: $selected) { experiment in
                ExperimentDetailSheet(
                    experiment: experiment,
                    webURL: model.webURL(path: "experiments/\(experiment.id)")
                )
            }
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
            EmptyStateView(
                title: "No experiments",
                systemImage: "flask",
                message: "This project doesn't have any experiments yet."
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

// MARK: - Detail

struct ExperimentDetailSheet: View {
    let experiment: Experiment
    let webURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status") {
                        StatusPill(
                            text: experiment.statusText,
                            tint: experimentStatusTint(experiment.statusText)
                        )
                    }
                    if let key = experiment.featureFlagKey, !key.isEmpty {
                        LabeledContent("Feature flag") {
                            Text(key)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let start = experiment.startDate {
                        LabeledContent("Started") {
                            Text(start, format: .dateTime.year().month().day())
                        }
                    }
                    if let end = experiment.endDate {
                        LabeledContent("Ended") {
                            Text(end, format: .dateTime.year().month().day())
                        }
                    }
                }

                if let description = experiment.description, !description.isEmpty {
                    Section {
                        Text(description).font(.callout)
                    } header: {
                        SectionLabel(text: "Description", systemImage: "text.alignleft")
                    }
                }

                Section {
                    if let webURL {
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    }
                } header: {
                    SectionLabel(text: "Results", systemImage: "chart.bar")
                } footer: {
                    // Said plainly: this screen shows setup, not outcomes. An
                    // experiment readout that hinted at a winner without running
                    // the statistics would be worse than no readout at all.
                    Text("GetHog shows how this experiment is set up. Variant results, exposures and statistical significance are computed by the PostHog web console and are not shown here.")
                }
            }
            .pageSurface()
            .navigationTitle(experiment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Formatting
//
// File-private so concurrent work on other screens can't collide with the name.

/// Chrome tint for a lifecycle status. The status word always travels with it —
/// in the pill, the section header and the accessibility label — so the colour
/// is never the only thing saying what state an experiment is in.
private func experimentStatusTint(_ status: String) -> Color {
    switch status {
    case "Running": Theme.Status.good
    case "Draft": Theme.accentWarm
    default: Color.secondary
    }
}

private func experimentStatusSymbol(_ status: String) -> String {
    switch status {
    case "Running": "play.circle"
    case "Draft": "pencil"
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
