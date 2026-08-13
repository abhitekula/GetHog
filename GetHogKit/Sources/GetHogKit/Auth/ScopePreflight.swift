import Foundation

/// A feature of the app, and the PostHog scopes it needs.
///
/// Personal API key scopes are chosen by the *user* when they create the key, so
/// wrong scopes are the single most predictable support burden. Probing up front
/// turns an opaque mid-session 403 into an actionable checklist.
public enum Capability: String, Sendable, CaseIterable, Identifiable {
    case dashboards
    case events
    case sessions
    case flags
    case replay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboards: "Dashboards & insights"
        case .events: "Events feed"
        case .sessions: "Session inspector"
        case .flags: "Feature flags"
        case .replay: "Session replay"
        }
    }

    public var requiredScopes: [String] {
        APIKeyScopeGuidance.requiredReadScopes(for: self).map(\.scope)
    }

    /// Toggling a flag needs a write scope, which is only discovered on first
    /// use because a read probe cannot detect it. Kept for the existing flag
    /// action while the catalog remains the one owner of its value.
    public var writeScope: String? {
        APIKeyScopeGuidance.optionalWriteScope(for: self)?.scope
    }

    public var systemImage: String {
        switch self {
        case .dashboards: "square.grid.2x2"
        case .events: "bolt"
        case .sessions: "rectangle.stack"
        case .flags: "flag"
        case .replay: "play.rectangle"
        }
    }
}

public enum CapabilityStatus: Sendable, Equatable {
    case available
    /// PostHog refused. This is the only case that is *evidence* about the key.
    case locked(scope: String?)
    /// The probe never reached a verdict — a timeout, a 5xx, a dropped
    /// connection. Says nothing at all about the key's scopes.
    case failed(String)

    /// Whether PostHog actually refused.
    ///
    /// The distinction this property exists to protect: a probe that *failed*
    /// and a probe that came back *denied* are different facts. Reported from a
    /// real session — same key, same build, one launch apart — the Sessions tab
    /// listed sessions normally and was then replaced by "Your PostHog API key
    /// is missing a scope. Add it to your key in PostHog, then re-check." The
    /// key was fine; a transient `.failed` had been read as a denial, and the
    /// app told someone to go and edit a working credential.
    public var isDenied: Bool {
        if case .locked = self { true } else { false }
    }

    /// The probe's own error, when there was one. Never a scope claim.
    public var failureMessage: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}

public struct CapabilityReport: Sendable, Equatable {
    public let results: [Capability: CapabilityStatus]

    public init(results: [Capability: CapabilityStatus]) {
        self.results = results
    }

    public func status(_ capability: Capability) -> CapabilityStatus {
        results[capability] ?? .failed("Not checked")
    }

    /// Whether this capability's screen may open.
    ///
    /// Deliberately the negation of *denied*, not the identity of `.available`.
    /// The gate has two states and the probe has three, so a boolean written the
    /// other way round has to fold `.failed` onto one side or the other — and
    /// folding it onto "unavailable" is what put a scope instruction in front of
    /// a user whose key was fine. Nothing but a refusal closes a screen. A probe
    /// that never got an answer lets the screen open and lets its own request
    /// produce the real error, which is a better error than a guess.
    public func isAvailable(_ capability: Capability) -> Bool {
        !status(capability).isDenied
    }

    /// Whether every probe came back confirming access.
    ///
    /// A different question from `isAvailable`, and strict where that one is
    /// permissive: a probe that failed genuinely did not confirm anything. The
    /// two must not share an implementation — collapsing them is the fault this
    /// file exists to prevent.
    public var allAvailable: Bool {
        Capability.allCases.allSatisfy { status($0) == .available }
    }

    /// Why a probe could not reach a verdict, when it could not.
    ///
    /// Kept rather than discarded: the reported bug replaced the real error with
    /// a scope claim the app had no evidence for, and lost the error doing it.
    public func probeFailure(_ capability: Capability) -> String? {
        status(capability).failureMessage
    }

    /// The scope to add, and `nil` whenever the app has no denial to base that
    /// instruction on.
    public func lockedScope(for capability: Capability) -> String? {
        guard case .locked(let scope) = status(capability) else { return nil }
        return scope ?? capability.requiredScopes.joined(separator: ", ")
    }

    /// Scope names to show the user, preferring the exact string PostHog
    /// returned and falling back to the documented scopes for that feature.
    public var missingScopes: [String] {
        results.compactMap { capability, status in
            guard case .locked(let scope) = status else { return nil }
            return scope ?? capability.requiredScopes.joined(separator: ", ")
        }
        .sorted()
    }
}

/// Probes one endpoint per feature to build the checklist.
public struct ScopePreflight: Sendable {
    private let client: PostHogClient

    public init(client: PostHogClient) {
        self.client = client
    }

    private enum UnauthorizedPolicy {
        case recordFailure
        case invalidateSession
    }

    /// Builds capability evidence without changing this public API's original
    /// nonthrowing contract.
    ///
    /// A 401 is not evidence about one capability's scopes: every request made
    /// with that credential is now unauthenticated. Compatibility callers get
    /// an inconclusive `.failed` result for every rejected probe, never a lock.
    /// Session owners that can replace the credential use
    /// `runRequiringValidCredential(projectID:)` instead.
    public func run(projectID: Int) async -> CapabilityReport {
        do {
            return try await run(projectID: projectID, unauthorized: .recordFailure)
        } catch {
            // `.recordFailure` handles every error at the probe boundary. Keep a
            // complete inconclusive report as defense if that invariant changes.
            return failedReport(error.localizedDescription)
        }
    }

    /// Builds capability evidence while surfacing a session-wide 401 to the
    /// credential owner. A 403 remains capability-local evidence; transport and
    /// server failures remain inconclusive probe results.
    public func runRequiringValidCredential(projectID: Int) async throws -> CapabilityReport {
        try await run(projectID: projectID, unauthorized: .invalidateSession)
    }

    private func run(
        projectID: Int,
        unauthorized policy: UnauthorizedPolicy
    ) async throws -> CapabilityReport {
        var results: [Capability: CapabilityStatus] = [:]

        for capability in Capability.allCases where capability != .replay {
            results[capability] = try await probe(
                capability,
                projectID: projectID,
                unauthorized: policy
            )
        }
        // Replay rides on the same scope as the inspector; a separate probe would
        // cost a request for no extra information.
        results[.replay] = results[.sessions]

        return CapabilityReport(results: results)
    }

    private func failedReport(_ message: String) -> CapabilityReport {
        CapabilityReport(results: Dictionary(uniqueKeysWithValues: Capability.allCases.map {
            ($0, CapabilityStatus.failed(message))
        }))
    }

    private func probe(
        _ capability: Capability,
        projectID: Int,
        unauthorized policy: UnauthorizedPolicy
    ) async throws -> CapabilityStatus {
        let endpoint: Endpoint = switch capability {
        case .dashboards: PostHogAPI.dashboards(projectID: projectID, limit: 1)
        case .events: PostHogAPI.hogql(projectID: projectID, sql: "SELECT 1 LIMIT 1")
        case .sessions, .replay: PostHogAPI.sessionRecordings(projectID: projectID, limit: 1)
        case .flags: PostHogAPI.featureFlags(projectID: projectID, limit: 1)
        }

        do {
            _ = try await client.data(for: endpoint)
            return .available
        } catch let error as PostHogError {
            switch error {
            case .forbidden(let scope, _): return .locked(scope: scope)
            case .unauthorized:
                switch policy {
                case .recordFailure: return .failed(error.localizedDescription)
                case .invalidateSession: throw error
                }
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
