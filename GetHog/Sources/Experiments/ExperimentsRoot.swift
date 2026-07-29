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
        // NavigationStack, not a split view: the detail is a sheet because the
        // numbers that justify a second column aren't computed on device.
        NavigationStack {
            content
                .navigationTitle("Experiments")
                .toolbar { ProjectSwitcher() }
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
        }
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
            ContentUnavailableView {
                Label("Couldn't load experiments", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.experiments.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No experiments",
                systemImage: "flask",
                description: Text("This project doesn't have any experiments yet.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(store.groups, id: \.status) { group in
                Section(group.status) {
                    ForEach(group.experiments) { experiment in
                        Button {
                            selected = experiment
                        } label: {
                            ExperimentRowView(experiment: experiment)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this experiment's setup")
                    }
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
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
        VStack(alignment: .leading, spacing: 5) {
            Text(experiment.name)
                .font(.body)
                .lineLimit(2)

            if let key = experiment.featureFlagKey, !key.isEmpty {
                // The flag key is an identifier developers copy verbatim, so it
                // is set in a monospaced face to keep it unambiguous.
                Text(key)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Feature flag \(key)")
            } else {
                Text("No feature flag linked")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(experimentRangeText(start: experiment.startDate, end: experiment.endDate))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
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
                    LabeledContent("Status") { Text(experiment.statusText) }
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
                    Section("Description") {
                        Text(description).font(.callout)
                    }
                }

                Section {
                    if let webURL {
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    }
                } header: {
                    Text("Results")
                } footer: {
                    // Said plainly: this screen shows setup, not outcomes. An
                    // experiment readout that hinted at a winner without running
                    // the statistics would be worse than no readout at all.
                    Text("GetHog shows how this experiment is set up. Variant results, exposures and statistical significance are computed by the PostHog web console and are not shown here.")
                }
            }
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
