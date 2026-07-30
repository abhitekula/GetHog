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
        switch self {
        case .dashboards: ["dashboard:read", "insight:read"]
        case .events: ["query:read"]
        case .sessions: ["session_recording:read"]
        case .flags: ["feature_flag:read"]
        case .replay: ["session_recording:read"]
        }
    }

    /// Toggling a flag needs a write scope, which is only discovered on first use
    /// because a read probe cannot detect it.
    public var writeScope: String? {
        self == .flags ? "feature_flag:write" : nil
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
    case locked(scope: String?)
    case failed(String)
}

public struct CapabilityReport: Sendable, Equatable {
    public let results: [Capability: CapabilityStatus]

    public init(results: [Capability: CapabilityStatus]) {
        self.results = results
    }

    public func status(_ capability: Capability) -> CapabilityStatus {
        results[capability] ?? .failed("Not checked")
    }

    public func isAvailable(_ capability: Capability) -> Bool {
        status(capability) == .available
    }

    public var allAvailable: Bool {
        Capability.allCases.allSatisfy { isAvailable($0) }
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

    public func run(projectID: Int) async -> CapabilityReport {
        var results: [Capability: CapabilityStatus] = [:]

        for capability in Capability.allCases where capability != .replay {
            results[capability] = await probe(capability, projectID: projectID)
        }
        // Replay rides on the same scope as the inspector; a separate probe would
        // cost a request for no extra information.
        results[.replay] = results[.sessions]

        return CapabilityReport(results: results)
    }

    private func probe(_ capability: Capability, projectID: Int) async -> CapabilityStatus {
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
            case .unauthorized: return .locked(scope: nil)
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
