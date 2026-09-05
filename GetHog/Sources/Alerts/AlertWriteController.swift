import Foundation
import Observation
import GetHogKit

/// Owns every write to one of PostHog's **own** alerts, plus the optimistic
/// state those writes imply.
///
/// Modelled on `FlagToggleController`, which is this app's whole vocabulary for a
/// mutation, and it keeps the same three commitments:
///
/// * **Nothing in here asks the user anything.** The caller has already shown a
///   confirmation dialog naming the alert and the direction. See
///   `InsightAlertsView`.
/// * **Optimistic apply with rollback.** `InsightAlert` is immutable and comes
///   straight from the API, so a just-applied change lives here as an override
///   rather than being written back into the decoded model — one source of truth
///   for "what did the server last tell us", which is what makes the rollback
///   honest.
/// * **Never a swipe action.** Every control that reaches this class is a labelled
///   button or a menu item.
///
/// No biometric gate, for `AnnotationComposer`'s reason. `BiometricGate` exists
/// because flipping a feature flag changes what production serves to users right
/// now. Silencing an alert for four hours changes who gets an e-mail. Putting
/// Face ID in front of that would train people to authenticate reflexively, which
/// is what makes the gate on the flag screen worth having.
///
/// **Nothing here is exercised against a tenant by the test suite.** Requests
/// are unit-tested with deterministic synthetic data, and demo routes provide
/// the only response shapes used by automated tests.
@MainActor
@Observable
final class AlertWriteController {

    /// Alert id → the snooze end we believe applies after our own write.
    ///
    /// A `Date??`, and the double optional is load-bearing rather than clever:
    /// the outer layer is "did we write this alert", the inner is "is it snoozed".
    /// One level would make "we unsnoozed it" indistinguishable from "we never
    /// touched it", and the row would keep drawing the server's stale end time
    /// under a button the user had just pressed.
    ///
    /// The *value* written is this app's estimate, and the estimate is
    /// deliberately conservative — see `AlertSnooze` for why `"1d"` does not mean
    /// twenty-four hours. It survives only until the next fetch replaces it.
    private(set) var snoozeOverrides: [String: Date?] = [:]
    /// Alert id → the enabled state we believe applies after our own write.
    private(set) var enabledOverrides: [String: Bool] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var message: WriteOutcomeMessage?

    /// Monotonic counters drive `.sensoryFeedback`; two alerts snoozed the same
    /// way in a row must still each produce a tap. `filedCount` is separate
    /// because a change request waiting for approval is neither a success nor a
    /// failure.
    private(set) var successCount = 0
    private(set) var failureCount = 0
    private(set) var filedCount = 0

    /// Alerts created in this session, newest first, so the list shows the one
    /// the user just wrote without spending a second request to re-list.
    private(set) var created: [InsightAlert] = []

    /// `AlertViewSet.scope_object = "alert"`, so PostHog's own scope name for
    /// these writes is `alert:write`. Not a `Capability.writeScope`: alerts have
    /// no `Capability` case of their own — the screens are gated on `.dashboards`,
    /// because an alert watches an insight — and inventing one would change what
    /// onboarding asks every user to tick.
    let requiredWriteScope = APIKeyScopeGuidance.optionalWriteDescriptor(for: .alerts).scope

    func dismissMessage() { message = nil }

    func isBusy(_ alert: InsightAlert) -> Bool { inFlight.contains(alert.id) }

    /// The snooze end this app believes applies, with our own write laid over the
    /// server's answer.
    func effectiveSnoozedUntil(_ alert: InsightAlert) -> Date? {
        if let written = snoozeOverrides[alert.id] { return written }
        return alert.snoozedUntil
    }

    func effectiveEnabled(_ alert: InsightAlert) -> Bool {
        enabledOverrides[alert.id] ?? alert.enabled
    }

    func isSnoozed(_ alert: InsightAlert, now: Date = Date()) -> Bool {
        guard let until = effectiveSnoozedUntil(alert) else { return false }
        return until > now
    }

    // MARK: - Snooze

    /// Applies a confirmed snooze, or clears one.
    ///
    /// One `.crud` PATCH, and no recurring cost — this is the request the whole
    /// feature exists for. An alert fires while you are not at a desk; you want
    /// it quiet until tomorrow.
    func setSnoozed(
        _ snooze: AlertSnooze?,
        alert: InsightAlert,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard !inFlight.contains(alert.id) else { return }
        guard let endpoint = PostHogAPI.setAlertSnoozed(
            projectID: projectID, alertID: alert.id, until: snooze
        ) else {
            failureCount += 1
            message = WriteOutcomeMessage(
                kind: .failure,
                text: "Couldn't build the request to snooze \(alert.displayTitle). Nothing was sent."
            )
            return
        }

        message = nil
        let previous = snoozeOverrides[alert.id]
        // The optimistic value is this app's *estimate* of where PostHog will
        // land, and the row says so rather than printing it as fact — see
        // `InsightAlertsView.snoozeLine`. The server truncates: `"4h"` lands on
        // the start of the hour, `"1d"` on the start of the next UTC day, so an
        // estimate computed here by plain addition would be up to an hour or a
        // day early. It is used to decide *whether* the alert is snoozed, never
        // to state a time as PostHog's.
        snoozeOverrides[alert.id] = snooze.map { Self.estimatedEnd(of: $0) } ?? Date?.none
        inFlight.insert(alert.id)
        defer { inFlight.remove(alert.id) }

        do {
            _ = try await client.data(for: endpoint)
            successCount += 1
        } catch {
            if let previous {
                snoozeOverrides[alert.id] = previous
            } else {
                snoozeOverrides[alert.id] = nil
            }
            record(
                error,
                object: alert.displayTitle,
                action: snooze == nil ? "wake" : "snooze",
                remedy: writeRemedy(for: client)
            )
        }
    }

