#if os(iOS) || os(macOS) || os(visionOS)
import AuthenticationServices
import Foundation
import GetHogKit
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Why an OAuth attempt stopped before producing a session. User cancellation
/// is silent (nil result, no error); everything else carries a sentence.
enum OAuthSignInError: Error, LocalizedError, Equatable {
    case denied(String?)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied(let error):
            error.map { "PostHog refused the request (\($0)). Try again." }
                ?? "PostHog refused the request. Try again."
        case .failed(let message):
            message
        }
    }
}

/// Presents the PostHog consent screen and returns the authorization code.
///
/// Owns one browser round trip: mints PKCE + `state`, opens the authorize
/// URL in an ephemeral `ASWebAuthenticationSession`, and awaits the matching
/// `OAuthCallbackInbox` entry. The completion handler and the universal link
/// both deliver there (the S4 measurement lives on `OAuthCallback.source`);
/// first writer per `state` wins, so whichever channel fires second is
/// dropped rather than double-completing the sign-in.
///
/// Ephemeral session, deliberately: no cookies persist, so a shared device
/// does not inherit the last user's PostHog login, and each attempt
/// re-authenticates in full.
@MainActor
final class OAuthSignInController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let directory: OAuthDirectory
    private var session: ASWebAuthenticationSession?
    /// Captured on the actor during `start`, read off it by the session.
    /// `nonisolated(unsafe)` because the delegate callback is nonisolated
    /// while the value can only be written before the session starts.
    private nonisolated(unsafe) var anchor: ASPresentationAnchor?

    init(directory: OAuthDirectory) {
        self.directory = directory
    }

    /// Runs one attempt. Returns the code and verifier for
    /// `AppModel.connectWithOAuth`, or nil when the user dismissed the
    /// browser without deciding.
    func start() async throws -> (code: String, verifier: String)? {
        let pkce = PKCE.generate()
        let state = Self.randomState()
        OAuthCallbackInbox.reset()

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: self.directory.authorizationURL(state: state, pkce: pkce),
                callbackURLScheme: nil
            ) { url, error in
                Task { @MainActor in
                    self.session = nil
                    if let url, let callback = OAuthCallback.parse(url) {
                        OAuthCallbackInbox.deliver(OAuthCallback(
                            outcome: callback.outcome,
                            state: callback.state,
                            source: .sessionCompletion
                        ))
                    } else if error != nil {
                        // Cancellation included: the waiter below is keyed on
                        // the outgoing `state`, so this always resolves it —
                        // including when the system cancels the session as the
                        // universal link returns (first writer wins there).
                        OAuthCallbackInbox.deliver(OAuthCallback(
                            outcome: .cancelled,
                            state: state,
                            source: .sessionCompletion
                        ))
                    }
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            self.anchor = Self.keyWindow()
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: OAuthSignInError.failed(
                    "Couldn't open the PostHog sign-in page."
                ))
                return
            }
            Task { @MainActor in
                let callback = await OAuthCallbackInbox.next(matching: state)
                self.session?.cancel()
                self.session = nil
                switch callback.outcome {
                case .code(let code):
                    continuation.resume(returning: (code, pkce.verifier))
                case .denied(let error):
                    continuation.resume(throwing: OAuthSignInError.denied(error))
                case .cancelled:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Nonisolated: the session calls it back off the actor, and it returns
    /// only the anchor captured during `start`.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    @MainActor
    private static func keyWindow() -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSWindow()
        #else
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIWindow()
        #endif
    }

    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCE.base64url(Data(bytes))
    }
}
#endif
