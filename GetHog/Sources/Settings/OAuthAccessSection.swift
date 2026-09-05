import GetHogKit
import GetHogUI
import SwiftUI

/// What this PostHog Cloud grant carries, and the way back to full access.
///
/// Mounted only for OAuth sessions (`SettingsRoot` gates on
/// `model.oauthDirectory`). A declined write scope does not break the session
/// — reads keep working and only the gated action reports its locked message
/// — so this section is an inventory plus one recovery action, not an alarm.
/// Re-authorizing asks for the full requested set again: refresh never widens
/// scopes, so the browser round trip is the only way a declined scope joins
/// the grant, and asking for everything keeps the grant to a single consent
/// rather than one round trip per scope.
struct SettingsOAuthAccessSection: View {
    @Environment(AppModel.self) private var model

    @State private var isAuthorizing = false
    @State private var error: String?

    private var granted: Set<String> {
        Set((try? model.store.load())?.grantedScopes ?? [])
    }

    private var expiryText: String? {
        guard let expiry = (try? model.store.load())?.accessTokenExpiry else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        if expiry > Date() {
            return "Renews \(formatter.localizedString(for: expiry, relativeTo: Date()))"
        }
        return "Expired — renews on next use"
    }

    private var missing: [String] {
        OAuthDirectory.requestedScopes.filter { !granted.contains($0) }
    }

    var body: some View {
        Section {
            if let expiryText {
                LabeledContent("Access token", value: expiryText)
                    .font(.footnote)
            }
            ForEach(OAuthDirectory.requestedScopes, id: \.self) { scope in
                LabeledContent(scope) {
                    Text(granted.contains(scope) ? "Granted" : "Not granted")
                        .font(.footnote)
                        .foregroundStyle(
                            granted.contains(scope)
                                ? Theme.Ink.secondary
                                : Theme.Status.warningInk
                        )
                }
                .font(.footnote.monospaced())
            }

            #if os(iOS) || os(macOS) || os(visionOS)
            // The browser round trip needs AuthenticationServices, which tvOS
            // does not offer — and a TV session can never hold an OAuth grant
            // anyway, so this section never mounts there regardless.
            if !missing.isEmpty, model.oauthDirectory != nil {
                Button {
                    Task { await grantFullAccess() }
                } label: {
                    HStack {
                        Label("Grant full access", systemImage: "checkmark.shield")
                        if isAuthorizing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isAuthorizing)
            }
            #endif

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.Status.criticalInk)
            }
        } header: {
            SectionLabel(text: "PostHog access", systemImage: "key.fill")
        } footer: {
            Text("Reads are always granted. Writes declined during sign-in stay off until granted here; a declined write fails only its own action.")
        }
    }

    #if os(iOS) || os(macOS) || os(visionOS)
    private func grantFullAccess() async {
        guard let directory = model.oauthDirectory else { return }
        isAuthorizing = true
        error = nil
        defer { isAuthorizing = false }
        do {
            guard let result = try await OAuthSignInController(directory: directory).start() else {
                return
            }
            try await model.connectWithOAuth(directory: directory, code: result.code, verifier: result.verifier)
        } catch let signInError as OAuthSignInError {
            self.error = signInError.localizedDescription
        } catch let posthogError as PostHogError {
            self.error = posthogError.localizedDescription
        } catch {
            self.error = "Couldn't finish granting access. Try again."
        }
    }
    #endif
}
