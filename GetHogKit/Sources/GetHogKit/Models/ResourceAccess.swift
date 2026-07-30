import Foundation

/// Why a gated screen can't show its data.
///
/// One classifier for every gated surface. It replaces two byte-identical
/// enums — `LogsState` and `TracingState` — that two parallel efforts produced
/// independently; they differed only in which fallback strings they defaulted
/// to, which is now a parameter.
///
/// The cases are separated by **remedy**, not by HTTP status, because the
/// remedies genuinely differ and pointing someone at the wrong one wastes their
/// time. Editing an API key cannot grant an organisation role. Nothing at all
/// fixes an endpoint that refuses personal keys as a category. Probing the live
/// API turned up four distinct walls where the app previously modelled two.
public enum ResourceAccessState: Sendable, Equatable {
    case loading

    /// PostHog denied a named resource. Fixed by an organisation admin granting
    /// role access, *not* by editing the API key.
    ///
    /// Note this arrives as HTTP **400**, not 403 — verified against the live
    /// API for both `logs` and `tracing`.
    case denied(resource: String)

    /// The personal API key lacks a scope. Fixed by the user editing their key,
    /// which is the only one of these four the user can fix alone.
    case missingScope(String)

    /// The product requires a paid plan. HTTP 402.
    case needsPlan(String?)

    /// PostHog must enable a feature flag for the organisation. Neither the
    /// user nor their admin can.
    case featureFlagged(String)

    /// The endpoint refuses personal API keys as a category:
    /// `"This action does not support personal API key access"`.
    ///
    /// No scope grant and no plan upgrade changes this — it needs OAuth, which
    /// this app does not have. Distinguished so the screen can say so plainly
    /// instead of sending someone to edit a key that was never the problem.
    case unsupportedForPersonalKeys

    case failed(String)
    case empty
    case loaded

    /// Classifies a failed request.
    ///
    /// - Parameters:
    ///   - resource: name to fall back on when PostHog omits it. The name is
    ///     scraped out of a prose message, so it can go missing if the wording
    ///     changes; staying locked beats dropping through to a retryable
    ///     failure that would never succeed.
    ///   - defaultScope: scope to name when a 403 carries no `missingScope`.
    public init(failure error: any Error, resource: String, defaultScope: String) {
        guard let error = error as? PostHogError else {
            self = .failed(error.localizedDescription)
            return
        }
        switch error {
        case .accessDenied(let named):
            self = .denied(resource: named ?? resource)

        case .paymentRequired(let detail):
            self = .needsPlan(detail)

        case .forbidden(let scope, let detail):
            // The detail text is the only thing separating these three, and
            // they have three different remedies, so it is worth reading rather
            // than collapsing every 403 into "add a scope".
            if let detail, detail.localizedCaseInsensitiveContains("personal API key") {
                self = .unsupportedForPersonalKeys
            } else if let detail, let flag = Self.featureFlagName(in: detail) {
                self = .featureFlagged(flag)
            } else {
                self = .missingScope(scope ?? defaultScope)
            }

        default:
            self = .failed(error.localizedDescription)
        }
    }

    /// Pulls `metrics` out of "requires feature flag 'metrics' to be enabled".
    private static func featureFlagName(in detail: String) -> String? {
        guard detail.localizedCaseInsensitiveContains("feature flag") else { return nil }
        // Quoted name if there is one; otherwise the caller still gets a
        // feature-flag state, just without being able to name the flag.
        let quotes: [Character] = ["'", "\"", "\u{2018}", "\u{2019}"]
        guard let open = detail.firstIndex(where: { quotes.contains($0) }) else { return "" }
        let rest = detail[detail.index(after: open)...]
        guard let close = rest.firstIndex(where: { quotes.contains($0) }) else { return "" }
        return String(rest[..<close])
    }

    /// Resolves a successful load: no rows is empty, which is not a failure.
    public static func resolved(rowCount: Int) -> ResourceAccessState {
        rowCount == 0 ? .empty : .loaded
    }

    /// True when this is a permission or plan wall rather than an outage.
    ///
    /// Drives whether the screen offers a retry. Offering one for a 403 invites
    /// someone to tap it forever; withholding one for a 500 hides the fix.
    public var isBlocked: Bool {
        switch self {
        case .denied, .missingScope, .needsPlan, .featureFlagged, .unsupportedForPersonalKeys:
            true
        case .loading, .failed, .empty, .loaded:
            false
        }
    }

    /// Retained name for the locked check, which reads better at the call site
    /// than `isBlocked` when the question really is "should this screen show a
    /// lock".
    public var isDenied: Bool { isBlocked }
}

/// The words one screen uses for its own subject.
///
/// This is the part of the old duplicated enums that was *not* duplication:
/// "Tracing is locked / No spans" and "Logs are locked / No log lines" are
/// genuinely different sentences. The structure is shared; the nouns are not.
public struct ResourceCopy: Sendable, Hashable {
    /// Capitalised, used as a subject: "Tracing", "Logs".
    public let subject: String
    /// Plural noun for the rows: "spans", "log lines".
    public let itemNoun: String
    /// What to suggest when a successful load returns nothing.
    public let emptyHint: String

    public init(subject: String, itemNoun: String, emptyHint: String) {
        self.subject = subject
        self.itemNoun = itemNoun
        self.emptyHint = emptyHint
    }
}

public extension ResourceAccessState {

    func headline(_ copy: ResourceCopy) -> String {
        switch self {
        case .denied, .missingScope, .needsPlan, .featureFlagged, .unsupportedForPersonalKeys:
            "\(copy.subject) is locked"
        case .failed:
            "Couldn't load \(copy.itemNoun)"
        case .empty:
            "No \(copy.itemNoun)"
        case .loading, .loaded:
            copy.subject
        }
    }

    /// The sentence under the headline. Names the exact thing that is missing,
    /// because "locked" on its own is not actionable — and names a *different*
    /// remedy per case, since the whole point of the four walls is that they
    /// are fixed by four different people.
    func detail(_ copy: ResourceCopy) -> String {
        switch self {
        case .denied(let resource):
            """
            Your PostHog account doesn't have `viewer` access to the `\(resource)` \
            resource in this project. An organisation admin grants it in role \
            access settings — a new API key will not fix it.
            """
        case .missingScope(let scope):
            "Your PostHog API key is missing the \(scope) scope. Add it to the key, then re-check."
        case .needsPlan(let detail):
            detail ?? "\(copy.subject) requires a paid PostHog plan."
        case .featureFlagged(let flag):
            flag.isEmpty
                ? "PostHog has to enable this product for your organisation before it can be read."
                : """
                  \(copy.subject) is behind the `\(flag)` feature flag. PostHog has to enable it \
                  for your organisation — neither a new key nor an admin can.
                  """
        case .unsupportedForPersonalKeys:
            """
            This endpoint refuses personal API keys, so no key and no plan will open it. \
            It needs OAuth, which GetHog doesn't have yet.
            """
        case .failed(let message):
            message
        case .empty:
            copy.emptyHint
        case .loading:
            "Loading \(copy.itemNoun)."
        case .loaded:
            "\(copy.subject) loaded."
        }
    }
}
