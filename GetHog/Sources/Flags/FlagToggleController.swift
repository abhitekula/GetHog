import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import Observation
import GetHogKit

/// Per-flag opt-in that decides whether a flag may be flipped from *outside*
/// the app — Control Center, an interactive widget, a Shortcuts action.
///
/// Deliberately plain statics over `UserDefaults.standard`: a widget extension
/// and an App Intent need the same answer without importing the app's view
/// layer, and the key format is the contract between them.
enum FlagQuickToggle {

    static func defaultsKey(for flagID: Int) -> String { "quickToggle.\(flagID)" }

    /// Off unless the user has said otherwise. `bool(forKey:)` returning false
    /// for an unset key is the whole default — nothing is opted in implicitly,
    /// because outside the app there is no confirmation dialog to answer.
    static func isAllowed(flagID: Int) -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey(for: flagID))
    }

    static func setAllowed(_ allowed: Bool, flagID: Int) {
        UserDefaults.standard.set(allowed, forKey: defaultsKey(for: flagID))
    }
}

/// Optional device-owner authentication in front of a flag write.
enum BiometricGate {

    static let defaultsKey = "requireBiometricsForFlagToggle"

    /// Off by default; Settings turns it on.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// macOS and the iOS-family platforms frame an `LAContext` reason
    /// differently, so the same words cannot serve both. macOS drops the reason into a sentence it
    /// writes itself — "GetHog is trying to \(reason)." — where an imperative
    /// sentence reads as broken grammar, so the Mac supplies only the clause
    /// that completes it. iOS and visionOS show the reason on its own line
    /// beneath the prompt, where the full imperative sentence is the right
    /// register.
    #if os(macOS)
    static let reason = "change a live feature flag"
    #else
    static let reason = "Confirm you want to change a live feature flag"
    #endif

    enum Outcome {
        case passed
        /// The device can't offer the check at all (no passcode, no enrolled
        /// biometry). The confirmation dialog is then the only guard, and the
        /// caller says so rather than pretending the gate ran.
        case unavailable(String)
        /// The user or the system refused. The write must not happen.
        case denied(String)
    }

    /// Deliberately actor-free and self-contained: `LAContext` is not
    /// `Sendable`, so it is created, used and discarded inside a single
    /// isolation domain rather than being handed across an actor boundary.
    static func evaluate() async -> Outcome {
        #if os(tvOS)
        // `LAPolicy`, `canEvaluatePolicy` and `evaluatePolicy` are all
        // unavailable on tvOS — an Apple TV has no device owner to
        // authenticate, no biometry and no passcode to fall back on. This is
        // the same honest answer the `.unavailable` path already gives a phone
        // with the gate switched off: the confirmation dialog is the only
        // guard, and the caller says so rather than pretending the gate ran.
        return .unavailable("this device has no device-owner authentication")
        #else
        let context = LAContext()
        var probeError: NSError?

        // `.deviceOwnerAuthentication`, not `…WithBiometrics`: a device with no
        // Face ID still gets a passcode prompt instead of skipping the gate.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &probeError) else {
            return .unavailable(probeError?.localizedDescription ?? "device authentication isn't set up")
        }

        do {
            let confirmed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return confirmed ? .passed : .denied("Authentication wasn't confirmed.")
        } catch let error as LAError {
            switch error.code {
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return .unavailable(error.localizedDescription)
            default:
                // Cancel, wrong face, too many attempts — all mean "don't write".
                return .denied(error.localizedDescription)
            }
        } catch {
            return .denied(error.localizedDescription)
        }
        #endif
    }
}

/// Owns every write to a feature flag, plus the optimistic state that write
/// implies.
///
/// `FeatureFlag.active` is immutable and comes straight from the API, so an
/// in-flight or just-applied change lives here as an override rather than being
/// written back into the decoded model. That keeps exactly one source of truth
/// for "what did the server last tell us", which is what makes rollback honest.
@MainActor
@Observable
final class FlagToggleController {

    /// Flag id → the state we believe it is in after our own write.
    private(set) var overrides: [Int: Bool] = [:]
    /// Flag id → condition-group index → the percentage we believe that group is
    /// at after our own write.
    ///
    /// Keyed by group as well as by flag because there is no "the" rollout
    /// percentage to override: `FeatureFlag.rolloutPercentage` is a `max()` across
    /// release-condition groups, and a flag with two groups has two numbers. An
    /// override keyed on the flag alone would have to pick one of them to be, and
    /// whichever it picked would be wrong for the other group's row.
    private(set) var rolloutOverrides: [Int: [Int: Double]] = [:]
    private(set) var inFlight: Set<Int> = []
    private(set) var message: FlagToggleMessage?

