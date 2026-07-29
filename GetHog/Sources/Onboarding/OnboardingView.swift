import GetHogKit
import SwiftUI

/// The highest-friction moment in the app.
///
/// The known failure of personal API keys is that scopes are chosen by the user,
/// so a wrong key produces opaque 403s later. This flow front-loads the exact
/// scope list, deep-links to the key page, and verifies before letting the user in.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var step: Step = .welcome
    @State private var region: PostHogRegion = .usCloud
    @State private var selfHostedURL = ""
    @State private var apiKey = ""
    @State private var isConnecting = false
    @State private var error: String?

    private enum Step { case welcome, region, key }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome: welcome
                case .region: regionPicker
                case .key: keyEntry
                }
            }
            .padding()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)

            VStack(spacing: 8) {
                Text("GetHog")
                    .font(.largeTitle.bold())
                Text("Your PostHog dashboards, events, sessions, and feature flags — native on iPhone and iPad.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // Trademark distance, stated up front rather than buried.
            Text("GetHog is a third-party app and operates independently from PostHog.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Get started") { step = .region }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    // MARK: - Region

    private var regionPicker: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Where is your PostHog?")
                .font(.title2.bold())

            VStack(spacing: 12) {
                regionOption(.usCloud, subtitle: "us.posthog.com")
                regionOption(.euCloud, subtitle: "eu.posthog.com")

                VStack(alignment: .leading, spacing: 8) {
                    Label("Self-hosted", systemImage: "server.rack")
                        .font(.headline)
                    TextField("https://posthog.example.com", text: $selfHostedURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Personal API keys are the only way to reach a self-hosted instance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Theme.cardBackground, in: .rect(cornerRadius: 12))
            }

            Spacer()

            Button("Continue") {
                if !selfHostedURL.isEmpty, let url = normalizedSelfHostedURL() {
                    region = .selfHosted(url)
                }
                step = .key
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!selfHostedURL.isEmpty && normalizedSelfHostedURL() == nil)
        }
    }

    private func regionOption(_ option: PostHogRegion, subtitle: String) -> some View {
        Button {
            region = option
            selfHostedURL = ""
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if region == option && selfHostedURL.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding()
            .background(Theme.cardBackground, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func normalizedSelfHostedURL() -> URL? {
        var text = selfHostedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    // MARK: - Key entry

    private var keyEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Add your personal API key")
                    .font(.title2.bold())

                Text("GetHog stores your key in the Keychain on this device only. It's never uploaded anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                SecureField("phx_…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())

                scopeChecklist

                Link(destination: region.apiKeySettingsURL) {
                    Label("Create a key in PostHog", systemImage: "arrow.up.forward.square")
                        .font(.subheadline.weight(.medium))
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.Status.critical)
                }

                Button {
                    Task { await connect() }
                } label: {
                    if isConnecting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(apiKey.isEmpty || isConnecting)
            }
        }
    }

    /// The exact scopes to tick, copyable so the user doesn't have to transcribe.
    private var scopeChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tick these scopes when creating the key")
                .font(.subheadline.weight(.semibold))

            ForEach(Self.requiredScopes, id: \.self) { scope in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.tertiary)
                    Text(scope)
                        .font(.footnote.monospaced())
                    Spacer()
                }
            }

            Button {
                UIPasteboard.general.string = Self.requiredScopes.joined(separator: "\n")
            } label: {
                Label("Copy scope list", systemImage: "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
        }
        .padding()
        .background(Theme.cardBackground, in: .rect(cornerRadius: 12))
    }

    private static let requiredScopes: [String] = {
        var scopes = Set<String>()
        for capability in Capability.allCases {
            scopes.formUnion(capability.requiredScopes)
            if let write = capability.writeScope { scopes.insert(write) }
        }
        scopes.insert("project:read")
        return scopes.sorted()
    }()

    private func connect() async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }

        do {
            try await model.connect(key: apiKey, region: region)
        } catch let phError as PostHogError {
            error = phError.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