    /// Where a snooze *approximately* ends, for deciding whether the alert is
    /// currently quiet.
    ///
    /// Deliberately never rendered as a time. PostHog parses the duration with
    /// `always_truncate=True`, so the real end is earlier than this by up to an
    /// hour (hour units) or a day (`"1d"`). Overstating it is the safe direction
    /// for the one decision it drives — the alert is treated as snoozed for
    /// slightly longer than it is, so the row offers "Wake it up" rather than
    /// silently reverting to a snooze button.
    private static func estimatedEnd(of snooze: AlertSnooze, from now: Date = Date()) -> Date {
        switch snooze {
        case .oneHour: now.addingTimeInterval(3600)
        case .fourHours: now.addingTimeInterval(4 * 3600)
        case .eightHours: now.addingTimeInterval(8 * 3600)
        case .tomorrow: now.addingTimeInterval(24 * 3600)
        }
    }

    // MARK: - Enable

    /// Starts or stops evaluation. A separate call from a snooze because it is a
    /// separate thing: a snooze expires by itself, a pause does not.
    func setEnabled(
        _ enabled: Bool,
        alert: InsightAlert,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard !inFlight.contains(alert.id) else { return }
        guard let endpoint = PostHogAPI.setAlertEnabled(
            projectID: projectID, alertID: alert.id, enabled: enabled
        ) else {
            failureCount += 1
            message = WriteOutcomeMessage(
                kind: .failure,
                text: "Couldn't build the request to change \(alert.displayTitle). Nothing was sent."
            )
            return
        }

        message = nil
        let previous = enabledOverrides[alert.id]
        enabledOverrides[alert.id] = enabled
        inFlight.insert(alert.id)
        defer { inFlight.remove(alert.id) }

        do {
            _ = try await client.data(for: endpoint)
            successCount += 1
        } catch {
            enabledOverrides[alert.id] = previous
            record(
                error,
                object: alert.displayTitle,
                action: enabled ? "start" : "pause",
                remedy: writeRemedy(for: client)
            )
        }
    }

    // MARK: - Create

    /// Writes a confirmed alert.
    ///
    /// - Returns: whether the alert now exists on PostHog. The composer stays open
    ///   on `false` so the threshold the user typed is still there to retry with.
    ///
    /// Unlike the two writes above there is nothing to roll *back* — the object
    /// did not exist before — so the optimistic state is an insertion into
    /// `created`, made only on success. An alert row that appeared and then
    /// vanished would be indistinguishable from a bug in the list, and this list
    /// is short enough that waiting for the answer costs nothing.
    @discardableResult
    func create(
        _ draft: AlertDraft,
        insightTitle: String,
        client: PostHogClient,
        projectID: Int
    ) async -> Bool {
        let key = "create-\(draft.insightID)"
        guard !inFlight.contains(key) else { return false }
        guard let endpoint = PostHogAPI.createAlert(projectID: projectID, draft: draft) else {
            failureCount += 1
            message = WriteOutcomeMessage(
                kind: .failure,
                text: """
                    Couldn't set an alert on \(insightTitle): the alert needs a name and at least \
                    one person to tell. Nothing was sent.
                    """
            )
            return false
        }

        message = nil
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let alert: InsightAlert = try await client.send(endpoint)
            created.insert(alert, at: 0)
            successCount += 1
            return true
        } catch PostHogError.decoding(let detail) {
            // The write very likely landed. PostHog answers a create with the
            // created object, so a decode failure means the alert probably exists
            // and this app could not read it back — the one failure where
            // "it wasn't saved" would be the wrong thing to say. Same wording as
            // `AnnotationComposer`'s, for the same reason.
            failureCount += 1
            message = WriteOutcomeMessage(
                kind: .failure,
                text: """
                    The alert may have been set — PostHog answered, but not in a shape this app \
                    could read. Pull to refresh to see whether it is there. (\(detail))
                    """
            )
            return false
        } catch {
            record(error, object: "an alert on \(insightTitle)", action: "set", remedy: writeRemedy(for: client))
            return false
        }
    }

    // MARK: - Reconciliation

    /// Drops overrides once a fresh fetch has spoken for the same alerts.
    ///
    /// Whoever else changed the alert in the web console wins: a stale local
    /// override that outlived its write would quietly misreport whether somebody
    /// is being e-mailed.
    func reconcile(with alerts: [InsightAlert]) {
        let settled = Set(alerts.map(\.id)).subtracting(inFlight)
        snoozeOverrides = snoozeOverrides.filter { !settled.contains($0.key) }
        enabledOverrides = enabledOverrides.filter { !settled.contains($0.key) }
        // A created alert that the server has now listed is no longer this
        // session's business; keeping both would draw it twice.
        let listed = Set(alerts.map(\.id))
        created.removeAll { listed.contains($0.id) }
    }

    /// Turns a thrown error into what the reader is told, and bumps whichever
    /// counter is honest about it.
    ///
    /// Delegates to `WriteFailure`, which is where this app's 403/409 reasoning
    /// lives — including the one case that is not a failure at all, a change
    /// request filed under an organisation approval policy.
    private func record(_ error: any Error, object: String, action: String, remedy: WriteRemedy = .personalKey) {
        let outcome = WriteFailure.message(
            for: error,
            object: object,
            action: action,
            writeScope: requiredWriteScope,
            remedy: remedy
        )
        if outcome.kind == .filed { filedCount += 1 } else { failureCount += 1 }
        message = outcome
    }
}