    /// Monotonic counters drive `.sensoryFeedback`; two flags flipped the same
    /// way in a row must still each produce a tap. `filedCount` is separate from
    /// the other two because a change request waiting for approval is neither a
    /// success nor a failure, and the error haptic is the one channel a user
    /// cannot argue with.
    private(set) var successCount = 0
    private(set) var failureCount = 0
    private(set) var filedCount = 0

    /// Invalidates suspended work when the selected project changes. Flag ids
    /// are only unique inside one project, so an old task must not even clear
    /// the in-flight marker of a new-project write that happens to reuse one.
    @ObservationIgnored private var projectGeneration: UInt64 = 0

    var requiredWriteScope: String { Capability.flags.writeScope ?? "feature_flag:write" }

    func effectiveActive(_ flag: FeatureFlag) -> Bool { overrides[flag.id] ?? flag.active }

    /// One release-condition group's rollout percentage, with our own write laid
    /// over it. `nil` means the group has no cap set, which means everyone the
    /// conditions match — not nobody.
    func effectiveRollout(_ flag: FeatureFlag, group index: Int) -> Double? {
        if let written = rolloutOverrides[flag.id]?[index] { return written }
        guard flag.conditionGroups.indices.contains(index) else { return nil }
        return flag.conditionGroups[index].rolloutPercentage
    }

    func isBusy(_ flag: FeatureFlag) -> Bool { inFlight.contains(flag.id) }

    func dismissMessage() { message = nil }

    /// Optimistic values belong to the project whose rows produced them. They
    /// must not survive into a new project's list, even if the two projects
    /// happen to reuse the same numeric flag id.
    func resetForProjectChange() {
        projectGeneration &+= 1
        overrides = [:]
        rolloutOverrides = [:]
        inFlight = []
        message = nil
    }

    /// Source-compatible entry point for callers that already hold one
    /// unquestionably current project id.
    func setActive(
        _ desired: Bool,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int
    ) async {
        await setActive(
            desired,
            flag: flag,
            client: client,
            projectID: projectID,
            currentProjectID: projectID
        )
    }

    /// Applies a confirmed change. Callers must have shown the confirmation
    /// dialog already — nothing in here asks the user whether they meant it.
    func setActive(
        _ desired: Bool,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        currentProjectID: Int?
    ) async {
        await setActive(
            desired,
            flag: flag,
            client: client,
            projectID: projectID,
            currentProjectID: { currentProjectID }
        )
    }

    /// The current project is a closure, not a captured value, because device
    /// authentication suspends this task. The root that owns this controller
    /// can disappear on sign-out while the task remains alive; re-reading the
    /// model after the prompt is the only check that still observes that
    /// transition.
    func setActive(
        _ desired: Bool,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        currentProjectID: @MainActor () -> Int?,
        isGateEnabled: Bool = BiometricGate.isEnabled,
        gate: @MainActor () async -> BiometricGate.Outcome = BiometricGate.evaluate
    ) async {
        await setActiveAuthorized(
            desired,
            flag: flag,
            client: client,
            projectID: projectID,
            authorizationIsCurrent: { currentProjectID() == projectID },
            isGateEnabled: isGateEnabled,
            gate: gate
        )
    }

    /// Interactive writes carry the complete authentication epoch that owned
    /// the captured client. Project ids and hosts can repeat after reconnect,
    /// so neither one is sufficient authorization after a biometric prompt.
    func setActive(
        _ desired: Bool,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        expectedScope: FlagWriteScope,
        currentScope: @MainActor () -> FlagWriteScope?,
        isGateEnabled: Bool = BiometricGate.isEnabled,
        gate: @MainActor () async -> BiometricGate.Outcome = BiometricGate.evaluate
    ) async {
        guard expectedScope.projectID == projectID else { return }
        await setActiveAuthorized(
            desired,
            flag: flag,
            client: client,
            projectID: projectID,
            authorizationIsCurrent: { currentScope() == expectedScope },
            isGateEnabled: isGateEnabled,
            gate: gate
        )
    }

