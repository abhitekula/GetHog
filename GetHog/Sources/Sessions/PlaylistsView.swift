import GetHogKit
import SwiftUI

@MainActor
@Observable
final class PlaylistsStore {
    var playlists: [SessionRecordingPlaylist] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<SessionRecordingPlaylist> = try await client.send(
                PostHogAPI.sessionRecordingPlaylists(projectID: projectID)
            )
            playlists = page.results
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// The project's own playlists, pinned first.
    var own: [SessionRecordingPlaylist] {
        playlists
            .filter { !$0.isSynthetic }
            .sorted {
                ($0.pinned ? 0 : 1, $0.name) < ($1.pinned ? 0 : 1, $1.name)
            }
    }

    /// PostHog's built-in views — watch history, frustration signals and the
    /// rest — which arrive in the same page with negative ids.
    var builtIn: [SessionRecordingPlaylist] {
        playlists.filter(\.isSynthetic)
    }
}

/// Replay playlists: the project's saved filters and collections, plus the
/// built-in views PostHog injects into the same response.
///
/// A plain `View`, not a tab root: playlists belong inside the sessions area,
/// so this is meant to be pushed onto an existing navigation stack.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var store = PlaylistsStore()

    var body: some View {
        content
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.sessions) {
            LockedCapabilityView(
                capability: .sessions,
                scope: model.lockedScope(for: .sessions)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.playlists.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.playlists.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No playlists",
                systemImage: "rectangle.stack",
                description: Text(
                    "Collections and saved replay filters made in the PostHog web console will appear here."
                )
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !store.own.isEmpty {
                Section {
                    ForEach(store.own) { PlaylistRowView(playlist: $0) }
                } header: {
                    Text("Saved in this project")
                }
            }

            if !store.builtIn.isEmpty {
                Section {
                    ForEach(store.builtIn) { PlaylistRowView(playlist: $0) }
                } header: {
                    Text("Built in")
                } footer: {
                    // Named as PostHog's, not the team's, because these appear in
                    // the same response and would otherwise read as playlists
                    // somebody created and forgot about.
                    Text("Views PostHog maintains for every project. They cannot be edited or deleted.")
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .skeleton(store.isLoading && store.playlists.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Row

struct PlaylistRowView: View {
    let playlist: SessionRecordingPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(playlist.name).lineLimit(2)
                } icon: {
                    Image(systemName: playlist.pinned ? "pin.fill" : playlist.kind.systemImage)
                }
                .font(.body)

                Spacer(minLength: 8)

                StatusPill(text: playlist.kind.title, tint: .secondary)
            }

            if let description = playlist.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(playlist.countSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let progress = playlist.watchedProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    // The bar repeats what countSummary already said in words, so
                    // it carries no information of its own to announce twice.
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        var parts = ["\(playlist.name), \(playlist.kind.title.lowercased())"]
        if playlist.pinned { parts.append("pinned") }
        if let description = playlist.description { parts.append(description) }
        parts.append(playlist.countSummary)
        if let progress = playlist.watchedProgress {
            parts.append("\(progress.formatted(.percent.precision(.fractionLength(0)))) watched")
        }
        return parts.joined(separator: ", ")
    }
}
