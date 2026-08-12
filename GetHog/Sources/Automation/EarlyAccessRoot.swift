import GetHogKit
import GetHogUI
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
    static let managementPath = "early_access_features"

    static let emptyPolicy = EmptyOutcomePolicy(
        title: "No early access features",
        systemImage: "sparkles",
        message: "An early access feature lets people opt themselves into a beta from inside your product, backed by a feature flag. This project offers none. GetHog reads early access features; create and manage them in PostHog.",
        actionTitle: "Manage in PostHog"
    )

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var store = EarlyAccessStore()
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle("Early access")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search features")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
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
            EmptyStateView(
                title: "Couldn't load early access",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.features.isEmpty && !store.isLoading {
            emptyState
        } else {
            list
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if consoleURL != nil {
            EmptyStateView(
                policy: Self.emptyPolicy,
                illustration: .experiment,
                action: openConsole
            )
        } else {
            EmptyStateView(policy: Self.emptyPolicy, illustration: .experiment)
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
                        .earlyAccessRowCard()
                    }
                } header: {
                    SectionLabel(text: group.stage.title, systemImage: "sparkles")
                } footer: {
                    Text(group.stage.explanation)
                }
            }

            if filteredGroups.isEmpty {
                Text("No features matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(Theme.Ink.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
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

    private var consoleURL: URL? { model.webURL(path: Self.managementPath) }

    private func openConsole() {
        if let consoleURL { openURL(consoleURL) }
    }
}

// MARK: - Row

struct EarlyAccessRowView: View {
    let feature: EarlyAccessFeature
    let flagURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            DataRow(
                glyph: "sparkles",
                tint: stageTint(feature.stage),
                title: feature.name,
                // A feature can be created before its flag exists; saying so
                // beats a blank line the reader has to interpret.
                subtitle: feature.flagKey ?? "No feature flag attached yet",
                footnote: feature.description,
                // Only the key is an identifier — the stand-in sentence is prose
                // and would read as code set in the same face.
                isSubtitleMonospaced: feature.flagKey != nil,
                accessory: .pill(feature.stage.title, stageTint(feature.stage))
            )

            // Kept out of `DataRow` on purpose: the link is a focusable element
            // in its own right, and folding it into the row would take it away
            // from VoiceOver, which is why this row combines its children as
            // `.contain` rather than `.combine`.
            if showsFlagAffordances {
                HStack(spacing: Theme.Space.s) {
                    if feature.flagActive == false {
                        Text("Flag off")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                    if let flagURL, let key = feature.flagKey {
                        Link(destination: flagURL) {
                            Label("Open flag", systemImage: "arrow.up.forward.square")
                                .font(Theme.Typography.caption)
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityLabel("Open the \(key) feature flag in PostHog")
                    }
                }
                // Indents past the glyph so the line hangs under the title
                // rather than under the row's leading edge.
                .padding(.leading, 44)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenSummary)
    }

    /// Both halves of the line are conditional, so the row asks before laying it
    /// out rather than reserving space for a line that renders empty.
    private var showsFlagAffordances: Bool {
        feature.flagActive == false || (flagURL != nil && feature.flagKey != nil)
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

// MARK: - Row chrome and formatting
//
// File-private so concurrent work on other screens can't collide with the name.

private extension View {
    /// The list treatment from the dashboards screen: every row is its own card
    /// on the page ground, with the system separator suppressed because the gap
    /// between cards already does that work.
    func earlyAccessRowCard() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
        )
        .listRowSeparator(.hidden)
    }
}

/// Tint for a lifecycle stage, always beside the stage's own word.
private func stageTint(_ stage: EarlyAccessStage) -> Color {
    switch stage {
    case .generalAvailability: Theme.Status.good
    case .beta, .alpha: Theme.accent
    case .draft, .concept: Theme.neutralMark
    case .archived, .unknown: Theme.neutralMark
    }
}
