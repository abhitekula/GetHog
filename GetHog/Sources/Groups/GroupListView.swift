import GetHogKit
import SwiftUI

@MainActor
@Observable
final class GroupListStore {
    var groups: [GroupRow] = []
    var isLoading = false
    var error: String?
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
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// The groups of one type, newest first.
struct GroupListView: View {
    let groupType: GroupType

    @Environment(AppModel.self) private var model
    @State private var store = GroupListStore()
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle(groupType.pluralName)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search \(groupType.pluralName.lowercased())")
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load groups", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.isEmpty && !store.isLoading {
            // A defined type with no groups is a real, common state — the type
            // exists because someone configured it, not because data arrived.
            ContentUnavailableView {
                Label("No groups yet", systemImage: "person.3")
            } description: {
                Text("Nothing has been identified as a “\(groupType.singularName)” in this project. Groups appear once your SDK sends a $groupidentify event for this type.")
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                if filtered.isEmpty {
                    Text("No \(groupType.pluralName.lowercased()) matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { group in
                        NavigationLink(value: GroupDetailTarget(group: group, groupType: groupType)) {
                            GroupRowView(group: group)
                        }
                    }
                }
            } header: {
                Text("\(store.groups.count) loaded")
            } footer: {
                Text("Newest first. Search matches the name and the group key.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
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

// MARK: - Detail

/// One group: what it is called, when it appeared, and what it carries.
struct GroupDetailView: View {
    let group: GroupRow
    let groupType: GroupType

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section(groupType.singularName) {
                LabeledContent("Name") {
                    Text(group.hasDisplayName ? group.displayName : "Not set")
                        .foregroundStyle(group.hasDisplayName ? .primary : .secondary)
                }
                LabeledContent("Key") {
                    Text(group.key)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Created") {
                    Text(group.createdAt.map {
                        $0.formatted(.dateTime.day().month().year())
                    } ?? "Unknown")
                }
                LabeledContent("Type") {
                    Text(groupType.groupType).font(.caption.monospaced())
                }
            }

            propertiesSection

            if let url = model.webURL(path: "groups/\(groupType.index)/\(webEncodedKey)") {
                Section {
                    Link(destination: url) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
            }
        }
        .navigationTitle(group.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var propertiesSection: some View {
        if case .object(let dict) = group.properties, !dict.isEmpty {
            Section("Properties (\(dict.count))") {
                ForEach(dict.keys.sorted(), id: \.self) { key in
                    PropertyRow(key: key, value: dict[key] ?? .null)
                }
            }
        } else {
            Section("Properties") {
                Text("This \(groupType.singularName.lowercased()) has no properties set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Group keys are opaque strings that may contain characters a path segment
    /// cannot carry verbatim.
    private var webEncodedKey: String {
        group.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? group.key
    }
}
