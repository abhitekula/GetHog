import GetHogKit
import SwiftUI

@MainActor
@Observable
final class ActionsStore {
    var actions: [PostHogAction] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var isEmpty: Bool { actions.isEmpty }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<PostHogAction> = try await client.send(
                PostHogAPI.actions(projectID: projectID, limit: 100)
            )
            // Deleted actions still come back on this endpoint, and pinned ones
            // are pinned because someone wanted them first.
            actions = page.results
                .filter { !$0.isDeleted }
                .sorted {
                    ($0.isPinned ? 0 : 1, $0.name.lowercased())
                        < ($1.isPinned ? 0 : 1, $1.name.lowercased())
                }
            error = nil
            loadedAt = Date()
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// Saved event definitions.
///
/// An action is several matchers OR-ed together, so the only useful thing a list
/// row can say is what those matchers actually match — a name alone tells you
/// nothing about whether the action is still catching the right clicks.
struct ActionsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = ActionsStore()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Actions")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search actions")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
                .navigationDestination(for: PostHogAction.self) { action in
                    ActionDetailView(action: action)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Actions are definitions over captured events; there is no separate
            // action scope to probe, so this gates on the nearest true thing.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load actions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.isEmpty && !store.isLoading {
            ContentUnavailableView {
                Label("No actions", systemImage: "cursorarrow.click.badge.clock")
            } description: {
                Text("This project hasn't defined any actions. Actions group several events or clicks under one name so insights can use them as a single step.")
            } actions: {
                if let url = model.webURL(path: "data-management/actions") {
                    Link("Create one in PostHog", destination: url)
                }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                if filtered.isEmpty {
                    Text("No actions matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { action in
                        NavigationLink(value: action) {
                            ActionRowView(action: action)
                        }
                    }
                }
            } footer: {
                Text("An action fires when any one of its steps matches.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .skeleton(store.isLoading && store.isEmpty)
    }

    private var filtered: [PostHogAction] {
        guard !search.isEmpty else { return store.actions }
        return store.actions.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.description ?? "").localizedCaseInsensitiveContains(search)
                || $0.matchedEvents.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Rows

struct ActionRowView: View {
    let action: PostHogAction

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(action.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if action.isCalculating {
                    StatusPill(text: "Calculating", tint: Theme.accent)
                } else if action.steps.isEmpty {
                    StatusPill(text: "No steps", tint: Theme.Status.critical)
                }
            }

            if let description = action.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(action.stepSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(calculationText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Never invents a time. An action PostHog has not yet counted says so.
    private var calculationText: String {
        guard let last = action.lastCalculatedAt else { return "Never calculated" }
        return "Last calculated \(last.formatted(.relative(presentation: .named)))"
    }

    private var spokenSummary: String {
        var parts = [action.name]
        if action.isPinned { parts.append("pinned") }
        if let description = action.description { parts.append(description) }
        parts.append(action.stepSummary)
        if action.isCalculating { parts.append("currently calculating") }
        parts.append(calculationText)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

struct ActionDetailView: View {
    let action: PostHogAction
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Action") {
                if let description = action.description {
                    Text(description).font(.callout)
                }
                LabeledContent("Steps") { Text(action.stepSummary) }
                LabeledContent("Last calculated") {
                    Text(action.lastCalculatedAt.map {
                        $0.formatted(.relative(presentation: .named))
                    } ?? "Never")
                }
                if action.isCalculating {
                    Label("PostHog is recalculating this action now", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let created = action.createdAt {
                    LabeledContent("Created") {
                        Text(created, format: .dateTime.day().month().year())
                    }
                }
                if let author = action.createdByName {
                    LabeledContent("Created by") { Text(author) }
                }
                if !action.tags.isEmpty {
                    LabeledContent("Tags") { Text(action.tags.joined(separator: ", ")) }
                }
            }

            Section {
                if action.steps.isEmpty {
                    Text("This action has no steps, so it never matches anything.")
                        .font(.callout)
                        .foregroundStyle(Theme.Status.critical)
                } else {
                    ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Step \(index + 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            Text(step.summary)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1), \(step.summary)")
                    }
                }
            } header: {
                Text("Steps")
            } footer: {
                Text("Any single step matching is enough to fire the action.")
            }

            if let url = model.webURL(path: "data-management/actions/\(action.id)") {
                Section {
                    Link(destination: url) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
            }
        }
        .navigationTitle(action.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
