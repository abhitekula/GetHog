import GetHogKit
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

/// Resolves a recording id back into the full record the detail screen needs.
///
/// The list screen already holds decoded recordings, but a restored window only
/// has the id, so this path has to exist regardless.
struct DetachedRecordingView: View {
    let recordingID: String

    @Environment(AppModel.self) private var model
    @State private var recording: SessionRecording?
    @State private var error: String?

    var body: some View {
        Group {
            if let recording {
                SessionDetailView(recording: recording)
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't load this recording", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else {
                ProgressView("Loading recording…")
                    .controlSize(.large)
            }
        }
        // Keyed on the project as well as the recording, because the guard in
        // `load()` returns silently when there is no client yet and nothing
        // else would ever retry it. A window restored at launch mounts before
        // the app's `bootstrap()` has resolved one — measured through the
        // solo-window route, where `GETHOG_SOLO_RECORDING` sat on "Loading
        // recording…" for the life of the window. Adding the project id to the
        // task's identity re-runs the load the moment bootstrap lands one.
        .task(id: [recordingID, model.projectID.map(String.init) ?? ""]) { await load() }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        do {
            recording = try await client.send(
                PostHogAPI.sessionRecording(projectID: projectID, recordingID: recordingID)
            )
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}
