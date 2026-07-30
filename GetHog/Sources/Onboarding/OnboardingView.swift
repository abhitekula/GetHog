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
            // Every step scrolls, not just key entry. The welcome step stacks a
            // 104pt tile, a large-title wordmark, three highlight rows and a
            // footer above "Get started"; at accessibility text sizes that
            // overflowed a fixed frame and put the only button on the first
            // screen out of reach, so first launch could not be completed at all.
            //
            // The minimum height is what lets the steps keep their own `Spacer`s:
            // inside a plain ScrollView a Spacer collapses to its minimum and the
            // welcome step would bunch against the top at ordinary sizes.
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        switch step {
                        case .welcome: welcome
                        case .region: regionPicker
                        case .key: keyEntry
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            // Cards use the grouped card colour, which is white in light mode —
            // without the grouped page behind them the whole flow reads as flat.
            .background(Theme.pageBackground)
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(.snappy) { step = step == .key ? .region : .welcome }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
            }
            .animation(.snappy, value: step)
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 20) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 104, height: 104)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 26))

                VStack(spacing: 10) {
                    Text("GetHog")
                        .font(.largeTitle.bold())
                    Text("Your PostHog dashboards, events, sessions, and feature flags — native on iPhone and iPad.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }

            Spacer(minLength: 24)

            VStack(spacing: 16) {
                ForEach(Self.highlights, id: \.title) { item in
                    HStack(spacing: 14) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30)
                            .background(Theme.accent.opacity(0.12), in: .circle)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Spacer(minLength: 24)

            VStack(spacing: 14) {
                // Trademark distance, stated up front rather than buried.
                Text("GetHog is a third-party app and operates independently from PostHog.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Button {
                    step = .region
                } label: {
                    Text("Get started").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private static let highlights: [(icon: String, title: String, detail: String)] = [
        ("square.grid.2x2", "Your real dashboards",
         "Saved tiles rendered natively — not rebuilt metric by metric."),
        ("rectangle.stack", "Session replay",
         "Watch web sessions and read the full event timeline."),
        ("lock.shield", "Stays on your device",
         "Your key lives in the Keychain. There's no backend."),
    ]

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

    /// No ScrollView of its own — the whole `Group` scrolls now, and nesting one
    /// scroll view inside another leaves this step with two competing gestures.
    private var keyEntry: some View {
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
                    .foregroundStyle(Theme.Status.criticalInk)
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

            Spacer(minLength: 0)
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
