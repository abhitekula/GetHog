import GetHogKit
import SwiftUI

@MainActor
@Observable
final class EarlyAccessStore {
    var features: [EarlyAccessFeature] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<EarlyAccessFeature> = try await client.send(
                PostHogAPI.earlyAccessFeatures(projectID: projectID)
            )
            features = page.results
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Grouped by stage in lifecycle order, dropping stages with nothing in them.
    var groups: [(stage: EarlyAccessStage, features: [EarlyAccessFeature])] {
        let byStage = Dictionary(grouping: features, by: \.stage)
        return (EarlyAccessStage.known + [.unknown]).compactMap { stage in
            guard let items = byStage[stage], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (stage: stage, features: sorted)
        }
    }
}

struct EarlyAccessRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = EarlyAccessStore()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Early access")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search features")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.flags) {
            // Gated on flags rather than dashboards: an early access feature is a
            // wrapper around a feature flag, and a key without `feature_flag:read`
            // would show every row with an empty flag.
            LockedCapabilityView(
                capability: .flags,
                scope: model.lockedScope(for: .flags)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.features.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load early access features", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.features.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No early access features",
                systemImage: "sparkles",
                description: Text(
                    "Features offered for opt-in in the PostHog web console will appear here."
                )
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(filteredGroups, id: \.stage) { group in
                Section {
                    ForEach(group.features) { feature in
                        EarlyAccessRowView(
                            feature: feature,
                            flagURL: feature.flagID.flatMap {
                                model.webURL(path: "feature_flags/\($0)")
                            }
                        )
                    }
                } header: {
                    Text(group.stage.title)
                } footer: {
                    Text(group.stage.explanation)
                }
            }

            if filteredGroups.isEmpty {
                Text("No features matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .skeleton(store.isLoading && store.features.isEmpty)
    }

    private var filteredGroups: [(stage: EarlyAccessStage, features: [EarlyAccessFeature])] {
        guard !search.isEmpty else { return store.groups }
        return store.groups.compactMap { group in
            let matches = group.features.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || ($0.description ?? "").localizedCaseInsensitiveContains(search)
                    || ($0.flagKey ?? "").localizedCaseInsensitiveContains(search)
            }
            return matches.isEmpty ? nil : (stage: group.stage, features: matches)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Row

struct EarlyAccessRowView: View {
    let feature: EarlyAccessFeature
    let flagURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(feature.name).font(.body).lineLimit(2)
                Spacer(minLength: 8)
                StatusPill(text: feature.stage.title, tint: stageTint(feature.stage))
            }

            if let description = feature.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let key = feature.flagKey {
                HStack(spacing: 8) {
                    Text(key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if feature.flagActive == false {
                        Text("flag off")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let flagURL {
                        Link(destination: flagURL) {
                            Label("Open flag", systemImage: "arrow.up.forward.square")
                                .font(.caption2)
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityLabel("Open the \(key) feature flag in PostHog")
                    }
                }
            } else {
                // A feature can be created before its flag exists; saying so beats
                // a blank line the reader has to interpret.
                Text("No feature flag attached yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        var parts = ["\(feature.name), stage \(feature.stage.title)"]
        if let description = feature.description { parts.append(description) }
        if let key = feature.flagKey {
            parts.append("flag \(key)\(feature.flagActive == false ? ", currently off" : "")")
        } else {
            parts.append("no feature flag attached yet")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Formatting

/// Tint for a lifecycle stage, always beside the stage's own word.
private func stageTint(_ stage: EarlyAccessStage) -> Color {
    switch stage {
    case .generalAvailability: Theme.Status.good
    case .beta, .alpha: Theme.accent
    case .draft, .concept: .secondary
    case .archived, .unknown: .secondary
    }
}
