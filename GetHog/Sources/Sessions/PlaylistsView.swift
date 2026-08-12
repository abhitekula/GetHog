import GetHogKit
import GetHogUI
import SwiftUI

@MainActor
@Observable
final class PlaylistsStore {
    var playlists: [SessionRecordingPlaylist] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// The project whose rows are allowed to publish into this store. Updated
    /// and cleared before a replacement request suspends.
    private var loadedProjectID: Int?
    private var generation = 0

    func load(client: PostHogClient, projectID: Int) async {
        generation += 1
        let token = generation
        if loadedProjectID != projectID {
            loadedProjectID = projectID
            playlists = []
            error = nil
            loadedAt = nil
        }
        isLoading = true
        defer {
            if token == generation, loadedProjectID == projectID {
                isLoading = false
            }
        }
        do {
            let page: Page<SessionRecordingPlaylist> = try await client.send(
                PostHogAPI.sessionRecordingPlaylists(projectID: projectID)
            )
            guard token == generation, loadedProjectID == projectID else { return }
            playlists = page.results
            loadedAt = Date()
            error = nil
        } catch {
            guard token == generation, loadedProjectID == projectID else { return }
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Saved filters: stored queries, re-run on open. Pinned first.
    ///
    /// Grouped by *what a playlist is* rather than by who made it, which is the
    /// division that changes what happens when you tap one. The screen used to
    /// split "Saved in this project" from "Built in", which put a stored query
    /// and a hand-pinned list side by side under one heading and left the only
    /// distinction that matters to a small grey pill on the row.
    var savedFilters: [SessionRecordingPlaylist] {
        playlists
            .filter { $0.kind == .filters }
            .sorted { ($0.pinned ? 0 : 1, $0.name) < ($1.pinned ? 0 : 1, $1.name) }
    }

    /// Collections: static lists of recordings somebody pinned. Includes
    /// PostHog's built-in views, which report the same `type` and — measured —
    /// are served by the same pinned-recordings sub-resource.
    var collections: [SessionRecordingPlaylist] {
        playlists
            .filter { $0.kind != .filters }
            .sorted {
                ($0.isSynthetic ? 1 : 0, $0.pinned ? 0 : 1, $0.name)
                    < ($1.isSynthetic ? 1 : 0, $1.pinned ? 0 : 1, $1.name)
            }
    }
}

/// Replay playlists: the project's saved filters and collections, plus the
/// built-in views PostHog injects into the same response.
///
/// A plain `View`, not a tab root: playlists belong inside the sessions area,
/// so this is meant to be pushed onto an existing navigation stack.
struct PlaylistsView: View {
    /// Hands a saved filter back to the sessions list. `nil` when there is no
    /// list behind this screen to hand one to.
    var onApplyFilter: ((SessionRecordingFilter) -> Void)?

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
            if !store.savedFilters.isEmpty {
                Section {
                    ForEach(store.savedFilters) { row($0) }
                } header: {
                    SectionLabel(text: "Saved filters", systemImage: "line.3.horizontal.decrease.circle", productMark: .session)
                } footer: {
                    Text("Stored queries. Each one is re-run when you open it, so what it holds changes as new sessions arrive.")
                }
            }

            if !store.collections.isEmpty {
                Section {
                    ForEach(store.collections) { row($0) }
                } header: {
                    SectionLabel(text: "Collections", systemImage: "rectangle.stack", productMark: .session)
                } footer: {
                    // Named as PostHog's, not the team's, because these appear in
                    // the same response and would otherwise read as playlists
                    // somebody created and forgot about.
                    Text("Fixed lists of recordings. The ones marked “PostHog” are maintained for every project and cannot be edited or deleted.")
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
        NavigationLink {
            PlaylistDetailView(playlist: playlist, onApplyFilter: onApplyFilter)
        } label: {
            PlaylistRowView(playlist: playlist)
        }
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
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
                // The section heading now carries the kind, so the pill is free
                // to carry the thing the heading cannot: whether this row is
                // PostHog's or the team's. Rows with no pill are the team's.
                accessory: playlist.isSynthetic ? .pill("PostHog", .secondary) : .none
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
        if playlist.isSynthetic { parts.append("maintained by PostHog") }
        if playlist.pinned { parts.append("pinned") }
        if let description = playlist.description { parts.append(description) }
        parts.append(playlist.countSummary)
        if let progress = playlist.watchedProgress {
            parts.append("\(progress.formatted(.percent.precision(.fractionLength(0)))) watched")
        }
        return parts.joined(separator: ", ")
    }
}
