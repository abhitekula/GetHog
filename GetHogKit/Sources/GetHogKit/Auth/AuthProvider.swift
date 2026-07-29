import Foundation

/// Where a user's PostHog lives.
///
/// Self-hosted is a first-class case, not a fallback: PostHog's hosted OAuth
/// server only serves cloud, so personal API keys remain the only way to reach a
/// self-hosted instance. That is why this stays supported permanently.
public enum PostHogRegion: Sendable, Hashable, Codable {
    case usCloud
    case euCloud
    case selfHosted(URL)

    public var host: URL {
        switch self {
        case .usCloud: URL(string: "https://us.posthog.com")!
        case .euCloud: URL(string: "https://eu.posthog.com")!
        case .selfHosted(let url): url
        }
    }

    public var displayName: String {
        switch self {
        case .usCloud: "US Cloud"
        case .euCloud: "EU Cloud"
        case .selfHosted(let url): url.host() ?? "Self-hosted"
        }
    }

    /// Where the user creates a personal API key, for the onboarding deep link.
    public var apiKeySettingsURL: URL {
        host.appendingPathComponent("settings/user-api-keys")
    }
}

/// Supplies credentials for outgoing requests.
///
/// Personal keys and OAuth both authenticate with `Authorization: Bearer`, so
/// only acquisition and refresh differ. Keeping that behind this protocol is what
/// makes adding OAuth later a single new conformance rather than a rewrite.
public protocol AuthProvider: Sendable {
    var region: PostHogRegion { get }
    func authorizationHeader() async throws -> String
    /// Called on a 401. Personal keys rethrow; OAuth would refresh and retry.
    func handleUnauthorized() async throws
}

public struct PersonalKeyAuthProvider: AuthProvider {
    public let key: String
    public let region: PostHogRegion

    public init(key: String, region: PostHogRegion) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
    }

    public func authorizationHeader() async throws -> String { "Bearer \(key)" }

    public func handleUnauthorized() async throws {
        // A personal key cannot be refreshed; the user must supply a new one.
        throw PostHogError.unauthorized
    }
}
