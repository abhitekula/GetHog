import Foundation
import Observation
import GetHogKit

/// Owns every write to an experiment, plus the optimistic state those writes
/// imply.
///
/// Same three commitments as `FlagToggleController` and `ErrorTriageController`,
/// which are the app's older writes:
///
/// * `Experiment` stays immutable and is exactly what the API last said. A
///   just-applied change lives here as an override, so there is one source of
///   truth for "what does the server believe" and rollback is honest.
/// * Nothing in here asks the user anything. Callers show the confirmation
///   dialog first; see `ExperimentDetailSheet`.
/// * A refresh wins. `reconcile(with:)` drops overrides a fresh fetch has spoken
///   for, so a stale local override cannot outlive its write.
///
/// ## Why this is one controller and not three buttons
///
/// The three actions it drives have *different blast radii behind the same
/// English word*, and that is the whole design problem for this screen:
///
///     End      writes end_date + conclusion. Does NOT touch the feature flag.
///              Users keep their variants and exposures keep firing.
///     Pause    calls set_flag_active(flag, False). Nobody sees the variant.
///              Writes nothing on the experiment at all.
///     Resume   the same, in reverse.
///
/// Somebody reaching for "stop the experiment" on a phone means one of those two
/// and the app cannot know which. Keeping them in one type means the wording,
/// the gating and the optimistic state for all three are decided side by side
/// rather than in three screens that each looked reasonable alone.
///
/// ## Why pause and resume are gated and end is not
///
/// `BiometricGate` exists because a flag flip changes what production serves to
/// users *right now*. Pause and resume do exactly that — through
/// `set_flag_active`, on the linked production flag — so they are gated on the
/// same optional check the flags screen uses. Ending an experiment moves a date
/// and records a judgement; nothing a user is served changes. Putting Face ID in
/// front of both would make the gate mean nothing, which is `ErrorTriageController`'s
/// argument for having none at all.
///
/// **No request this drives has ever been executed.** The available key is
/// read-only and project [REMOVED PRIVATE DATA] has zero experiments; see `PostHogAPI+Experiments`.
@MainActor
@Observable
final class ExperimentLifecycleController {

    /// What we believe an experiment looks like after our own write.
    ///
    /// The status is carried as well as the conclusion because `pause/` writes
    /// *nothing* on the experiment row — PostHog derives `paused` from the linked
    /// flag being inactive — so there is no field on the object to reflect the
    /// change into. The override is the only place that fact can live until the
    /// next fetch.
    struct Override: Equatable {
        var status: ExperimentStatus
        var conclusion: ExperimentConclusion?
        var conclusionComment: String?
        var endDate: Date?
    }

    private(set) var overrides: [Int: Override] = [:]
    private(set) var inFlight: Set<Int> = []
    private(set) var message: WriteOutcomeMessage?

    /// Monotonic counters drive `.sensoryFeedback`; two experiments paused in a
    /// row must still each produce a tap. `filedCount` is separate from both
    /// because a change request is neither — playing the error haptic for it
    /// would say "that didn't work" in the one channel a user cannot argue with.
    private(set) var successCount = 0
    private(set) var failureCount = 0
    private(set) var filedCount = 0

    /// Not a `Capability.writeScope`: experiments have no `Capability` case of
    /// their own — the screen is gated on `.dashboards` — and inventing one would
    /// change what onboarding asks every user to tick. Named here so the 403 path
    /// can still be specific.
    ///
    /// Worth knowing, and read from the decorators rather than probed:
    /// `pause/` and `resume/` declare **only** `experiment:write` and then flip a
    /// production feature flag. So this is the scope to add, and it is a wider
    /// grant than its name suggests.
    let requiredWriteScope = "experiment:write"

    func isBusy(_ experiment: Experiment) -> Bool { inFlight.contains(experiment.id) }

    func dismissMessage() { message = nil }

    // MARK: - Effective state

    func effectiveStatus(_ experiment: Experiment) -> ExperimentStatus? {
        overrides[experiment.id]?.status ?? experiment.status
    }

    /// The status word, with our own writes laid over the server's.
    ///
    /// Falls back to `Experiment.statusText` rather than reimplementing it, so
    /// the archived-overrides-everything rule and the date-derived fallback for
    /// payloads that predate `status` stay in one place.
    func effectiveStatusText(_ experiment: Experiment) -> String {
        guard let override = overrides[experiment.id] else { return experiment.statusText }
        return experiment.archived ? "Archived" : override.status.displayName
    }

    func effectiveConclusion(_ experiment: Experiment) -> ExperimentConclusion? {
        overrides[experiment.id]?.conclusion ?? experiment.conclusion
    }

    func effectiveConclusionComment(_ experiment: Experiment) -> String? {
        if let override = overrides[experiment.id] {
            return override.conclusionComment ?? experiment.conclusionComment
        }
        return experiment.conclusionComment
    }

    func effectiveEndDate(_ experiment: Experiment) -> Date? {
        overrides[experiment.id]?.endDate ?? experiment.endDate
    }

    /// Whether pausing is worth offering. Only a running experiment has anything
    /// to pause, and a stopped one's flag is not this screen's to touch.
    func canPause(_ experiment: Experiment) -> Bool {
        !experiment.archived && effectiveStatus(experiment) == .running
    }

