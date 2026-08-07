import GetHogKit
import GetHogUI
import Observation
import SwiftUI

/// Which PostHog a key belongs to, as a thing a `Picker` can hold.
///
/// `PostHogRegion.selfHosted` carries a `URL`, which a picker tag cannot,
/// so the choice and the host string are kept apart and resolved together.
enum TVRegionChoice: String, CaseIterable, Hashable {
    case usCloud
    case euCloud
    case selfHosted

    var title: String {
        switch self {
        case .usCloud: "US Cloud"
        case .euCloud: "EU Cloud"
        case .selfHosted: "Self-hosted"
        }
    }

    var subtitle: String {
        switch self {
        case .usCloud: "us.posthog.com"
        case .euCloud: "eu.posthog.com"
        case .selfHosted: "Your own deployment"
        }
    }
}

/// Everything about key entry that can be decided without a screen.
///
/// Separated from the view so the rules that decide whether a key is usable are
/// testable — the alternative is a `canConnect` that only a running Apple TV can
/// disagree with.
@MainActor
@Observable
final class TVKeyEntryModel {
    var key = ""
    var region: TVRegionChoice = .usCloud
    var selfHostedHost = ""

    /// Trimmed the way `StoredCredential.init` trims, so what this screen calls
    /// empty and what the credential calls empty cannot disagree — a key of
    /// three spaces must not reach a request as a header.
    var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when a self-hosted address cannot be made into a URL with a host.
    ///
    /// `URL(string:)` alone is not enough: it accepts `"posthog"` and yields a
    /// relative URL with no host, which would reach the client as a base and
    /// fail at request time with something that reads like a network error
    /// rather than a typo.
    func resolvedRegion() -> PostHogRegion? {
        switch region {
        case .usCloud: .usCloud
        case .euCloud: .euCloud
        case .selfHosted:
            {
                let trimmed = selfHostedHost.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: trimmed), url.host() != nil, url.scheme != nil else {
                    return nil
                }
                return .selfHosted(url)
            }()
        }
    }

    var canConnect: Bool {
        !trimmedKey.isEmpty && resolvedRegion() != nil
    }
}

/// The screen the `.onboarding` phase lands on.
///
/// The system does the heavy lifting: a `SecureField` on tvOS raises the grid
/// keyboard *and* the "Type with iPhone" proxy without any code at all, which
/// is the only humane way to enter a 47-character key with a remote. This
/// view's job is the honesty around it — where the key rests, what happens if
/// it stops working, and the way out for someone who just wants to look.
struct TVKeyEntryView: View {
    @Environment(AppModel.self) private var model

    @State private var entry = TVKeyEntryModel()
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header

                SecureField("Personal API key", text: $entry.key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Personal API key")

                Picker("PostHog", selection: $entry.region) {
                    ForEach(TVRegionChoice.allCases, id: \.self) { choice in
                        Text("\(choice.title) — \(choice.subtitle)").tag(choice)
                    }
                }

                if entry.region == .selfHosted {
                    TextField("https://posthog.example.com", text: $entry.selfHostedHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Self-hosted address")
                }

                // Both the error thrown by this attempt and the one a stored
                // credential failed with on launch. A key that worked yesterday
                // and stopped lands here with its explanation, exactly as on
                // iOS, rather than dropping the user on an empty form.
                if let message = error ?? model.connectionError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Status.criticalInk)
                }

                HStack(spacing: Theme.Space.m) {
                    Button {
                        connect()
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Text("Connect")
                            if isConnecting {
                                ProgressView()
                                    .accessibilityLabel("Connecting")
                            }
                        }
                    }
                    .disabled(!entry.canConnect || isConnecting)

                    Button("Browse the demo") {
                        Task { await model.enterDemo() }
                    }
                    .disabled(isConnecting)
                }

                Text(Self.storageFootnote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1_100, alignment: .leading)
        }
        .background(Theme.pageBackground)
    }

    /// Names where the key rests, in the same words `SettingsRoot`'s tvOS
    /// footer uses — one statement of one fact, not two that could drift.
    ///
    /// "Available after the first unlock" is the accessibility class the kit
    /// stores tvOS credentials under: an Apple TV has no lock screen to unlock
    /// interactively, so a class that waits for one would leave the app unable
    /// to read its own key.
    static let storageFootnote =
        "Stored in this device's Keychain, available after the first unlock, and never synced or uploaded."

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // The drawn accent rather than `BrandMarkView`: the mark is an
            // asset catalog image, and this target copies only the demo
            // fixtures out of `GetHog/Resources`.
            BrandConnectingAccent()
            Text("Connect this Apple TV to PostHog")
                .font(Theme.Typography.title)
            Text("A personal API key from your PostHog account settings. Press the field to type with the remote, or with your iPhone when it offers.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private func connect() {
        guard let region = entry.resolvedRegion() else { return }
        let key = entry.trimmedKey
        isConnecting = true
        error = nil
        Task {
            do {
                try await model.connect(key: key, region: region)
            } catch {
                self.error = (error as? PostHogError)?.localizedDescription
                    ?? error.localizedDescription
            }
            isConnecting = false
        }
    }
}
