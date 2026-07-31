import Foundation
import Observation
import GetHogKit

struct ErrorTriageMessage: Identifiable, Equatable {
    enum Kind { case failure, notice }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// Owns every write to an error tracking issue, plus the optimistic state those
/// writes imply.
///
/// Modelled deliberately closely on `FlagToggleController`, which was the app's
/// only write until this file existed. Same three commitments:
///
/// * `ErrorIssue` stays immutable and is exactly what the API last said. An
///   in-flight or just-applied change lives here as an override, so there is one
///   source of truth for "what does the server believe" and rollback is honest
///   rather than a guess.
/// * Nothing in here asks the user anything. Callers show the confirmation
///   dialog first; see `ErrorIssueDetailView`.
/// * A refresh wins. `reconcile(with:)` drops overrides that a fresh fetch has
///   spoken for, so a stale local override cannot outlive its write and
///   misreport a colleague's change.
///
/// The one thing it does *not* copy is the biometric gate. `BiometricGate` exists
/// for flag flips because a flag flip changes what production serves to users
/// right now. Triage does not: resolving an issue relabels a row, and even
/// suppression only changes what is collected from here on. Putting Face ID in
/// front of "Resolve" would train people to authenticate reflexively, which is
/// exactly what makes the gate on the flag screen worth less.
@MainActor
@Observable
final class ErrorTriageController {

    /// Issue id → the status we believe it is in after our own write.
    private(set) var statusOverrides: [String: ErrorIssueStatus] = [:]
    /// Issue id → the assignee we believe it has. The outer optional is
    /// "have we written one", the inner is "is it assigned to anybody" — an
    /// unassign is a write whose result is `nil`, and collapsing the two would
    /// make it indistinguishable from not having written at all.
    private(set) var assigneeOverrides: [String: ErrorIssueAssignee?] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var message: ErrorTriageMessage?

    /// Monotonic counters drive `.sensoryFeedback`; two issues resolved in a row
    /// must still each produce a tap.
    private(set) var successCount = 0
    private(set) var failureCount = 0

    /// Not a `Capability.writeScope`: error tracking has no `Capability` case of
    /// its own — the screen is gated on `.events`, because it is served by
    /// `/query/` — and inventing one would change what onboarding asks every user
    /// to tick. Named here so the 403 path can still be specific.
    let requiredWriteScope = "error_tracking:write"

    func isBusy(_ issue: ErrorIssue) -> Bool { inFlight.contains(issue.id) }

    func dismissMessage() { message = nil }

    /// The issue as the screen should draw it: the server's copy, with anything
    /// we have written since laid over the top.
    func effective(_ issue: ErrorIssue) -> ErrorIssue {
        var result = issue
        if let status = statusOverrides[issue.id] {
            result = result.withStatus(status)
        }
        if let assignee = assigneeOverrides[issue.id] {
            result = result.withAssignee(assignee)
        }
        return result
    }

    func effectiveStatus(_ issue: ErrorIssue) -> String {
        statusOverrides[issue.id]?.rawValue ?? issue.status
    }

    func effectiveAssignee(_ issue: ErrorIssue) -> ErrorIssueAssignee? {
        if let override = assigneeOverrides[issue.id] { return override }
        return issue.assignee
    }

    // MARK: - Writes

    /// Applies a confirmed status change.
    ///
    /// Callers must have shown the confirmation dialog already — and for
    /// `.suppressed`, the *stronger* one, because that is the only value here
    /// that changes what PostHog stores rather than how a row is labelled.
    func setStatus(
        _ desired: ErrorIssueStatus,
        issue: ErrorIssue,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard !inFlight.contains(issue.id) else { return }
        message = nil

        let previous = statusOverrides[issue.id]
        statusOverrides[issue.id] = desired
        inFlight.insert(issue.id)
        defer { inFlight.remove(issue.id) }

        do {
            _ = try await client.data(
                for: PostHogAPI.setErrorIssueStatus(
                    projectID: projectID,
                    issueID: issue.id,
                    status: desired
                )
            )
            successCount += 1
            if desired == .resolved {
                // Stated after the fact as well as before it. PostHog reopens a
                // resolved issue by itself when it recurs, and someone who
                // resolved this from a phone will not be watching the list when
                // it comes back.
                message = ErrorTriageMessage(
                    kind: .notice,
                    text: "Resolved. PostHog reopens this automatically if the error happens again."
                )
            }
        } catch {
            statusOverrides[issue.id] = previous
            failureCount += 1
            message = failureMessage(for: error, issue: issue, action: verb(for: desired))
        }
    }

