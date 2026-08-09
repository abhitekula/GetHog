import GetHogKit
import Observation
import SwiftUI

/// What a torn-off iPad window shows.
///
/// Carries identifiers only, never a decoded model. iPadOS persists this value
/// and hands it back after a relaunch, so a serialised copy of a dashboard would
/// return as whatever the numbers were when the window was last open — a window
/// that silently lies about being live. Re-fetching from an id is the only
/// version that stays honest across restoration.
///
/// The title is deliberately *not* part of the value either: `WindowGroup`
/// identifies windows by equality, so folding a mutable title into the case
/// would open a second window for the same dashboard the moment it was renamed.
enum WindowTarget: Codable, Hashable {
    case dashboard(id: Int)
    case recording(id: String)
}

/// Hosts whatever a secondary window was opened for.
///
/// Secondary windows share the app's single `AppModel`, so they share one
/// client, one rate-limit governor and one cache. A window that built its own
/// stack would double this app's share of an organisation-wide request budget.
struct DetachedWindowView: View {
    let target: WindowTarget?

    var body: some View {
        NavigationStack {
            switch target {
            case .dashboard(let id):
                DashboardDetailView(dashboardID: id)
            case .recording(let id):
                DetachedRecordingView(recordingID: id)
            case nil:
                ContentUnavailableView(
                    "Nothing to show",
                    systemImage: "macwindow",
                    description: Text("This window was opened without a target.")
                )
            }
        }
    }
}

/// One authoritative state for a recording detached from its source list.
///
/// The numeric project id cannot establish authority by itself: ids may repeat
/// between PostHog regions, and replacing a credential must invalidate work
/// started by the prior authentication epoch.
@MainActor
@Observable
final class DetachedRecordingStore {
    enum State: Equatable {
        case waitingForSession
        case loading(FlagWriteScope)
        case loaded(FlagWriteScope, SessionRecording)
        case failed(FlagWriteScope, String)
    }

    private(set) var state: State = .waitingForSession
    private var generation: UInt64 = 0

    func load(
        client: PostHogClient?,
        recordingID: String,
        scope: FlagWriteScope?
    ) async {
        generation &+= 1
        let loadGeneration = generation

        guard
            let client,
            let scope,
            let projectRegion = scope.projectRegion,
            client.region == projectRegion
        else {
            state = .waitingForSession
            return
        }

        state = .loading(scope)

        do {
            let recording: SessionRecording = try await client.send(
                PostHogAPI.sessionRecording(
                    projectID: scope.projectID,
                    recordingID: recordingID
                )
            )
            guard
                generation == loadGeneration,
                currentScope == scope,
                !Task.isCancelled
            else { return }
            state = .loaded(scope, recording)
        } catch {
            guard
                generation == loadGeneration,
                currentScope == scope,
                !Task.isCancelled
            else { return }
            let message = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
            state = .failed(scope, message)
        }
    }

    private var currentScope: FlagWriteScope? {
        switch state {
        case .waitingForSession:
            nil
        case .loading(let scope), .loaded(let scope, _), .failed(let scope, _):
            scope
        }
    }
}

/// Every value that can change which recording request is authoritative.
struct DetachedRecordingTaskID: Hashable {
    let recordingID: String
    let projectID: Int?
    let projectRegion: PostHogRegion?
    let authSessionID: UUID?

    init(recordingID: String, scope: FlagWriteScope?) {
        self.recordingID = recordingID
        projectID = scope?.projectID
        projectRegion = scope?.projectRegion
        authSessionID = scope?.authSessionID
    }
}

/// Resolves a recording id back into the full record the detail screen needs.
///
/// The list screen already holds decoded recordings, but a restored window only
/// has the id, so this path has to exist regardless.
struct DetachedRecordingView: View {
    let recordingID: String

    @Environment(AppModel.self) private var model
    @State private var store = DetachedRecordingStore()

    var body: some View {
        Group {
            switch store.state {
            case .waitingForSession, .loading:
                ProgressView("Loading recording…")
                    .controlSize(.large)
            case .loaded(_, let recording):
                SessionDetailView(recording: recording)
            case .failed(_, let error):
                ContentUnavailableView {
                    Label("Couldn't load this recording", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            }
        }
        .task(
            id: DetachedRecordingTaskID(
                recordingID: recordingID,
                scope: model.flagWriteScope
            )
        ) {
            await load()
        }
    }

    private func load() async {
        let client = model.client
        let scope = model.flagWriteScope
        await store.load(client: client, recordingID: recordingID, scope: scope)
    }
}
