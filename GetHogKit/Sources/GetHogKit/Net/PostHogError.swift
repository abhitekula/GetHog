import Foundation

public enum PostHogError: Error, Equatable, Sendable {
    case unauthorized
    /// The key authenticated but lacks a scope. `missingScope` is the exact
    /// scope string PostHog named, so onboarding can tell the user what to tick.
    case forbidden(missingScope: String?)
    case rateLimited(retryAfter: TimeInterval)
    case http(status: Int, detail: String?)
    case transport(String)
    case decoding(String)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport: true
        case .http(let status, _): status >= 500
        default: false
        }
    }
}

extension PostHogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Your API key was rejected. Check the key and try again."
        case .forbidden(let scope):
            if let scope {
                "Your API key is missing the \(scope) scope."
            } else {
                "Your API key doesn't have permission for this."
            }
        case .rateLimited(let after):
            "PostHog is rate limiting requests. Try again in \(Int(after))s."
        case .http(let status, let detail):
            detail ?? "PostHog returned an error (\(status))."
        case .transport(let message):
            "Couldn't reach PostHog: \(message)"
        case .decoding(let message):
            "Unexpected response from PostHog: \(message)"
        }
    }
}

/// PostHog's standard error envelope:
/// `{"type":…,"code":…,"detail":…,"attr":…}`
struct PostHogErrorEnvelope: Decodable {
    let type: String?
    let code: String?
    let detail: String?

    /// Pulls a scope like `session_recording:read` out of the human-readable
    /// detail message. PostHog does not return it as a structured field.
    var missingScope: String? {
        guard let detail else { return nil }
        let pattern = /([a-z_]+:(?:read|write))/
        return detail.firstMatch(of: pattern).map { String($0.1) }
    }
}
