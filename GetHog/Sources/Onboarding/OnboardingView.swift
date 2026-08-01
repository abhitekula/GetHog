import GetHogKit
import SwiftUI

/// The highest-friction moment in the app.
///
/// The known failure of personal API keys is that scopes are chosen by the user,
/// so a wrong key produces opaque 403s later. This flow front-loads the exact
/// scope list, links directly to the key page, and verifies before letting the user in.
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
                // A generic SF Symbol, deliberately — no PostHog logo or
                // wordmark appears anywhere in this app — and hidden, because
                // the wordmark directly beneath it already names the app.
                //
                // Without the hiding this was the *first thing VoiceOver said on
                // first launch*: "chart.xyaxis.line". `AboutView` draws the same
                // glyph for the same reason and has always hidden it; this one
                // was simply missed, and no test could have caught it, because
                // every screen in the audit sweep is reached through demo mode
                // and demo mode supplies a credential that puts the app straight
                // past onboarding. `AccessibilityAuditTests.testOnboarding` is
                // the case that closes that, and it has to launch without
                // `-GetHogDemo` to do it.
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 104, height: 104)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 26))
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("GetHog")
                        .font(.largeTitle.bold())
                    // On `Theme.Ink`, not SwiftUI's ramp, and for the measured
                    // reason `Theme.Ink` records: the system's `.secondary` is
                    // an alpha composite, so on this screen's `#F2EFE9` ground
                    // it lands at 3.26:1 and on a card at 3.44:1 — both under
                    // the 4.5:1 floor. Every supporting line on this flow is on
                    // one of those two surfaces, and this is the first screen
                    // anybody sees.
                    Text("Your PostHog dashboards, events, sessions, and feature flags — native on iPhone and iPad.")
                        .font(.callout)
                        .foregroundStyle(Theme.Ink.secondary)
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
                                .foregroundStyle(Theme.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    // Replaced rather than combined, and the difference is
                    // measured rather than stylistic.
                    //
                    // `.accessibilityElement(children: .combine)` was here, and
                    // it *did* fold the two `Text`s into one label — while
                    // leaving all three children in the tree underneath it. Two
                    // of the three rows therefore published a stop labelled
                    // `rectangle.stack` and `lock.shield`; the third read "Grid
                    // View", because SF Symbols ships a description for that
                    // glyph and not for the others, which is the only reason it
                    // looked fine. Adding `.accessibilityHidden(true)` to the
                    // image changed nothing at all: measured before and after,
                    // both glyphs were still there.
                    //
                    // Combining makes this row a *container*, and a container's
                    // children are enumerated from what was rendered rather than
                    // from SwiftUI's accessibility nodes — so a child's
                    // suppression is never consulted. The dashboard tile has the
                    // same defect for the same reason, from a different cause
                    // (a chart's `AXChartDescriptor`), and takes the same
                    // answer: replace the subtree, do not try to edit it.
                    //
                    // The replacement says exactly what `.combine` said, so the
                    // row still reads as one stop with both lines in it.
                    .accessibilityRepresentation {
                        VStack {
                            Text(item.title)
                            Text(item.detail)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Spacer(minLength: 24)

            VStack(spacing: 14) {
                // Trademark distance, stated up front rather than buried — and
                // therefore the one line on this screen that has to be readable
                // whether or not anybody wants to read it.
                //
                // It was the least readable text in the app. Measured on the
                // rendered screen: `.tertiary` composites to `#BCBAB8` on the
                // `#F2EFE9` ground for **1.69:1**, against a 4.5:1 floor.
                // `Ink.secondary` rather than `Ink.tertiary`, because a
                // disclaimer is not supporting detail — nothing about it should
                // recede.
                Text("GetHog is a third-party app and operates independently from PostHog.")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    step = .region
                } label: {
                    Text("Get started").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // **The label, not the tint.** `.borderedProminent` draws a
                // white label over the app tint, and the app tint is a colour
                // chosen for *ink on the ground* rather than for a slab: in
                // dark, `Theme.accent` is `#3EC5CE`, and white on it measured
                // **2.08:1** on the rendered screen — under half the 4.5:1 AA
                // floor, on the only button first launch has. Light was fine at
                // 6.00:1, which is why this survived a light-only reading.
                //
                // Darkening the tint is the wrong lever: `Theme.accent` is the
                // one colour the whole app is keyed to, including the widget
                // target, and it would be moved here to settle an argument about
                // a label.
                //
                // This was `Theme.pageBackground` — correct in dark and a
                // measured *regression* in light, where `#F2EFE9` on `#0B6E75`
                // is 5.23:1 against white's 6.00:1. `Theme.inkOnAccent` is the
                // same answer written once, and it keeps white in light: on a
                // slab this dark, light ink is not a preference, it is the only
                // side of the ramp that can clear AA at all.
                .foregroundStyle(Theme.inkOnAccent)
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
                        .foregroundStyle(Theme.Ink.secondary)
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
            // Same 2.08:1 measurement as "Get started"; see there, and
            // `Theme.inkOnAccent`.
            .foregroundStyle(Theme.inkOnAccent)
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
                    Text(subtitle).font(.caption).foregroundStyle(Theme.Ink.secondary)
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
                .foregroundStyle(Theme.Ink.secondary)

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
            // Same 2.08:1 measurement as "Get started"; see there, and
            // `Theme.inkOnAccent`.
            .foregroundStyle(Theme.inkOnAccent)
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
                    // A tick beside a scope the user has to find and switch on is
                    // a meaningful graphic, so it owes WCAG's 3:1 for non-text;
                    // `.tertiary` gave it 1.73:1 on this card.
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Theme.Ink.tertiary)
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