    private func setActiveAuthorized(
        _ desired: Bool,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        authorizationIsCurrent: @MainActor () -> Bool,
        isGateEnabled: Bool,
        gate: @MainActor () async -> BiometricGate.Outcome
    ) async {
        // `projectID` is captured with the decoded flag. The other value is the
        // project selected at commit time. Never substitute the latter into the
        // endpoint: a stale detail must do nothing, not write its old flag id
        // through the newly selected project.
        guard authorizationIsCurrent() else { return }
        guard !inFlight.contains(flag.id) else { return }
        let generation = projectGeneration
        message = nil

        if isGateEnabled {
            let outcome = await gate()
            guard generation == projectGeneration else { return }
            guard authorizationIsCurrent() else { return }
            switch outcome {
            case .passed:
                break
            case .unavailable(let detail):
                message = FlagToggleMessage(
                    kind: .notice,
                    text: "Device authentication wasn't available (\(detail)). This change was confirmed by dialog only."
                )
            case .denied(let detail):
                failureCount += 1
                message = FlagToggleMessage(
                    kind: .failure,
                    text: "Not authenticated, so \(flag.key) was left unchanged. \(detail)"
                )
                return
            }
        }

        // Also covers a gate that is disabled: a caller can enqueue this task
        // and sign out before the main actor begins executing it.
        guard authorizationIsCurrent() else { return }

        let previous = effectiveActive(flag)
        apply(desired, to: flag)
        inFlight.insert(flag.id)
        defer {
            if generation == projectGeneration {
                inFlight.remove(flag.id)
            }
        }

        do {
            _ = try await client.data(
                for: PostHogAPI.setFlagActive(projectID: projectID, flagID: flag.id, active: desired)
            )
            guard generation == projectGeneration else { return }
            guard authorizationIsCurrent() else { return }
            successCount += 1
            // Inside the success branch, after the write returned, and never in
            // the `catch` below: the optimistic state is rolled back when the
            // request fails, and a donation is a claim the thing happened. It is
            // also gated on the flag's own quick-toggle opt-in — see
            // `IntentDonations.mayDonateToggle` — so a flag the user has chosen
            // to keep in-app only cannot become a Siri suggestion that would
            // then be refused by `SetFeatureFlagIntent` anyway.
            IntentDonations.flagSet(flag, enabled: desired)
        } catch {
            guard generation == projectGeneration else { return }
            guard authorizationIsCurrent() else { return }
            apply(previous, to: flag)
            record(error, flag: flag, action: desired ? "enable" : "disable")
        }
    }

    /// Applies a confirmed rollout change to **one** release-condition group.
    ///
    /// The group index is a parameter and not a convenience because there is no
    /// single rollout percentage on a flag to set — see `rolloutOverrides` and
    /// `FeatureFlag.rolloutPercentage`.
    ///
    /// Returns without a request when `PostHogAPI.setFlagRollout` declines to
    /// build one. That happens when the flag arrived without its verbatim
    /// `filters`, when its `filters` carry no `groups` array, or when the index or
    /// the percentage is out of range — and in the second case in particular,
    /// sending the PATCH anyway would answer **200 with the flag unchanged**,
    /// which is the worst of the three outcomes because it looks like success.
    ///
    /// Gated on the device-owner check for the same reason the toggle is: this
    /// changes what production serves to users right now.
    /// Source-compatible entry point for a caller whose project cannot change
    /// between decoding the flag and invoking the write.
    func setRollout(
        _ percentage: Double,
        group index: Int,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int
    ) async {
        await setRollout(
            percentage,
            group: index,
            flag: flag,
            client: client,
            projectID: projectID,
            currentProjectID: projectID
        )
    }

    func setRollout(
        _ percentage: Double,
        group index: Int,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        currentProjectID: Int?
    ) async {
        await setRollout(
            percentage,
            group: index,
            flag: flag,
            client: client,
            projectID: projectID,
            currentProjectID: { currentProjectID }
        )
    }

    func setRollout(
        _ percentage: Double,
        group index: Int,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        currentProjectID: @MainActor () -> Int?,
        isGateEnabled: Bool = BiometricGate.isEnabled,
        gate: @MainActor () async -> BiometricGate.Outcome = BiometricGate.evaluate
    ) async {
        await setRolloutAuthorized(
            percentage,
            group: index,
            flag: flag,
            client: client,
            projectID: projectID,
            authorizationIsCurrent: { currentProjectID() == projectID },
            isGateEnabled: isGateEnabled,
            gate: gate
        )
    }

    func setRollout(
        _ percentage: Double,
        group index: Int,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        expectedScope: FlagWriteScope,
        currentScope: @MainActor () -> FlagWriteScope?,
        isGateEnabled: Bool = BiometricGate.isEnabled,
        gate: @MainActor () async -> BiometricGate.Outcome = BiometricGate.evaluate
    ) async {
        guard expectedScope.projectID == projectID else { return }
        await setRolloutAuthorized(
            percentage,
            group: index,
            flag: flag,
            client: client,
            projectID: projectID,
            authorizationIsCurrent: { currentScope() == expectedScope },
            isGateEnabled: isGateEnabled,
            gate: gate
        )
    }

