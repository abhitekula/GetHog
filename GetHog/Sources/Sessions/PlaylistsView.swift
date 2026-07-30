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
            EmptyStateView(
                title: "Couldn't load playlists",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.playlists.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No playlists",
                systemImage: "rectangle.stack",
                message:
                    "Collections and saved replay filters made in the PostHog web console will appear here."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !store.own.isEmpty {
                Section {
                    ForEach(store.own) { row($0) }
                } header: {
                    SectionLabel(text: "Saved in this project", systemImage: "bookmark.fill")
                }
            }

            if !store.builtIn.isEmpty {
                Section {
                    ForEach(store.builtIn) { row($0) }
                } header: {
                    SectionLabel(text: "Built in", systemImage: "wand.and.stars")
                } footer: {
                    // Named as PostHog's, not the team's, because these appear in
                    // the same response and would otherwise read as playlists
                    // somebody created and forgot about.
                    Text("Views PostHog maintains for every project. They cannot be edited or deleted.")
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.playlists.isEmpty)
    }

    private func row(_ playlist: SessionRecordingPlaylist) -> some View {
        PlaylistRowView(playlist: playlist)
            .listRowBackground(
                Theme.cardBackground
                    .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .padding(.vertical, 1)
            )
            .listRowSeparator(.hidden)
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
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            DataRow(
                glyph: playlist.pinned ? "pin.fill" : playlist.kind.systemImage,
                // PostHog's own views take the warm secondary rather than the app
                // accent: they are real playlists, but they arrive in the same
                // response and should not compete with the ones a team made.
                tint: playlist.isSynthetic ? Theme.accentWarm : Theme.accent,
                title: playlist.name,
                subtitle: playlist.description,
                footnote: playlist.countSummary,
                accessory: .pill(playlist.kind.title, .secondary)
            )

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
