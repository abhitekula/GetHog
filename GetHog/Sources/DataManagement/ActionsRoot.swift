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
    @Environment(OpenDetails.self) private var openDetails
    @Environment(\.openURL) private var openURL
    @State private var store = ActionsStore()
    @State private var search = ""

    /// The open action, held in `OpenDetails` rather than pushed as a value onto
    /// the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it, and a value on
    /// the host's stack goes when the host does.
    private var selection: Binding<PostHogAction?> {
        Binding(
            get: { openDetails[.actions] as? PostHogAction },
            set: { openDetails[.actions] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        content
            .navigationTitle("Actions")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search actions")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
            .navigationDestination(item: selection) { action in
                ActionDetailView(action: action)
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
            EmptyStateView(
                title: "Couldn't load actions",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No actions",
                systemImage: "cursorarrow.click.badge.clock",
                message: "An action groups several events or clicks under one name so an insight can use them as a single step. Nobody has defined one in this project — actions are optional, and a project that queries raw events directly never needs any.",
                // GetHog reads actions and cannot create one, so the only
                // thing on offer is the console that can.
                actionTitle: consoleURL == nil ? nil : "Define one in PostHog",
                action: openConsole
            )
        } else {
            list
        }
    }

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` displays it.
    private var list: some View {
        List(selection: selection) {
            Section {
                if filtered.isEmpty {
                    Text("No actions matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { action in
                        NavigationLink(value: action) {
                            ActionRowView(action: action)
                        }
                        .actionsRowCard()
                    }
                }
            } footer: {
                Text("An action fires when any one of its steps matches.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
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

    private var consoleURL: URL? { model.webURL(path: "data-management/actions") }

    private var openConsole: (() -> Void)? {
        guard let consoleURL else { return nil }
        return { openURL(consoleURL) }
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
        DataRow(
            glyph: "cursorarrow.click",
            // Pinned actions take the warm secondary, the way the dashboard list
            // marks generated tiles: the sort already floats them to the top,
            // and the tint is what says *why* they are up there.
            tint: action.isPinned ? Theme.accentWarm : Theme.accent,
            title: action.name,
            subtitle: action.description ?? matchSummary,
            footnote: calculationText,
            // Only the fallback is an identifier list — a description is prose
            // and monospacing it would read as code.
            isSubtitleMonospaced: action.description == nil && !action.matchedEvents.isEmpty,
            accessory: accessory
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// The events this action can fire on, which is the thing a name alone never
    /// tells you. Falls back to the step count when no step names an event —
    /// a selector-only action matches clicks, not a named event.
    private var matchSummary: String {
        let events = action.matchedEvents
        return events.isEmpty ? action.stepSummary : events.joined(separator: ", ")
    }

    /// A stepless action is broken rather than merely idle, so it keeps the
    /// critical tint even though nothing is running.
    private var accessory: RowAccessory {
        if action.isCalculating { return .pill("Calculating", Theme.accent) }
        if action.steps.isEmpty { return .pill("No steps", Theme.Status.critical) }
        // The row pushes a detail screen, so there is nothing to add here — the
        // link draws its own disclosure.
        return .none
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
            Section {
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
            } header: {
                SectionLabel(text: "Action", systemImage: "cursorarrow.click")
            }

            Section {
                if action.steps.isEmpty {
                    Text("This action has no steps, so it never matches anything.")
                        .font(.callout)
                        .foregroundStyle(Theme.Status.criticalInk)
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
                SectionLabel(text: "Steps", systemImage: "list.number")
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
        .pageSurface()
        .navigationTitle(action.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row chrome
//
// File-private so concurrent work on other screens can't collide with the name.

private extension View {
    /// The list treatment from the dashboards screen: every row is its own card
    /// on the page ground, with the system separator suppressed because the gap
    /// between cards already does that work.
    func actionsRowCard() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}
