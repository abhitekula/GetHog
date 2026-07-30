import Foundation

public enum PostHogError: Error, Equatable, Sendable {
    case unauthorized
    /// The key authenticated but lacks a scope. `missingScope` is the exact
    /// scope string PostHog named, so onboarding can tell the user what to tick.
    case forbidden(missingScope: String?, detail: String? = nil)
    /// The feature exists but the organisation's plan doesn't include it (HTTP 402).
    case paymentRequired(String?)
    /// The key is fine, but this user lacks access to a specific resource.
    /// PostHog reports this as a **400**, not a 403.
    case accessDenied(resource: String?)
    case rateLimited(retryAfter: TimeInterval)
    /// PostHog stopped a query for exceeding its execution budget. Carries
    /// PostHog's verbatim advice, which is addressed to someone with a SQL
    /// console rather than to the reader of a phone screen.
    case queryTimeout(String?)
    case http(status: Int, detail: String?)
    case transport(String)
    /// Carries a `DecodingError` description — written for a compiler, never for
    /// a reader. See `errorDescription` and `technicalDetail`.
    case decoding(String)

    public var isRetryable: Bool {
        switch self {
        // Measured against a live project: the same query that timed out
        // succeeded on 1 run in 5. The condition belongs to the cluster's load,
        // not to the request, so trying again is a real remedy.
        case .rateLimited, .transport, .queryTimeout: true
        case .http(let status, _): status >= 500
        default: false
        }
    }

    /// Whether this case's own `errorDescription` is fit to put in front of a
    /// reader.
    ///
    /// Kept separate from `technicalDetail` on purpose. The two used to be the
    /// same question — only `.decoding` had a detail, so "has a detail" stood in
    /// for "cannot describe itself". `.queryTimeout` has both a detail *and* a
    /// sentence, and a caller that still conflated them would have replaced the
    /// timeout's message with the decoding one.
    public var hasReadableDescription: Bool {
        if case .decoding = self { false } else { true }
    }

    /// The verbatim fault, for a screen that can disclose it behind a
    /// "Details" control rather than printing it as the message.
    public var technicalDetail: String? {
        switch self {
        case .decoding(let message): message
        case .queryTimeout(let detail): detail
        default: nil
        }
    }

    /// Recognises the execution-budget failure from PostHog's message.
    ///
    /// Observed as HTTP 504, but keyed on the body: PostHog documents no status
    /// for this and the sentence is what actually identifies it. Deliberately
    /// does not match the neighbouring 503 "Queries are a little too busy right
    /// now", which is a different condition with a message already fit to show.
    public static func isQueryTimeout(detail: String?) -> Bool {
        guard let detail else { return false }
        return detail.contains("max execution time")
    }
}

extension PostHogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Your API key was rejected. Check the key and try again."
        case .forbidden(let scope, _):
            if let scope {
                "Your API key is missing the \(scope) scope."
            } else {
                "Your API key doesn't have permission for this."
            }
        case .paymentRequired(let detail):
            detail ?? "This feature requires a paid PostHog plan."
        case .accessDenied(let resource):
            if let resource {
                "You don't have access to \(resource) in this project. Ask an admin to grant it."
            } else {
                "You don't have access to this resource in the project."
            }
        case .rateLimited(let after):
            "PostHog is rate limiting requests. Try again in \(Int(after))s."
        // Says the one thing that happened and stops. PostHog's own text —
        // "See our docs for how to improve your query performance. You may need
        // to materialize." — reached the Events tab as the entire user-facing
        // message: docs it does not link, and an instruction nobody can carry
        // out from a phone. It survives as `technicalDetail` for whoever can
        // use it.
        case .queryTimeout:
            "PostHog took too long to run this query and stopped it. Trying again often works."
        case .http(let status, let detail):
            detail ?? "PostHog returned an error (\(status))."
        case .transport(let message):
            "Couldn't reach PostHog: \(message)"
        // Deliberately says nothing about *what* was malformed. Measured on the
        // Groups screen: interpolating the message put
        // "DecodingError.typeMismatch: expected value of type Array<Any>" in
        // front of a user, who can neither read nor act on a Swift type name.
        // The one true thing the app knows is that the payload was not the shape
        // it expected; the rest is `technicalDetail`, for whoever can use it.
        case .decoding:
            "PostHog's response wasn't in a shape this app could read."
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

    /// Pulls the resource name out of "Access control failure. You don't have
    /// `viewer` access to the `logs` resource." — the message is the only place
    /// PostHog says which resource was denied.
    var deniedResource: String? {
        guard let detail, detail.contains("Access control failure") else { return nil }
        let pattern = /access to the `([a-z_]+)` resource/
        return detail.firstMatch(of: pattern).map { String($0.1) }
    }
}
