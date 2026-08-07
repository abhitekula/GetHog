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
    /// HTTP 409 with `code: approval_required` or `code:
    /// change_request_pending` — **not a failure**.
    ///
    /// The one response in this enum whose defining property is that the request
    /// did what it was supposed to and the object still did not change. Under an
    /// organisation approval policy a write that would touch a feature flag is
    /// turned into a *change request*: the flag is untouched, a row exists, and
    /// the named approvers have been notified. An optimistic client must roll the
    /// UI back — the flag really did not change — while telling the reader their
    /// change was filed and by whom it needs approving. Reporting it as a failure
    /// is the one description that is definitely wrong.
    ///
    /// **Source-derived, never observed.** Read out of PostHog's `@approval_gate`
    /// decorator on the feature-flag serializer's `create`/`update`; the key this
    /// was built against is read-only, so no 409 of any kind has been received
    /// from a live deployment. See `ApprovalOutcome` for what is and is not known
    /// about the body's shape.
    case approvalRequired(ApprovalOutcome)
    /// Any other HTTP 409.
    ///
    /// In practice the feature-flag serializer's optimistic-concurrency check,
    /// which only ever fires when the caller sent a `version` — `version =
    /// request_data.get("version", -1)` is read off the *raw* body, so a request
    /// that omits it skips the check entirely and last write wins. Sending the
    /// version you decoded is what turns a silent clobber into this. Also
    /// source-derived and never observed.
    case editConflict(detail: String?)
    case http(status: Int, detail: String?)
    /// A Foundation URL-loading failure whose numeric code must survive the
    /// transport boundary. Some device-specific recovery depends on that code:
    /// watchOS uses `NSURLErrorNotConnectedToInternet` (-1009) to explain that
    /// a Bluetooth-proxied request may be waiting on an offline iPhone.
    case network(code: Int, description: String)
    case transport(String)
    /// Carries a `DecodingError` description — written for a compiler, never for
    /// a reader. See `errorDescription` and `technicalDetail`.
    case decoding(String)

    public var isRetryable: Bool {
        switch self {
        // Rate limits, transport failures, and query timeouts are transient
        // conditions for which retrying can be a real remedy.
        case .rateLimited, .network, .transport, .queryTimeout: true
        case .http(let status, _): status >= 500
        default: false
        }
    }

    /// Whether the write reached PostHog and was *recorded* rather than
    /// rejected.
    ///
    /// Exists so a caller can tell the one non-failure in this enum apart from
    /// everything else without matching the case by hand at every call site. A
    /// caller that treats this as an error will report a real, pending,
    /// human-visible change request as something that did not happen.
    public var isApprovalPending: Bool {
        if case .approvalRequired = self { true } else { false }
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
        case .network(_, let description): description
        case .queryTimeout(let detail): detail
        default: nil
        }
    }

    /// Foundation's `NSURLErrorDomain` code when the transport reached URL
    /// loading. `nil` for HTTP failures and non-URL transports.
    public var networkErrorCode: Int? {
        if case .network(let code, _) = self { code } else { nil }
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
        // Says "not yet" rather than "no", because that is what happened. The
        // sentence deliberately opens with what is *true of the object* — it did
        // not change — before naming the request, so a reader who stops after one
        // clause is not left believing the write landed.
        case .approvalRequired(let outcome):
            outcome.summary
        case .editConflict(let detail):
            detail ?? "Somebody else changed this while you were looking at it. Reload and try again."
        case .http(let status, let detail):
            detail ?? "PostHog returned an error (\(status))."
        case .network(_, let description):
            "Couldn't reach PostHog: \(description)"
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

/// What a 409 approval response says, reduced to the three facts a phone screen
/// can act on: which of the two codes it was, whether there is a change-request
/// id to quote, and who has to approve it.
///
/// **Every claim about this payload is source-derived and unverified.** It comes
/// from PostHog's `@approval_gate` decorator and the `ship_variant` docstring
/// that describes the same response. Automated tests use synthetic 409 bodies
/// and do not retain tenant responses. Two consequences are baked into the
/// decoding below rather than assumed away:
///
/// * `change_request_id` is decoded as a `JSONValue` and rendered as text,
///   because nothing establishes whether it is an integer primary key or a uuid
///   string. Both render; only one would decode if this were typed.
/// * `required_approvers` is a bare list in the shape the decorator builds, and
///   its *element* shape is not documented anywhere read. It is decoded as
///   `[JSONValue]` and each element is described by `Self.describe`, which
///   handles a plain email string, a numeric user id, and an object keyed by
///   any of `email`/`name`/`first_name`+`last_name`/`id`. An element matching
///   none of those is dropped rather than printed as JSON — a phone screen
///   saying "needs approval from `{\"foo\": 1}`" is worse than one saying only
///   how many people it needs.
public struct ApprovalOutcome: Sendable, Equatable, Hashable {

    /// The two codes the gate can answer with. They mean different things to the
    /// person holding the phone: the first says *you* filed something, the
    /// second says somebody already did and yours added nothing.
    public enum Kind: String, Sendable, Hashable {
        case filed = "approval_required"
        case alreadyPending = "change_request_pending"
    }

    public let kind: Kind
    /// The change request's id as text, when the body carried one.
    public let changeRequestID: String?
    /// Approver descriptions, best effort. Empty is a real answer — the body may
    /// carry an empty list, or a list this build could not describe.
    public let approvers: [String]
    /// PostHog's own `message`/`detail`, kept verbatim for disclosure.
    public let detail: String?

    public init(
        kind: Kind,
        changeRequestID: String? = nil,
        approvers: [String] = [],
        detail: String? = nil
    ) {
        self.kind = kind
        self.changeRequestID = changeRequestID
        self.approvers = approvers
        self.detail = detail
    }

    /// One sentence stating what is true of the object, then what exists because
    /// of the request, then who has to act.
    ///
    /// Deliberately does not lead with PostHog's own `message`. That field is
    /// written for an API consumer and this is the one response whose *default*
    /// reading — "the call errored" — is wrong, so the correction has to come
    /// first and in this app's words. The server's sentence survives as `detail`.
    public var summary: String {
        var text = kind == .alreadyPending
            ? "Nothing changed: a change request for this is already waiting for approval."
            : "Nothing changed yet. Your change was filed as a change request and is waiting for approval."
        switch approvers.count {
        case 0: break
        case 1: text += " \(approvers[0]) has to approve it."
        default: text += " It needs approval from \(approvers.joined(separator: ", "))."
        }
        return text
    }

    /// Describes one entry of `required_approvers`, or `nil` when this build
    /// cannot say anything truthful about it.
    static func describe(_ value: JSONValue) -> String? {
        switch value {
        case .string(let name):
            return name.isEmpty ? nil : name
        case .number:
            return value.stringValue.map { "User \($0)" }
        case .object:
            if let email = value["email"]?.stringValue, !email.isEmpty { return email }
            if let name = value["name"]?.stringValue, !name.isEmpty { return name }
            let parts = [value["first_name"]?.stringValue, value["last_name"]?.stringValue]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
            if let id = value["id"]?.stringValue { return "User \(id)" }
            return nil
        default:
            return nil
        }
    }
}

/// The 409 body, read only far enough to build an `ApprovalOutcome`.
///
/// A separate type from `PostHogErrorEnvelope` because it is a different
/// envelope: PostHog's standard error shape is `{type, code, detail, attr}`,
/// while this one carries `message`, `change_request_id`, `change_request` and
/// `required_approvers` beside the code. Decoding one with the other would
/// silently drop everything worth telling the reader.
struct ApprovalEnvelope: Decodable {
    let code: String?
    let message: String?
    let detail: String?
    let changeRequestID: JSONValue?
    let requiredApprovers: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case code, message, detail
        case changeRequestID = "change_request_id"
        case requiredApprovers = "required_approvers"
    }

    /// `nil` unless the body actually names one of the two approval codes.
    ///
    /// Keyed on `code` and nothing else. A 409 this build does not recognise must
    /// not be dressed up as an approval — telling someone their change is waiting
    /// for a colleague when it is not is worse than the generic conflict message.
    var outcome: ApprovalOutcome? {
        guard let code, let kind = ApprovalOutcome.Kind(rawValue: code) else { return nil }
        return ApprovalOutcome(
            kind: kind,
            changeRequestID: changeRequestID?.stringValue,
            approvers: (requiredApprovers ?? []).compactMap(ApprovalOutcome.describe),
            detail: message ?? detail
        )
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
