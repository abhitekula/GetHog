import GetHogKit
import GetHogUI
import SwiftUI

@MainActor
@Observable
final class GroupListStore {
    var groups: [GroupRow] = []
    var isLoading = false
    var error: LoadFailure?
    var loadedAt: Date?

    var isEmpty: Bool { groups.isEmpty }

    func load(client: PostHogClient, projectID: Int, groupTypeIndex: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.groups(projectID: projectID, groupTypeIndex: groupTypeIndex)
            )
            // Already ordered `created_at DESC` by the query; re-sorting here
            // would silently disagree with the ordering the API was asked for.
            groups = response.rows.compactMap(GroupRow.init(row:))
            error = nil
            loadedAt = Date()
        } catch {
            self.error = LoadFailure(error, loading: "groups")
        }
    }
}

/// The groups of one type, newest first.
struct GroupListView: View {
    let groupType: GroupType

    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = GroupListStore()
    @State private var search = ""

    /// The open group — level 1 of the Groups screen, with the group *type* at
    /// level 0 in `GroupsRoot`.
    ///
    /// This view is rebuilt along with everything else under it when the size
    /// class swaps hosts, so its own `@State` would go the same way the type's
    /// did. Both levels are restored, in order, by the two
    /// `navigationDestination(item:)`s reading these two slots.
    private var selection: Binding<GroupRow?> {
        Binding(
            get: { openDetails[.groups, level: 1] as? GroupRow },
            set: { openDetails[.groups, level: 1] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        content
            .navigationTitle(groupType.pluralName)
            .navigationDestination(item: selection) { group in
                GroupDetailView(group: group, groupType: groupType)
            }
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .searchable(text: $search, prompt: "Search \(groupType.pluralName.lowercased())")
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.isEmpty {
            LoadFailureState(title: "Couldn't load groups", failure: error) {
                Task { await load() }
            }
        } else if store.isEmpty && !store.isLoading {
            // A defined type with no groups is a real, common state — the type
            // exists because someone configured it, not because data arrived.
            EmptyStateView(
                title: "No groups yet",
                systemImage: "person.3",
                message: "Nothing has been identified as a “\(groupType.singularName)” in this project. Groups appear once your SDK sends a $groupidentify event for this type."
            )
        } else {
            list
        }
    }

    /// Selection-driven, like every other list that opens a detail across the
    /// size-class boundary.
    private var list: some View {
        List(selection: selection) {
            Section {
                if filtered.isEmpty {
                    Text("No \(groupType.pluralName.lowercased()) matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(Theme.Ink.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filtered) { group in
                        NavigationLink(value: group) {
                            GroupRowView(group: group)
                        }
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                SectionLabel(text: "\(store.groups.count) loaded", systemImage: "building.2")
            } footer: {
                Text("Newest first. Search matches the name and the group key.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .sparseCollectionSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    /// Filtered on device rather than through the query's own `search`
    /// parameter: the budget is organisation-wide, and a request per keystroke
    /// would spend it on a list already in memory.
    private var filtered: [GroupRow] {
        guard !search.isEmpty else { return store.groups }
        return store.groups.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.key.localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, groupTypeIndex: groupType.index)
    }
}

// `GroupDetailView` used to live here. It moved to `GroupDetailView.swift` when
// it stopped being a property list and grew the three windowed sections —
// activity, people and recordings — that each need a store of their own.
