import GetHogKit
import SwiftUI

/// The screen a link resolves to.
///
/// A link carries an id and nothing else, so every branch here has to resolve
/// the object itself — the same shape `FlagSearchDestination` and
/// `DetachedRecordingView` already use for the search index and a restored iPad
/// window. Between the link being written and being opened the object can have
/// been deleted, so "not found" is a normal outcome on all of them and each says
/// so in its own words rather than showing an empty screen.
struct LinkDestinationView: View {
    let link: PostHogLink

    var body: some View {
        switch link {
        case .dashboard(let id):
            DashboardDetailView(dashboardID: id)
        case .featureFlag(let id):
            FlagSearchDestination(flagID: id, key: nil)
        case .sessionRecording(let id):
            DetachedRecordingView(recordingID: id)
                .navigationTitle("Session")
                .navigationBarTitleDisplayMode(.inline)
        case .errorIssue(let id):
            ErrorIssueLinkDestination(issueID: id)
        case .screen, .insight:
            // Neither is ever pushed — a screen goes through `RootView.open(_:)`
            // and an insight has no screen at all, so it is refused before it
            // gets here. This branch exists to keep the switch honest.
            EmptyStateView(
                title: "Nothing to show",
                systemImage: "questionmark.square.dashed",
                message: "GetHog has no screen for this link."
            )
        }
    }
}

// MARK: - Error issue

/// One error issue, reached from nothing but its id.
///
/// There is no endpoint that fetches a single issue: PostHog answers error
/// tracking with a query over a period, so the only way to an issue is to ask
/// for the period and find it. That makes the period part of the honest answer —
/// an issue last seen four months ago is not missing, it is outside the window
/// this screen asked about, and saying "not found" without saying "in the last
/// 90 days" would be wrong.
struct ErrorIssueLinkDestination: View {
    let issueID: String

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var store = ErrorTrackingStore()

    /// The widest window the query offers. A link is usually followed long after
    /// it was written, so the narrow windows the Errors screen defaults to would
    /// turn a real issue into a false "not found".
    private let window: AnalyticsWindow = .quarter

    private var issue: ErrorIssue? { store.issues.first { $0.id == issueID } }

    var body: some View {
        Group {
            if let issue {
                ErrorIssueDetailView(issue: issue)
            } else if store.isLoading {
                ProgressView().controlSize(.large)
            } else if !model.isAvailable(.events) {
                LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                    Task { await model.refreshCapabilities() }
                }
            } else if let error = store.error {
                EmptyStateView(
                    title: "Couldn't load this issue",
                    systemImage: "exclamationmark.triangle",
                    message: error,
                    actionTitle: "Try again"
                ) {
                    Task { await load() }
                }
            } else {
                EmptyStateView(
                    title: "Issue not in this window",
                    systemImage: "questionmark.square.dashed",
                    message: "Nothing with this id was reported in \(window.spokenTitle.lowercased()) for \(model.selectedProject?.name ?? "this project"). It may have been resolved and aged out, or it may belong to another project.",
                    actionTitle: webURL == nil ? nil : "Open in PostHog",
                    action: webURL.map { url in { openURL(url) } }
                )
            }
        }
        .navigationTitle(issue?.name ?? "Error")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.projectID) { await load() }
    }

    private var webURL: URL? { model.webURL(path: "error_tracking/\(issueID)") }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, window: window, order: .lastSeen)
    }
}
