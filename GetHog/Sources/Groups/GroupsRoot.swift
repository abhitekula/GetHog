import GetHogKit
import SwiftUI

@MainActor
@Observable
final class GroupTypesStore {
    var types: [GroupType] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var isEmpty: Bool { types.isEmpty }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            // A bare array, not a `Page`: this endpoint turns pagination off.
            let types: [GroupType] = try await client.send(
                PostHogAPI.groupTypes(projectID: projectID)
            )
            self.types = types.sorted()
            error = nil
            loadedAt = Date()
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// Group analytics: the account-like entities events are attributed to.
///
/// A project defines group *types* and each type holds its own groups, so this
/// screen is the type list and the groups live one level down. The type list
/// deliberately claims no group counts — getting them would cost one query per
/// type, and an invented "0" next to a type that simply hasn't been counted is
/// exactly the kind of quiet lie this app tries not to tell.
struct GroupsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = GroupTypesStore()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Groups")
                .toolbar { ProjectSwitcher() }
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
                .navigationDestination(for: GroupType.self) { type in
                    GroupListView(groupType: type)
                }
                .navigationDestination(for: GroupDetailTarget.self) { target in
                    GroupDetailView(group: target.group, groupType: target.groupType)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Approximate: groups are read through `/query/`, which is the scope
            // `.events` probes. The types endpoint additionally wants
            // `group:read`, which no capability models — a key that lacks it
            // surfaces as this screen's error rather than as a lock.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.isEmpty {
            EmptyStateView(
                title: "Couldn't load groups",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.isEmpty && !store.isLoading {
            // Keeps its own `ContentUnavailableView`: the action here is a link
            // out to PostHog rather than a button, which `EmptyStateView` does
            // not model.
            ContentUnavailableView {
                Label("No group types", systemImage: "person.3")
            } description: {
                Text("This project hasn't defined any group types. Groups let you attribute events to an account, workspace or company rather than to one person.")
            } actions: {
                if let url = model.webURL(path: "groups") {
                    Link("Open groups in PostHog", destination: url)
                }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.types) { type in
                    NavigationLink(value: type) {
                        GroupTypeRowView(groupType: type)
                    }
                    .listRowBackground(
                        Theme.cardBackground
                            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                            .padding(.vertical, 1)
                    )
                    .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(text: "Group types", systemImage: "person.3")
            } footer: {
                Text("Each type holds its own set of groups. Events carry a group key for every type they belong to.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

/// Navigation payload for a group, which needs its type along for the ride so
/// the detail screen can name what kind of thing it is showing.
struct GroupDetailTarget: Hashable {
    let group: GroupRow
    let groupType: GroupType
}

// MARK: - Rows

struct GroupTypeRowView: View {
    let groupType: GroupType

    var body: some View {
        DataRow(
            glyph: "person.3",
            title: groupType.pluralName,
            // The raw type is the string a developer passes to `group()` in the
            // SDK and types into a filter, so it stays monospaced and unaltered.
            subtitle: groupType.groupType,
            footnote: "Group type index \(groupType.index)",
            isSubtitleMonospaced: true,
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(groupType.pluralName), type \(groupType.groupType), index \(groupType.index)"
        )
    }
}

struct GroupRowView: View {
    let group: GroupRow

    var body: some View {
        DataRow(
            glyph: "building.2",
            title: group.displayName,
            // A group key is an identifier, so it is set monospaced. An unnamed
            // group has its key as the title already and says so here instead of
            // printing the same string twice.
            subtitle: group.hasDisplayName ? group.key : "No name property set",
            footnote: "\(createdText) · \(group.propertyCount) propert\(group.propertyCount == 1 ? "y" : "ies")",
            isSubtitleMonospaced: group.hasDisplayName,
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Never invents a date. A group whose `created_at` did not come back says so.
    private var createdText: String {
        guard let created = group.createdAt else { return "Created date unknown" }
        return "Created \(created.formatted(.relative(presentation: .named)))"
    }

    private var spokenSummary: String {
        var parts = [group.displayName]
        if !group.hasDisplayName { parts.append("no name property set") }
        parts.append(createdText)
        parts.append("\(group.propertyCount) properties")
        return parts.joined(separator: ", ")
    }
}
