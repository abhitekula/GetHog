import GetHogKit
import GetHogUI
import SwiftUI

/// The recordings behind one playlist.
///
/// ## The two kinds are fetched by completely different means
///
/// The two public resource shapes require different loading paths:
///
/// * A **collection** is static — the recordings somebody pinned. They come
///   from `GET /session_recording_playlists/{short_id}/recordings/`, which
///   returns exactly the pinned rows and nothing else.
/// * A **saved filter** is dynamic — a stored query, re-run every time it is
///   opened. That same sub-resource answers `200` with `{"results": [],
///   "has_next": false}` for one, because a saved filter pins nothing. Reading
///   that as "empty" would show a populated saved filter as blank forever.
///   Its contents come from replaying its stored `filters` blob against the
///   recordings endpoint instead.
///
/// Built-in playlists typed as `collection` take the pinned sub-resource path
/// too.
struct PlaylistDetailView: View {
    let playlist: SessionRecordingPlaylist
    /// Hands the saved filter back to the sessions list. `nil` when this screen
    /// was reached from somewhere with no list to hand it to.
    var onApplyFilter: ((SessionRecordingFilter) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = PlaylistContentsStore()

    var body: some View {
        content
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task(id: "\(model.projectID ?? 0)|\(playlist.id)") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.recordings.isEmpty {
            EmptyStateView(
                title: "Couldn't open this playlist",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: store.isRetryable ? "Try again" : nil,
                action: store.isRetryable ? { Task { await load() } } : nil
            )
        } else {
            list
        }
    }

    /// The header and the apply button stay on screen when the result is empty.
    /// They used to be in the branch that an empty result replaced, which took
    /// away the explanation of what this playlist *is* and the way to widen it
    /// at exactly the moment both were wanted.
    private var list: some View {
        List {
            Section {
                if store.recordings.isEmpty && !store.isLoading {
                    emptyRow
                }
                ForEach(store.recordings) { recording in
                    NavigationLink {
                        SessionDetailView(recording: recording)
                    } label: {
                        SessionRowView(recording: recording)
                    }
                    .listRowBackground(
                        Theme.cardBackground
                            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                            .padding(.vertical, 1)
                    )
                    .listRowSeparator(.hidden)
                }
            } header: {
                header
            }

            if playlist.kind == .filters, let filter = playlist.recordingFilter,
               let onApplyFilter {
                Section {
                    Button {
                        onApplyFilter(filter)
                        dismiss()
                    } label: {
                        Label("Use these filters in Sessions", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .minimumHitTarget()
                } footer: {
                    Text("Applies the saved filter to the session list, where you can widen or narrow it.")
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.recordings.isEmpty)
    }

    /// Says which of the two things this playlist is, in a sentence, because the
    /// difference decides whether the list will change on its own tomorrow.
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: playlist.kind.title, systemImage: playlist.kind.systemImage)
            Text(kindExplanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)

            // An untranslated clause makes the result *wider*, which looks
            // exactly like the filter working. Said out loud for that reason.
            if !playlist.untranslatedClauses.isEmpty {
                Label(
                    "Not applied here: \(playlist.untranslatedClauses.joined(separator: ", ")). This list is wider than the saved filter.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Status.warningInk)
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, Theme.Space.xs)
    }

    private var kindExplanation: String {
        switch playlist.kind {
        case .filters:
            "A stored query, re-run each time it is opened. What it holds changes as new sessions arrive."
        case .collection:
            playlist.isSynthetic
                ? "A view PostHog maintains for every project. Its contents are chosen by PostHog, not pinned by anyone here."
                : "Recordings somebody added by hand. It changes only when somebody changes it."
        case .unknown:
            "PostHog did not say what kind of playlist this is."
        }
    }

    /// Empty is a normal, meaningful state for both kinds, and it means
    /// different things — so it says which.
    ///
    /// A saved filter's empty answer is especially easy to misread: the pinned
    /// sub-resource returns `[]` for one whether or not its query matches
    /// anything, which is why this screen never asks that endpoint about a saved
    /// filter at all.
    private var emptyRow: some View {
        SectionEmptyState(
            text: playlist.kind == .filters
                ? "This saved filter's query ran and matched no recordings."
                : "Nothing has been pinned to this collection. Recordings are added from the PostHog web console.",
            systemImage: playlist.kind == .filters
                ? "line.3.horizontal.decrease.circle"
                : "pin.slash",
            actionTitle: "Try again",
            action: { Task { await load() } }
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(playlist: playlist, client: client, projectID: projectID)
    }
}

@MainActor
@Observable
final class PlaylistContentsStore {
    var recordings: [SessionRecording] = []
    var isLoading = false
    var error: String?
    var isRetryable = true
    var loadedAt: Date?

    func load(
        playlist: SessionRecordingPlaylist,
        client: PostHogClient,
        projectID: Int
    ) async {
        isLoading = true
        defer { isLoading = false }

        // The kind decides the request. A saved filter asked for its pinned
        // rows would always answer with none.
        let endpoint: Endpoint = if let filter = playlist.recordingFilter {
            PostHogAPI.sessionRecordings(projectID: projectID, limit: 50, filter: filter)
        } else {
            PostHogAPI.playlistRecordings(projectID: projectID, shortID: playlist.id, limit: 50)
        }

        do {
            let list: RecordingList = try await client.send(endpoint)
            recordings = list.results
            loadedAt = Date()
            error = nil
        } catch let failure as PostHogError {
            recordings = []
            error = failure.hasReadableDescription
                ? failure.localizedDescription
                : "PostHog's answer did not have the shape this screen expects."
            isRetryable = failure.isRetryable
        } catch {
            recordings = []
            self.error = error.localizedDescription
            isRetryable = true
        }
    }
}
