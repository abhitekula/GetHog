import Foundation
import GetHogKit

/// An OAuth authorization response, parsed off the universal-link callback.
struct OAuthCallback: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// The browser came back with an authorization code.
        case code(String)
        /// The user denied consent, or PostHog refused the request.
        case denied(String?)
        /// Delivered by `ASWebAuthenticationSession` when the user dismissed it.
        case cancelled
    }

    let outcome: Outcome
    /// Echo of the `state` sent with the authorize URL. The inbox matches on
    /// it, which is what stops a stale or foreign callback from completing
    /// somebody else's sign-in.
    let state: String?
    /// Which channel delivered it — the S4 spike measurement. Both write to
    /// the same inbox; first writer for a `state` wins.
    let source: Source

    enum Source: Sendable, Equatable {
        case sessionCompletion
        case universalLink
    }

    /// Whether this URL is an OAuth callback for the configured directory,
    /// and therefore must not reach deep-link routing.
    static func isOAuthCallback(_ url: URL, directory: OAuthDirectory) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == directory.callbackHost,
              components.path == "/oauth/callback" || components.path == "/oauth/callback/"
        else { return false }
        return true
    }

    /// Parses a callback URL. Returns nil for anything that is not an OAuth
    /// callback at all (so shells can fall through to `LinkInbox`); a
    /// callback-shaped URL with an authorization error parses to `.denied`.
    static func parse(_ url: URL) -> OAuthCallback? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.path == "/oauth/callback" || components.path == "/oauth/callback/"
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let state = value("state")
        if let code = value("code"), !code.isEmpty {
            return OAuthCallback(outcome: .code(code), state: state, source: .universalLink)
        }
        let error = value("error")
        return OAuthCallback(outcome: .denied(error), state: state, source: .universalLink)
    }
}

/// One place every OAuth response lands before the sign-in flow reads it.
///
/// The same cold-launch argument as `LinkInbox`: a universal link can resume
/// the app before the starter that asked for it has subscribed, so the value
/// is held keyed by `state` until taken. First writer per `state` wins, which
/// is what lets the `ASWebAuthenticationSession` completion and the universal
/// link race without double-completing one sign-in.
@MainActor
enum OAuthCallbackInbox {
    private static var pending: [String: OAuthCallback] = [:]
    private static var waiters: [String: [CheckedContinuation<OAuthCallback, Never>]] = [:]

    static let didChangeNotification = Notification.Name("app.gethog.oauthCallback")

    static func deliver(_ callback: OAuthCallback) {
        let key = callback.state ?? ""
        if pending[key] == nil {
            pending[key] = callback
        }
        guard let callback = pending[key] else { return }
        for waiter in waiters.removeValue(forKey: key) ?? [] {
            waiter.resume(returning: callback)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Waits for the callback carrying `state`, however long the browser round
    /// trip takes. A callback that arrived first is returned immediately.
    static func next(matching state: String) async -> OAuthCallback {
        if let callback = pending.removeValue(forKey: state) {
            return callback
        }
        return await withCheckedContinuation { continuation in
            waiters[state, default: []].append(continuation)
        }
    }

    /// Test and retry seam: drops everything held, waking nobody.
    static func reset() {
        pending = [:]
        waiters = [:]
    }
}

/// Whether this build can start OAuth sign-in.
///
/// Two conditions, and only the conjunction opens the entry points. A
/// configured directory means somebody set up the server half; the platform
/// condition covers the client half: Mac Debug entitlements deliberately
/// carry no `applinks` (that entitlement requires a certificate and Debug is
/// what a teamless clone builds), so a universal link could never return
/// there. Release Mac, iOS, and visionOS all carry the entitlement.
///
/// Sessions outlive the condition on purpose: a grant minted in Release
/// keeps refreshing in Debug, because renewal is a token call, not a link.
/// Only starting a new browser round trip is gated.
enum OAuthAvailability {
    static var canBeginSignIn: Bool {
        guard OAuthDirectory.resolve() != nil else { return false }
        #if os(macOS) && DEBUG
        return false
        #else
        return true
        #endif
    }
}

/// Routes a continued web-browsing activity to the OAuth inbox when it is one
/// of ours. Shared by the iOS, Mac, and Vision shells; each mounts it beside
/// its Handoff continuation, which answers a different activity type.
///
/// Returns whether the activity was consumed. Anything that is not an OAuth
/// callback for the configured directory falls through — notably when no
/// directory is configured, in which case this never consumes.
enum OAuthActivityRouter {
    @MainActor
    static func route(_ activity: NSUserActivity, directory: OAuthDirectory?) -> Bool {
        guard let directory,
              activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL,
              OAuthCallback.isOAuthCallback(url, directory: directory),
              let callback = OAuthCallback.parse(url)
        else { return false }
        OAuthCallbackInbox.deliver(callback)
        return true
    }
}