    private func setRolloutAuthorized(
        _ percentage: Double,
        group index: Int,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int,
        authorizationIsCurrent: @MainActor () -> Bool,
        isGateEnabled: Bool,
        gate: @MainActor () async -> BiometricGate.Outcome
    ) async {
        guard authorizationIsCurrent() else { return }
        guard !inFlight.contains(flag.id) else { return }
        let generation = projectGeneration
        message = nil

        guard let endpoint = PostHogAPI.setFlagRollout(
            projectID: projectID,
            flag: flag,
            groupIndex: index,
            percentage: percentage
        ) else {
            failureCount += 1
            message = FlagToggleMessage(
                kind: .failure,
                text: """
                    Couldn't change the rollout for \(flag.key). GetHog didn't keep enough of this \
                    flag's release conditions to change one safely without dropping the rest. \
                    Edit it in the PostHog web console.
                    """
            )
            return
        }

        if isGateEnabled {
            let outcome = await gate()
            guard generation == projectGeneration else { return }
            guard authorizationIsCurrent() else { return }
            switch outcome {
            case .passed:
                break
            case .unavailable(let detail):
                message = FlagToggleMessage(
                    kind: .notice,
                    text: "Device authentication wasn't available (\(detail)). This change was confirmed by dialog only."
                )
            case .denied(let detail):
                failureCount += 1
                message = FlagToggleMessage(
                    kind: .failure,
                    text: "Not authenticated, so \(flag.key) was left unchanged. \(detail)"
                )
                return
            }
        }

        guard authorizationIsCurrent() else { return }

        let previous = rolloutOverrides[flag.id]?[index]
        rolloutOverrides[flag.id, default: [:]][index] = percentage
        inFlight.insert(flag.id)
        defer {
            if generation == projectGeneration {
                inFlight.remove(flag.id)
            }
        }

        do {
            _ = try await client.data(for: endpoint)
            guard generation == projectGeneration else { return }
            guard authorizationIsCurrent() else { return }
            successCount += 1
        } catch {
            guard generation == projectGeneration else { return }
            guard authorizationIsCurrent() else { return }
            rolloutOverrides[flag.id]?[index] = previous
            record(error, flag: flag, action: "change the rollout for")
        }
    }

    /// Drops overrides once a fresh fetch has spoken for the same flags.
    ///
    /// Whoever else changed the flag in the web console wins: a stale local
    /// override that outlives its write would quietly misreport production.
    func reconcile(with flags: [FeatureFlag]) {
        let settled = Set(flags.map(\.id)).subtracting(inFlight)
        overrides = overrides.filter { !settled.contains($0.key) }
        rolloutOverrides = rolloutOverrides.filter { !settled.contains($0.key) }
    }

    private func apply(_ value: Bool, to flag: FeatureFlag) {
        // Only keep an override while it actually disagrees with the API.
        overrides[flag.id] = value == flag.active ? nil : value
    }

    /// Turns a thrown error into what the reader is told, and bumps whichever
    /// counter is honest about it.
    ///
    /// **The reason this is one function rather than a `catch` per call site.**
    /// One of the things that reaches this `catch` is not a failure at all: under
    /// an organisation approval policy, `PATCH /feature_flags/:id/` answers HTTP
    /// 409 `approval_required`, the flag is unchanged, a change request exists,
    /// and its approvers have been notified. Before `PostHogError.approvalRequired`
    /// and this function existed, that arrived as a generic 409 and this
    /// controller reported it as *"Couldn't enable …"*, which is the one
    /// description that is definitely wrong — nothing failed, and there is a real,
    /// pending, human-visible request the reader now needs to chase.
    ///
    /// The optimistic state is still rolled back by the caller, and must be: the
    /// flag really did not change. Rollback and "this failed" are two separate
    /// claims, and only the first one was ever true here.
    ///
    /// **Source-derived, never observed.** No 409 has been received from a live
    /// deployment; provoking one needs an approval policy *and* a write, and the
    /// key here is read-only.
    private func record(_ error: any Error, flag: FeatureFlag, action: String) {
        let outcome = WriteFailure.message(
            for: error,
            object: flag.key,
            action: action,
            writeScope: requiredWriteScope
        )
        if outcome.kind == .filed { filedCount += 1 } else { failureCount += 1 }
        message = outcome
    }
}