    /// Applies a confirmed assignment, or clears one when `assignee` is `nil`.
    func setAssignee(
        _ assignee: ErrorIssueAssignee?,
        issue: ErrorIssue,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard !inFlight.contains(issue.id) else { return }
        message = nil

        let previous = assigneeOverrides[issue.id]
        assigneeOverrides[issue.id] = .some(assignee)
        inFlight.insert(issue.id)
        defer { inFlight.remove(issue.id) }

        do {
            _ = try await client.data(
                for: PostHogAPI.assignErrorIssue(
                    projectID: projectID,
                    issueID: issue.id,
                    assignee: assignee
                )
            )
            successCount += 1
        } catch {
            assigneeOverrides[issue.id] = previous
            failureCount += 1
            message = failureMessage(
                for: error,
                issue: issue,
                action: assignee == nil ? "unassign" : "assign"
            )
        }
    }

    /// Drops overrides once a fresh fetch has spoken for the same issues.
    ///
    /// Whoever else changed the issue in the web console wins, for the reason
    /// the flag controller gives: a stale local override that outlives its write
    /// quietly misreports the real state.
    func reconcile(with issues: [ErrorIssue]) {
        let settled = Set(issues.map(\.id)).subtracting(inFlight)
        statusOverrides = statusOverrides.filter { !settled.contains($0.key) }
        assigneeOverrides = assigneeOverrides.filter { !settled.contains($0.key) }
    }

    // MARK: - Failures

    private func verb(for status: ErrorIssueStatus) -> String {
        switch status {
        case .active: "reopen"
        case .resolved: "resolve"
        case .suppressed: "suppress"
        }
    }

    private func failureMessage(
        for error: any Error,
        issue: ErrorIssue,
        action: String
    ) -> ErrorTriageMessage {
        var text = "Couldn't \(action) \(issue.name). \(error.localizedDescription)"

        if let posthogError = error as? PostHogError {
            switch posthogError {
            case .forbidden:
                // A read-scoped key passes every preflight probe — error tracking
                // is gated on `query:read`, which it has — and only fails here.
                // This is the first moment the user can learn what to tick.
                //
                // This branch used to hand-roll the same sentence `WriteFailure`
                // did, binding nothing and asserting `requiredWriteScope` for
                // every 403. Both were wrong the same way and were found
                // together; the classification now defers to the shared helper
                // so the two cannot drift again.
                //
                // Only the text is taken. `ErrorTriageMessage` is a *separate*
                // struct from `WriteOutcomeMessage` — deliberately, per the note
                // on `WriteOutcomeMessage`: error-tracking writes do not pass
                // through PostHog's approval gate, so this type has no `.filed`
                // case and must not gain one. `WriteFailure.message` cannot
                // return `.filed` for a `.forbidden` input, so the two `Kind`s
                // agree on every value that can reach here.
                text = WriteFailure.message(
                    for: posthogError,
                    object: issue.name,
                    action: action,
                    writeScope: requiredWriteScope
                ).text
            case .unauthorized:
                text = "Couldn't \(action) \(issue.name): your API key was rejected. Reconnect in Settings."
            default:
                text = "Couldn't \(action) \(issue.name). \(posthogError.localizedDescription)"
            }
        }

        return ErrorTriageMessage(kind: .failure, text: text)
    }
}

/// Loads the newest exception occurrence for one issue.
///
/// Separate from `ErrorTrackingStore` because it is a different request with a
/// different lifetime: the list is one query per project-and-window, this is one
/// query per issue opened, and folding them together would either refetch every
/// stack on a sort change or hold stale frames after one.
@MainActor
@Observable
final class ExceptionStackStore {
    private(set) var occurrence: ExceptionOccurrence?
    private(set) var isLoading = false
    private(set) var error: String?
    /// Set when the query succeeded and simply found nothing. Distinct from
    /// `error`: "PostHog has no stored exception for this issue in its own
    /// window" is an answer, and showing it as a failure would be a lie.
    private(set) var isEmpty = false

    private var loadedIssueID: String?

    func load(client: PostHogClient, projectID: Int, issue: ErrorIssue) async {
        guard loadedIssueID != issue.id || (occurrence == nil && error == nil && !isEmpty) else {
            return
        }
        loadedIssueID = issue.id
        isLoading = true
        isEmpty = false
        error = nil
        defer { isLoading = false }

        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.errorIssueOccurrence(
                    projectID: projectID,
                    issueID: issue.id,
                    within: Self.window(for: issue)
                )
            )
            occurrence = ExceptionOccurrence.first(in: response)
            isEmpty = occurrence == nil
        } catch {
            occurrence = nil
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// The issue's own lifetime, which is the tightest bound that cannot exclude
    /// its own events.
    ///
    /// `first_seen` is always present on the list query; `last_seen` is too, but
    /// both are treated as optional here because the REST issue endpoint returns
    /// only the first. The fallbacks widen rather than narrow — a query that
    /// runs slowly is recoverable, one that cannot see the event is not.
    static func window(for issue: ErrorIssue) -> ClosedRange<Date> {
        let end = issue.lastSeen ?? Date()
        let start = issue.firstSeen ?? end.addingTimeInterval(-90 * 86_400)
        return start <= end ? start...end : end...start
    }
}
