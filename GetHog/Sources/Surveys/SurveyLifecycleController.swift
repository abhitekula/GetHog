import Foundation
import Observation
import GetHogKit

/// Owns every write to a survey, plus the optimistic state those writes imply.
///
/// Same three commitments as the app's older writes — an immutable `Survey`, no
/// question asked in here, and a fresh fetch wins. See
/// `ExperimentLifecycleController` for the long form.
///
/// ## The override is over *dates*, because there is no status to override
///
/// A survey carries no `status` field. Measured: `GET /surveys/` returns 37 keys
/// for each of this project's six surveys and none of them is one. Running means
/// `start_date` set, `end_date` unset, not archived — PostHog's own
/// `_should_survey_flags_be_active` is that exact expression, and
/// `Survey.statusText` derives the same four words the same way. The four words
/// are the client's invention, and there is no server value for them to disagree
/// with.
///
/// So this controller overrides the two dates and lets `Survey.statusText` derive
/// the word, rather than overriding the word directly. Overriding the word would
/// put a second, divergent definition of "Running" in the app — one derived from
/// dates for surveys the user has not touched, one asserted for surveys they
/// have — and the two would drift the first time either changed.
///
/// **No request this drives has ever been executed**; the available key is
/// read-only. See `PostHogAPI+Surveys` for what is source-derived, including the
/// unmeasured consequence of stopping through the action rather than the PATCH.
@MainActor
@Observable
final class SurveyLifecycleController {

    /// The two date fields, as we believe them after our own write. Both are
    /// double optionals in effect — `nil` inside means "cleared", which is what a
    /// resume writes and is not the same as "not overridden".
    struct Override: Equatable {
        var startDate: Date?
        var endDate: Date?
    }

    private(set) var overrides: [String: Override] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var message: WriteOutcomeMessage?

    private(set) var successCount = 0
    private(set) var failureCount = 0
    private(set) var filedCount = 0

    /// Not a `Capability.writeScope`: surveys have no `Capability` case of their
    /// own — the screen is gated on `.dashboards` — so this is named here rather
    /// than added to onboarding's checklist for everyone.
    let requiredWriteScope = "survey:write"

    func isBusy(_ survey: Survey) -> Bool { inFlight.contains(survey.id) }

    func dismissMessage() { message = nil }

    // MARK: - Effective state

    /// The survey as the screen should draw it: the server's copy, with our own
    /// writes laid over the top.
    ///
    /// Returns a whole `Survey` rather than a status word so every derived
    /// reading — the pill, the section it groups under, the "Stopped" date row —
    /// comes from the same three fields PostHog's own rule reads.
    func effective(_ survey: Survey) -> Survey {
        guard let override = overrides[survey.id] else { return survey }
        return survey.withDates(startDate: override.startDate, endDate: override.endDate)
    }

    func effectiveStatusText(_ survey: Survey) -> String { effective(survey).statusText }

    /// Launched, and not stopped. The only state `stop` applies to.
    func canStop(_ survey: Survey) -> Bool {
        let live = effective(survey)
        return !live.archived && live.startDate != nil && live.endDate == nil
    }

    /// Never launched. `launch/` is the only way to give a survey a start date,
    /// and it is not the way to restart a stopped one.
    func canLaunch(_ survey: Survey) -> Bool {
        let live = effective(survey)
        return !live.archived && live.startDate == nil
    }

    /// Launched once and stopped. Resuming clears the end date; PostHog's own
    /// analytics event for the transition is literally `"survey resumed"`.
    ///
    /// Deliberately not `launch/`: that action refuses a survey whose `end_date`
    /// is in the past — *"Cannot launch a survey with end_date in the past."* —
    /// so the word that sounds right is the call that cannot work.
    func canResume(_ survey: Survey) -> Bool {
        let live = effective(survey)
        return !live.archived && live.startDate != nil && live.endDate != nil
    }

    // MARK: - Writes

    func stop(_ survey: Survey, client: PostHogClient, projectID: Int) async {
        let live = effective(survey)
        await perform(
            survey,
            action: "stop",
            endpoint: PostHogAPI.stopSurvey(projectID: projectID, surveyID: survey.id),
            optimistic: Override(startDate: live.startDate, endDate: Date()),
            client: client,
            notice: "Stopped. Every response already collected is kept, and you can resume this survey later."
        )
    }

    func launch(_ survey: Survey, client: PostHogClient, projectID: Int) async {
        await perform(
            survey,
            action: "launch",
            endpoint: PostHogAPI.launchSurvey(projectID: projectID, surveyID: survey.id),
            optimistic: Override(startDate: Date(), endDate: nil),
            client: client,
            notice: nil
        )
    }

    func resume(_ survey: Survey, client: PostHogClient, projectID: Int) async {
        let live = effective(survey)
        await perform(
            survey,
            action: "resume",
            endpoint: PostHogAPI.resumeSurvey(projectID: projectID, surveyID: survey.id),
            optimistic: Override(startDate: live.startDate, endDate: nil),
            client: client,
            notice: nil
        )
    }

    func reconcile(with surveys: [Survey]) {
        let settled = Set(surveys.map(\.id)).subtracting(inFlight)
        overrides = overrides.filter { !settled.contains($0.key) }
    }

    // MARK: - The one write path

    /// No biometric gate, and the reason is `ErrorTriageController`'s rather than
    /// `FlagToggleController`'s. `BiometricGate` guards a change to what
    /// production serves users *right now*; a survey starting or stopping changes
    /// whether a prompt is shown, which is recoverable in one tap and destroys
    /// nothing. Putting Face ID in front of it would train people to authenticate
    /// reflexively, which is what makes the gate on the flags screen worth less.
    private func perform(
        _ survey: Survey,
        action: String,
        endpoint: Endpoint,
        optimistic: Override,
        client: PostHogClient,
        notice: String?
    ) async {
        guard !inFlight.contains(survey.id) else { return }
        message = nil

        let previous = overrides[survey.id]
        overrides[survey.id] = optimistic
        inFlight.insert(survey.id)
        defer { inFlight.remove(survey.id) }

        do {
            _ = try await client.data(for: endpoint)
            successCount += 1
            if let notice { message = WriteOutcomeMessage(kind: .notice, text: notice) }
        } catch {
            overrides[survey.id] = previous
            let outcome = WriteFailure.message(
                for: error,
                object: survey.name,
                action: action,
                writeScope: requiredWriteScope
            )
            if outcome.kind == .filed { filedCount += 1 } else { failureCount += 1 }
            message = outcome
        }
    }
}
