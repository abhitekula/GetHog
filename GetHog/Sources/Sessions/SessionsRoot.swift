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
            ContentUnavailableView {
                Label("Couldn't load sessions", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.recordings.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No sessions",
                systemImage: "rectangle.stack",
                description: Text("No session recordings in this project yet.")
            )
        } else {
            List(selection: $selection) {
                ForEach(store.filtered(search: search)) { recording in
                    NavigationLink(value: recording) {
                        SessionRowView(recording: recording)
                    }
                }
                FreshnessLabel(date: store.loadedAt).listRowBackground(Color.clear)
            }
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
        HStack(spacing: 12) {
            Text(recording.person?.initials ?? "?")
                .font(.caption.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.15), in: .circle)
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(recording.personDisplayName)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text(recording.durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(recording.pathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Label("\(recording.clickCount)", systemImage: "hand.tap")
                    if recording.hasErrors {
                        Label("\(recording.consoleErrorCount)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Status.critical)
                    }
                    if !recording.isReplayable {
                        // Set expectations in the list, not after a failed load.
                        Label("Mobile", systemImage: "iphone")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let start = recording.startTime {
                        Text(start, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
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
