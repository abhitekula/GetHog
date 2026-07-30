import GetHogKit
import SwiftUI

@MainActor
@Observable
final class SessionsStore {
    var recordings: [SessionRecording] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var errorsOnly = false
    var minimumDuration: Double = 0

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<SessionRecording> = try await client.send(
                PostHogAPI.sessionRecordings(projectID: projectID, limit: 50)
            )
            recordings = page.results
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    func filtered(search: String) -> [SessionRecording] {
        recordings.filter { recording in
            if errorsOnly && !recording.hasErrors { return false }
            if (recording.recordingDuration ?? 0) < minimumDuration { return false }
            if !search.isEmpty {
                let haystack = [recording.personDisplayName, recording.startURL ?? ""]
                    .joined(separator: " ")
                if !haystack.localizedCaseInsensitiveContains(search) { return false }
            }
            return true
        }
    }
}

struct SessionsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = SessionsStore()
    @State private var selection: SessionRecording?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            content
                .navigationTitle("Sessions")
                .toolbar {
                    ProjectSwitcher()
                    ToolbarItem(placement: .topBarTrailing) { filterMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Playlists are saved views over these same recordings,
                        // so they live here rather than competing for a tab.
                        NavigationLink {
                            PlaylistsView()
                        } label: {
                            Image(systemName: "list.star")
                        }
                        .accessibilityLabel("Playlists")
                    }
                }
                .searchable(text: $search, prompt: "Search person or URL")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
        } detail: {
            if let selection {
                SessionDetailView(recording: selection).id(selection.id)
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "rectangle.stack",
                    description: Text("Pick a session to inspect its timeline.")
                )
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Errors only", isOn: Binding(
                get: { store.errorsOnly }, set: { store.errorsOnly = $0 }
            ))
            Picker("Minimum duration", selection: Binding(
                get: { store.minimumDuration }, set: { store.minimumDuration = $0 }
            )) {
                Text("Any").tag(0.0)
                Text("Over 30s").tag(30.0)
                Text("Over 2m").tag(120.0)
                Text("Over 10m").tag(600.0)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter sessions")
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.sessions) {
            LockedCapabilityView(capability: .sessions, scope: model.lockedScope(for: .sessions)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.recordings.isEmpty {
            EmptyStateView(
                title: "Couldn't load sessions",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.recordings.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No sessions",
                systemImage: "rectangle.stack",
                message: "No session recordings in this project yet."
            )
        } else {
            List(selection: $selection) {
                ForEach(store.filtered(search: search)) { recording in
                    NavigationLink(value: recording) {
                        SessionRowView(recording: recording)
                    }
                    .listRowBackground(
                        Theme.cardBackground
                            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                            .padding(.vertical, 1)
                    )
                    .listRowSeparator(.hidden)
                }
                FreshnessLabel(date: store.loadedAt)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listRowSpacing(Theme.Space.xs)
            .pageSurface()
            .skeleton(store.isLoading && store.recordings.isEmpty)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

struct SessionRowView: View {
    let recording: SessionRecording

    var body: some View {
        DataRow(
            glyph: glyph,
            tint: tint,
            title: recording.personDisplayName,
            subtitle: recording.pathComponent,
            footnote: stats,
            // The start URL's path is an identifier, and a column of aligned
            // paths is what makes one session's entry point comparable to the
            // next one's.
            isSubtitleMonospaced: true,
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The glyph carries whatever is unusual about the session — errors first,
    /// then the mobile recordings this app cannot play — so the list can be
    /// triaged by shape before a name is read.
    private var glyph: String {
        if recording.hasErrors { return "exclamationmark.triangle.fill" }
        if !recording.isReplayable { return "iphone" }
        return "play.rectangle"
    }

    private var tint: Color {
        recording.hasErrors ? Theme.Status.critical : Theme.accent
    }

    /// Duration, activity and the caveats on the row's one caption line. The
    /// error count used to be a bare number behind a red triangle, so it says
    /// "errors" now; and the order puts what is worth acting on ahead of the
    /// timestamp, which is the part that gets truncated away first.
    private var stats: String {
        var parts = [recording.durationText, "\(recording.clickCount) clicks"]
        if recording.hasErrors { parts.append("\(recording.consoleErrorCount) errors") }
        // Set expectations in the list, not after a failed load.
        if !recording.isReplayable { parts.append("Mobile, not playable") }
        if let start = recording.startTime {
            parts.append(start.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var parts = [
            recording.personDisplayName,
            "duration \(recording.durationText)",
            "\(recording.clickCount) clicks",
        ]
        if recording.hasErrors { parts.append("\(recording.consoleErrorCount) console errors") }
        if !recording.isReplayable { parts.append("mobile recording, not playable") }
        return parts.joined(separator: ", ")
    }
}
