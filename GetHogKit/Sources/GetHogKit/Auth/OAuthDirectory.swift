import CryptoKit
import Foundation
import Security

/// Where PostHog Cloud OAuth lives, and where this build's callback goes.
///
/// The issuer is constant — the region-agnostic proxy, so no region picker
/// precedes OAuth sign-in; the API host is resolved after authentication from
/// the token's region info and `/me/`. Every deployment-specific string
/// derives from one injected host, so the public tree names no domain: the
/// host arrives per-developer through `Config/OAuth.local.xcconfig` as
/// `GETHOG_OAUTH_DOMAIN`, and an empty value means `init` returns nil and
/// every OAuth entry point stays hidden.
public struct OAuthDirectory: Sendable, Hashable, Equatable {
    public static let issuerHost = "oauth.posthog.com"

    /// The host serving the CIMD document, the universal-link callback, and
    /// the `apple-app-site-association` file. Never a URL, only a host.
    public let callbackHost: String

    public init?(callbackHost: String) {
        let host = callbackHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !host.isEmpty, !host.contains("://"), !host.contains("/") else { return nil }
        self.callbackHost = host
    }

    public var issuer: URL { URL(string: "https://\(Self.issuerHost)")! }

    /// The CIMD document URL. This *is* the OAuth `client_id`: PostHog fetches
    /// it during authorization to learn this client's name, logo, and allowed
    /// redirect URIs, so no pre-registration step exists.
    public var clientID: String { "https://\(callbackHost)/posthog-client" }

    /// The universal-link callback. Must be listed verbatim in the CIMD
    /// document's `redirect_uris` and claimed by the app's
    /// `apple-app-site-association` entry.
    public var redirectURI: String { "https://\(callbackHost)/oauth/callback" }

    public var authorizationEndpoint: URL {
        issuer.appending(path: "oauth/authorize/")
    }

    public var tokenEndpoint: URL {
        issuer.appending(path: "oauth/token/")
    }

    public var revocationEndpoint: URL {
        issuer.appending(path: "oauth/revoke/")
    }

    /// One consent, every surface. Refresh never widens scopes — a token
    /// minted without a write scope can never grow it — so requesting the full
    /// working set up front avoids interrupting the user for re-authorization
    /// the first time they toggle a flag or snooze an alert. Kept as literals
    /// beside the catalog rather than derived from it: `APIKeyScopeGuidance`
    /// describes what a *key* needs per surface, while this is the ceiling one
    /// *grant* carries, and the suite below pins that this stays a superset of
    /// both the core reads and the full-client writes plus organization read.
    ///
    /// The ceiling ships as two lists because consent treats them differently:
    /// `requiredScopes` are locked on PostHog's screen, `optionalScopes` are
    /// pre-checked but declinable (`optional_scopes` in the CIMD document). A
    /// declined write does not break the session — reads keep working and only
    /// the gated action reports its missing scope. `requestedScopes` is the
    /// union the authorize URL sends.
    public static let requiredScopes: [String] = [
        "dashboard:read",
        "insight:read",
        "query:read",
        "session_recording:read",
        "feature_flag:read",
        "project:read",
        "organization:read",
    ]

    public static let optionalScopes: [String] = [
        "feature_flag:write",
        "alert:write",
        "annotation:write",
        "error_tracking:write",
        "experiment:write",
        "survey:write",
    ]

    public static var requestedScopes: [String] {
        requiredScopes + optionalScopes
    }

    /// The browser URL that starts the authorization-code + PKCE flow.
    /// PostHog supports `code` only, with `S256` challenges.
        /// The `GetHogOAuthDomain` Info.plist key carrying the per-developer host.
    public static let infoPlistKey = "GetHogOAuthDomain"

    /// Reads the per-developer OAuth directory host out of a built bundle.
    ///
    /// The value arrives as an Info.plist key expanded from
    /// `$(GETHOG_OAUTH_DOMAIN)` at build time. Empty (the public default)
    /// means nil: OAuth entry points stay hidden and the app is PAT-only.
    /// Lives in the kit (rather than beside its callers) because widget
    /// extensions resolve it from their own bundles too.
    public static func resolve(bundle: Bundle = .main) -> OAuthDirectory? {
        guard let host = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return nil
        }
        return OAuthDirectory(callbackHost: host)
    }

    public func authorizationURL(state: String, pkce: PKCE) -> URL {        var components = URLComponents(
            url: authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.requestedScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }
}

/// Proof Key for Code Exchange (RFC 7636), public-client edition.
///
/// A native app ships no client secret, so the secret is per-authorization
/// instead: the verifier stays in memory for the minutes the browser round
/// trip takes, and only its SHA-256 challenge travels in the authorize URL.
public struct PKCE: Sendable, Equatable {
    public let verifier: String

    public init(verifier: String) {
        self.verifier = verifier
    }

    /// 32 random bytes, base64url without padding: 43 characters, inside the
    /// 43–128 range the server requires.
    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCE(verifier: base64url(Data(bytes)))
    }

    /// `BASE64URL-ENCODE(SHA256(verifier))`, no padding.
    public var challenge: String {
        Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64url without padding, per RFC 7636 Appendix A. Public so the app
    /// layer can mint `state` values with the same encoding the challenges use.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
