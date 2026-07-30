import Foundation
import LocalAuthentication
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

    static let reason = "Confirm you want to change a live feature flag"

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
    }
}

struct FlagToggleMessage: Identifiable, Equatable {
    enum Kind { case failure, notice }

    let id = UUID()
    let kind: Kind
    let text: String
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
    private(set) var inFlight: Set<Int> = []
    private(set) var message: FlagToggleMessage?

    /// Monotonic counters drive `.sensoryFeedback`; two flags flipped the same
    /// way in a row must still each produce a tap.
    private(set) var successCount = 0
    private(set) var failureCount = 0

    var requiredWriteScope: String { Capability.flags.writeScope ?? "feature_flag:write" }

    func effectiveActive(_ flag: FeatureFlag) -> Bool { overrides[flag.id] ?? flag.active }

    func isBusy(_ flag: FeatureFlag) -> Bool { inFlight.contains(flag.id) }

    func dismissMessage() { message = nil }

    /// Applies a confirmed change. Callers must have shown the confirmation
    /// dialog already — nothing in here asks the user whether they meant it.
    func setActive(
        _ desired: Bool,
        flag: FeatureFlag,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard !inFlight.contains(flag.id) else { return }
        message = nil

        if BiometricGate.isEnabled {
            switch await BiometricGate.evaluate() {
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

        let previous = effectiveActive(flag)
        apply(desired, to: flag)
        inFlight.insert(flag.id)
        defer { inFlight.remove(flag.id) }

        do {
            _ = try await client.data(
                for: PostHogAPI.setFlagActive(projectID: projectID, flagID: flag.id, active: desired)
            )
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
            apply(previous, to: flag)
            failureCount += 1
            message = failureMessage(for: error, flag: flag, desired: desired)
        }
    }

    /// Drops overrides once a fresh fetch has spoken for the same flags.
    ///
    /// Whoever else changed the flag in the web console wins: a stale local
    /// override that outlives its write would quietly misreport production.
    func reconcile(with flags: [FeatureFlag]) {
        let settled = Set(flags.map(\.id)).subtracting(inFlight)
        overrides = overrides.filter { !settled.contains($0.key) }
    }

    private func apply(_ value: Bool, to flag: FeatureFlag) {
        // Only keep an override while it actually disagrees with the API.
        overrides[flag.id] = value == flag.active ? nil : value
    }

    private func failureMessage(
        for error: any Error,
        flag: FeatureFlag,
        desired: Bool
    ) -> FlagToggleMessage {
        let verb = desired ? "enable" : "disable"
        var text = "Couldn't \(verb) \(flag.key). \(error.localizedDescription)"

        if let posthogError = error as? PostHogError {
            switch posthogError {
            case .forbidden:
                // A read-scoped key passes preflight and only fails here, so
                // this is the first moment the user can learn what to tick.
                text = """
                    Couldn't \(verb) \(flag.key): your personal API key is missing the \
                    \(requiredWriteScope) scope. Add it to the key in PostHog, then try again.
                    """
            case .unauthorized:
                text = "Couldn't \(verb) \(flag.key): your API key was rejected. Reconnect in Settings."
            default:
                text = "Couldn't \(verb) \(flag.key). \(posthogError.localizedDescription)"
            }
        }

        return FlagToggleMessage(kind: .failure, text: text)
    }
}
