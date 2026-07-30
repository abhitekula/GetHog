import GetHogKit
import SwiftUI

/// Loading for the three "what needs my attention" surfaces.
///
/// One file because the three stores are the same shape — fetch a page, keep an
/// error string, stamp the load — and three near-identical files would be three
/// places to fix the same bug. The screens differ; the loading does not.
///
/// A generic store was tried and rejected: `Page<T>` decoding plus the
/// per-resource sort each screen needs put the type parameters in the view
/// layer, which is exactly where they are least useful.

@MainActor
@Observable
final class InboxStore {
    var tasks: [AgentTask] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<AgentTask> = try await client.send(
                PostHogAPI.tasks(projectID: projectID)
            )
            // The list has no archived rows to filter — see `PostHogAPI.tasks`,
            // where the missing archive parameter is documented — but the field
            // is honoured rather than ignored in case that changes.
            tasks = page.results.filter { !$0.archived }
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class SignalsStore {
    var reports: [SignalReport] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<SignalReport> = try await client.send(
                PostHogAPI.signalReports(projectID: projectID)
            )
            reports = page.results
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Grouped by status, decisions first.
    var grouped: [(status: SignalReportStatus, reports: [SignalReport])] {
        Dictionary(grouping: reports, by: \.status)
            .sorted { $0.key.rank < $1.key.rank }
            .map { ($0.key, $0.value) }
    }
}

@MainActor
@Observable
final class HealthStore {
    var issues: [HealthIssue] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<HealthIssue> = try await client.send(
                PostHogAPI.healthIssues(projectID: projectID)
            )
            issues = page.results.sorted(by: HealthIssue.mostUrgentFirst)
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    var active: [HealthIssue] { issues.filter { $0.status == .active } }
    var resolved: [HealthIssue] { issues.filter { $0.status != .active } }

    /// Drives the tab badge. Only critical *and* still active counts —
    /// badging a resolved issue trains people to ignore the badge.
    var criticalCount: Int {
        active.filter { $0.severity == .critical }.count
    }
}
