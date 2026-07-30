import GetHogKit
import SwiftUI

@MainActor
@Observable
final class DashboardsStore {
    var dashboards: [DashboardSummary] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<DashboardSummary> = try await client.send(
                PostHogAPI.dashboards(projectID: projectID)
            )
            dashboards = page.results.filter { !$0.title.isEmpty }
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    var pinned: [DashboardSummary] { dashboards.filter(\.pinned) }
    var others: [DashboardSummary] { dashboards.filter { !$0.pinned } }
}

struct DashboardsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = DashboardsStore()
    @State private var selection: DashboardSummary?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            content
                .navigationTitle("Dashboards")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search dashboards")
                .refreshable { await load() }
                .task(id: model.projectID) {
                    await load()
                    applyDebugSelectionIfNeeded()
                }
        } detail: {
            if let selection {
                // `.id` rebuilds the screen per dashboard, which also clears the
                // previously selected tile rather than leaving one dashboard's
                // insight open beside another dashboard's grid.
                DashboardDetailView(summary: selection)
                    .id(selection.id)
            } else {
                ContentUnavailableView(
                    "Select a dashboard",
                    systemImage: "square.grid.2x2",
                    description: Text("Pick a dashboard to see its tiles.")
                )
            }
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
        } else if let error = store.error, store.dashboards.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load dashboards", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.dashboards.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No dashboards",
                systemImage: "square.grid.2x2",
                description: Text("This project doesn't have any dashboards yet.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if !filtered(store.pinned).isEmpty {
                Section("Pinned") {
                    ForEach(filtered(store.pinned), id: \.self) { row($0) }
                }
            }
            Section(filtered(store.pinned).isEmpty ? "" : "All dashboards") {
                ForEach(filtered(store.others), id: \.self) { row($0) }
            }
            if let loadedAt = store.loadedAt {
                FreshnessLabel(date: loadedAt)
                    .listRowBackground(Color.clear)
            }
        }
        .skeleton(store.isLoading && store.dashboards.isEmpty)
    }

    private func row(_ dashboard: DashboardSummary) -> some View {
        NavigationLink(value: dashboard) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.title)
                    .font(.body)
                if let description = dashboard.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contextMenu {
            if let url = model.webURL(path: "dashboard/\(dashboard.id)") {
                Link(destination: url) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("Copy link", systemImage: "link")
                }
            }
        }
    }

    private func filtered(_ items: [DashboardSummary]) -> [DashboardSummary] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }

    private func applyDebugSelectionIfNeeded() {
        #if DEBUG
        switch DebugLaunch.dashboard {
        case .first:
            selection = store.pinned.first ?? store.dashboards.first
        case .id(let id):
            selection = store.dashboards.first { $0.id == id }
        case nil:
            break
        }
        #endif
    }
}