    func canResume(_ experiment: Experiment) -> Bool {
        !experiment.archived && effectiveStatus(experiment) == .paused
    }

    /// Ending is offered for anything that has launched and has not already been
    /// ended. `end/` 400s on an already-stopped experiment, so offering it there
    /// would be offering a button that cannot work.
    func canEnd(_ experiment: Experiment) -> Bool {
        guard !experiment.archived else { return false }
        switch effectiveStatus(experiment) {
        case .running, .paused, .exposureFrozen: return true
        case .draft, .stopped: return false
        case nil: return experiment.startDate != nil && experiment.endDate == nil
        }
    }

    // MARK: - Writes

    /// Ends an experiment with the conclusion the user picked.
    ///
    /// The conclusion is not optional here for the reason it is not optional on
    /// the endpoint: `end_experiment` assigns it unconditionally, so ending
    /// without one writes `null` over a colleague's recorded verdict.
    func end(
        _ experiment: Experiment,
        conclusion: ExperimentConclusion,
        comment: String,
        client: PostHogClient,
        projectID: Int
    ) async {
        await perform(
            experiment,
            action: "end",
            endpoint: PostHogAPI.endExperiment(
                projectID: projectID,
                experimentID: experiment.id,
                conclusion: conclusion,
                comment: comment
            ),
            optimistic: Override(
                status: .stopped,
                conclusion: conclusion,
                conclusionComment: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? experiment.conclusionComment
                    : comment,
                endDate: Date()
            ),
            client: client,
            // No biometric gate: ending changes a date and a label. Nothing a
            // user is served changes, and the flag keeps serving variants.
            requiresDeviceOwner: false,
            notice: """
                Ended. The linked feature flag was not touched — people already in a variant \
                keep seeing it. Pause the experiment if you want that to stop too.
                """
        )
    }

    /// Pauses or resumes by flipping the linked feature flag.
    func setPaused(
        _ paused: Bool,
        experiment: Experiment,
        client: PostHogClient,
        projectID: Int
    ) async {
        let endpoint = paused
            ? PostHogAPI.pauseExperiment(projectID: projectID, experimentID: experiment.id)
            : PostHogAPI.resumeExperiment(projectID: projectID, experimentID: experiment.id)

        await perform(
            experiment,
            action: paused ? "pause" : "resume",
            endpoint: endpoint,
            optimistic: Override(
                status: paused ? .paused : .running,
                conclusion: overrides[experiment.id]?.conclusion,
                conclusionComment: overrides[experiment.id]?.conclusionComment,
                endDate: overrides[experiment.id]?.endDate
            ),
            client: client,
            // Gated: this is a production feature flag changing, which is the one
            // thing `BiometricGate` was added for.
            requiresDeviceOwner: true,
            notice: nil
        )
    }

    /// Drops overrides once a fresh fetch has spoken for the same experiments.
    ///
    /// Whoever else changed it in the web console wins, for the reason the flag
    /// controller gives: a stale local override that outlives its write quietly
    /// misreports production.
    func reconcile(with experiments: [Experiment]) {
        let settled = Set(experiments.map(\.id)).subtracting(inFlight)
        overrides = overrides.filter { !settled.contains($0.key) }
    }

    // MARK: - The one write path

    private func perform(
        _ experiment: Experiment,
        action: String,
        endpoint: Endpoint,
        optimistic: Override,
        client: PostHogClient,
        requiresDeviceOwner: Bool,
        notice: String?
    ) async {
        guard !inFlight.contains(experiment.id) else { return }
        message = nil

        if requiresDeviceOwner, BiometricGate.isEnabled {
            switch await BiometricGate.evaluate() {
            case .passed:
                break
            case .unavailable(let detail):
                // Proceed, but say the gate did not actually run rather than
                // implying it passed — the same wording the flags screen uses.
                message = WriteOutcomeMessage(
                    kind: .notice,
                    text: "Device authentication wasn't available (\(detail)). This change was confirmed by dialog only."
                )
            case .denied(let detail):
                failureCount += 1
                message = WriteOutcomeMessage(
                    kind: .failure,
                    text: "Not authenticated, so \(experiment.name) was left unchanged. \(detail)"
                )
                return
            }
        }

        let previous = overrides[experiment.id]
        overrides[experiment.id] = optimistic
        inFlight.insert(experiment.id)
        defer { inFlight.remove(experiment.id) }

        do {
            _ = try await client.data(for: endpoint)
            successCount += 1
            if let notice { message = WriteOutcomeMessage(kind: .notice, text: notice) }
        } catch {
            // Rolled back in **every** branch, including the approval one, and
            // that is not a contradiction: under an approval policy the
            // experiment genuinely did not change, so the screen must stop
            // claiming it did. What differs is what the reader is told — see
            // `WriteFailure.message`, which turns that catch into "filed" rather
            // than "failed".
            overrides[experiment.id] = previous
            let outcome = WriteFailure.message(
                for: error,
                object: experiment.name,
                action: action,
                writeScope: requiredWriteScope
            )
            if outcome.kind == .filed { filedCount += 1 } else { failureCount += 1 }
            message = outcome
        }
    }
}
