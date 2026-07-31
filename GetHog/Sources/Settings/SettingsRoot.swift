import LocalAuthentication
import GetHogKit
import SwiftUI
import TipKit

/// Account, permissions, and limits.
///
/// Settings carries more weight in this app than in most. Two facts decide
/// whether GetHog works correctly and neither is visible anywhere else: the
/// scopes the user happened to tick when creating their key, and the fact that
/// the rate-limit budget being spent is organisation-wide. Both are stated
/// plainly here rather than buried under "Advanced".
struct SettingsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var maskedKey = ""
    @State private var revealedKey: String?
    @State private var revealError: String?
    @State private var isRechecking = false
    @State private var isConfirmingSignOut = false
    @State private var cacheBytes: Int64 = 0

    /// Owned here rather than inside the cards so a row scrolling out of view
    /// and back does not discard what was already paid for. The *loading* is
    /// still triggered from the rows — see `QuotaSpendCard` — because that is
    /// what makes it lazy; only the results live at this level.
    @State private var quotaStore = QuotaStore()
    @State private var sdkHealthStore = SDKHealthStore()

    /// A revealed key re-masks itself rather than sitting on a screen the user
    /// walked away from.
    private static let revealTimeout: Duration = .seconds(30)

    var body: some View {
        List {
            accountSection
            projectSection
            alertsSection
            permissionsSection
            apiKeySection
            dataSection
            sdkHealthSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .pageSurface()
        // Every label/value pair below stops at a readable measure instead of
        // spanning the window. See `Theme.Measure.pair`.
        .measuredPairs()
        .navigationTitle("Settings")
        // No `ProjectSwitcher()` here: the Project section below already is
        // the switcher, and two controls for one piece of state on one
        // screen is a bug report waiting to happen.
        .task {
            AppTips.refresh(from: model)
            loadMaskedKey()
            await loadCacheSize()
        }
        .task(id: revealedKey) {
            guard revealedKey != nil else { return }
            try? await Task.sleep(for: Self.revealTimeout)
            revealedKey = nil
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS snapshots the screen for the app switcher on the way out.
            // A revealed key must not survive into that image.
            if phase != .active { revealedKey = nil }
        }
        .confirmationDialog(
            "Sign out of GetHog?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { model.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your API key is deleted from this device's Keychain and the cached data is cleared. You'll need the key again to sign back in.")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            // Not one word in these rows is prose. Every value is a name, an
            // address, an organisation or a region — and a `LabeledContent`
            // stacks its value under its label at accessibility sizes, so at AX5
            // the value wraps and the hyphenation dictionary gets its chance.
            // Measured here: person@example.com`, which is not this user's
            // address. A reader cannot tell an invented hyphen from one that was
            // always there, and an address is the field where that distinction
            // decides whether the string is true. `zxx` is the ISO code for "no
            // linguistic content", so no dictionary applies and a line breaks
            // only where the string already allows it — the same fix, for the
            // same reason, as `RowCard`'s.
            Group {
                LabeledContent("Name", value: model.me?.displayName ?? "—")
                if let email = model.me?.email {
                    LabeledContent("Email", value: email)
                }
                if let organization = model.me?.organization?.name {
                    LabeledContent("Organization", value: organization)
                }
                if let region = model.client?.region {
                    LabeledContent("Region", value: region.displayName)
                }
            }
            .typesettingLanguage(Locale.Language(identifier: "zxx"))
        } header: {
            SectionLabel(text: "Account", systemImage: "person.crop.circle")
        }
    }

    // MARK: - Project

    private var projectSection: some View {
        Section {
            TipView(ProjectSwitchTip())
                .listRowBackground(Color.clear)
            Picker("Project", selection: Binding(
                get: { model.selectedProject?.id ?? -1 },
                set: { id in model.selectedProject = model.projects.first { $0.id == id } }
            )) {
                ForEach(model.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
        } header: {
            SectionLabel(text: "Project", systemImage: "folder")
        } footer: {
            // Timezone is not trivia: it sets every chart's day boundary, so the
            // same query can disagree with a tool configured to local time.
            Text("Charts and event timestamps follow the project's timezone, \(model.selectedProject?.timezone ?? "UTC"). Days start and end there, not on this device.")
        }
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        Section {
            NavigationLink {
                MetricAlertsView()
            } label: {
                Label("Metric alerts", systemImage: "bell.badge")
            }
        } header: {
            SectionLabel(text: "Alerts", systemImage: "bell.badge")
        } footer: {
            // Stated here as well as on the screen itself, because a Settings
            // row called "alerts" is exactly where someone forms the assumption
            // that this app watches their numbers continuously. It does not.
            Text("Thresholds on the metrics your widgets already read, checked when iOS wakes the app in the background. Notices arrive late rather than live, and nothing is sent to a server — the check runs on this device.")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            ForEach(Capability.allCases) { capability in
                PermissionRow(
                    capability: capability,
                    status: model.capabilities?.status(capability)
                )
            }

            Button {
                Task {
                    isRechecking = true
                    await model.refreshCapabilities()
                    isRechecking = false
                }
            } label: {
                HStack {
                    Label("Re-check permissions", systemImage: "arrow.clockwise")
                    if isRechecking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRechecking || model.client == nil)
        } header: {
            SectionLabel(text: "Permissions", systemImage: "key")
        } footer: {
            Text("Scopes are chosen when you create a personal API key. Add a missing one in PostHog, then re-check.\n\nToggling a flag also needs `feature_flag:write`, which PostHog only reveals on the first toggle attempt — it can't be probed here.")
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Personal API key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(revealedKey ?? maskedKey)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel(
                        revealedKey == nil
                            // Bullets are read out one by one by VoiceOver.
                            ? "API key hidden, ending in \(maskedKey.suffix(4))"
                            : "API key revealed"
                    )
            }

            if revealedKey == nil {
                Button {
                    Task { await reveal() }
                } label: {
                    Label("Reveal key", systemImage: "eye")
                }
                .disabled(maskedKey.isEmpty)
            } else {
                Button {
                    revealedKey = nil
                } label: {
                    Label("Hide key", systemImage: "eye.slash")
                }
            }

            if let revealError {
                Label(revealError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.Status.criticalInk)
            }

            if let url = model.client?.region.apiKeySettingsURL {
                Link(destination: url) {
                    Label("Manage keys in PostHog", systemImage: "arrow.up.forward.square")
                }
            }

            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            SectionLabel(text: "API key", systemImage: "lock")
        } footer: {
            Text("The key is stored in this device's Keychain, marked device-only, and never synced or uploaded. Revealing it asks for Face ID, Touch ID, or your passcode, and it re-hides itself after 30 seconds.")
        }
    }

    // MARK: - Usage & limits

    /// One section, two budgets, deliberately in that order.
    ///
    /// The plan quota is what PostHog meters and bills the organisation for; the
    /// rate-limit meter under it is GetHog's own share of a *different*
    /// organisation-wide allowance. They were built at different times for
    /// different reasons, but a reader arriving here is asking one question —
    /// what is this costing us — and answering it in two unrelated places, with
    /// two different colour languages, would make the smaller of the two look
    /// like the whole story. So they share a section, a palette and a footer,
    /// and the footer's job is to say which is which.
    private var dataSection: some View {
        Section {
            QuotaSpendCard(store: quotaStore)
                // Full-bleed so the card's own `StatStrip` supplies the inset;
                // otherwise the strip is indented past every other row.
                .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: 0, bottom: Theme.Space.s, trailing: 0))

            RateLimitUsageView(client: model.client)

            LabeledContent("Cached data") {
                Text(cacheBytes, format: .byteCount(style: .file))
                    .monospacedDigit()
            }

            Button {
                Task { await clearCache() }
            } label: {
                Label("Clear cache", systemImage: "trash")
            }
            .disabled(cacheBytes == 0)
        } header: {
            SectionLabel(text: "Usage & limits", systemImage: "gauge.with.needle")
        } footer: {
            // The whole reason both meters exist. PostHog's limits are counted
            // per organisation, so requests this app makes come out of the same
            // allowance the user's production integrations depend on.
            Text("Two allowances, both counted per organisation. The quota above is what PostHog meters your plan against; the meter below it is GetHog's own share of PostHog's rate limits — the same budget your production integrations spend. The app paces itself well below the published limits and caches responses on this device, so revisiting a dashboard doesn't cost your team another request.")
        }
    }

    // MARK: - SDK health

    private var sdkHealthSection: some View {
        Section {
            SDKHealthCard(store: sdkHealthStore)
        } header: {
            SectionLabel(text: "SDK health", systemImage: "shippingbox")
        } footer: {
            // Says out loud that the judgement is not this app's. Without it the
            // card reads as GetHog grading the user's SDKs, and the first
            // time it disagreed with the web console the app would be the one
            // assumed wrong.
            Text("PostHog decides this, not GetHog. Release grace periods, version-gap and age rules, and each version's share of traffic are all applied on PostHog's servers; this card shows the verdict and PostHog's own wording for it. The check re-runs roughly daily, so an SDK you have just upgraded can stay listed for about a day.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label("About GetHog", systemImage: "info.circle")
            }
        } footer: {
            Text("GetHog is a third-party app and operates independently from PostHog.")
        }
    }

    // MARK: - Actions

    private func loadMaskedKey() {
        guard let key = try? model.store.load()?.key else { return }
        maskedKey = Self.mask(key)
    }

    private func reveal() async {
        revealError = nil
        do {
            guard try await DeviceOwnerGate.authenticate(
                reason: "Reveal your PostHog API key"
            ) else {
                revealError = "Authentication was cancelled."
                return
            }
            // Read from the Keychain on demand rather than holding the plaintext
            // in view state, so it exists in the view only while it is on screen.
            revealedKey = try model.store.load()?.key
        } catch {
            revealError = error.localizedDescription
        }
    }

    private func loadCacheSize() async {
        cacheBytes = Int64(await model.cache.totalSizeBytes())
    }

    private func clearCache() async {
        await model.cache.clear()
        await loadCacheSize()
    }

    /// `phx_••••••••4f21` — enough to tell two keys apart without exposing one.
    static func mask(_ key: String) -> String {
        let bullets = String(repeating: "•", count: 8)
        guard key.count > 8 else { return bullets }

        let head: String
        if let underscore = key.firstIndex(of: "_") {
            head = String(key[...underscore])
        } else {
            head = String(key.prefix(4))
        }
        return head + bullets + key.suffix(4)
    }
}

// MARK: - Permission row

/// One capability and the scope standing between the user and it.
private struct PermissionRow: View {
    let capability: Capability
    let status: CapabilityStatus?

    private var symbol: String {
        switch status {
        case .available: "checkmark.circle.fill"
        case .locked: "lock.fill"
        case .failed: "exclamationmark.triangle.fill"
        case nil: "circle.dashed"
        }
    }

    /// Locked takes the warm secondary rather than a raw system orange: a
    /// missing scope is something to fix, not a failure, and the app's own warm
    /// tone says that without borrowing a third traffic-light hue.
    private var tint: Color {
        switch status {
        case .available: Theme.Status.good
        case .locked: Theme.accentWarm
        case .failed: Theme.Status.critical
        case nil: .secondary
        }
    }

    private var detail: String {
        switch status {
        case .available:
            "Available"
        case .locked(let scope):
            // PostHog names the missing scope when it can; when it doesn't, the
            // documented scopes for this feature are the next best answer.
            "Missing scope: \(scope ?? capability.requiredScopes.joined(separator: ", "))"
        case .failed(let message):
            message
        case nil:
            "Not checked yet"
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            RowGlyph(systemName: symbol, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(capability.title)
                    .font(Theme.Typography.title)

                // Assembled here rather than handed to `DataRow`: a failed probe
                // puts the server's own message in this line, and a row type
                // that clips its subtitle to one line would hide the sentence
                // that says what to fix.
                Text(detail)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        // State is in the text as well as the icon, so combining the row reads
        // "Feature flags, Missing scope: feature_flag:read" in one pass.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Biometric gate

private enum DeviceOwnerGate {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// `LAContext` is not `Sendable`, so it is created and consumed entirely
    /// inside this one non-isolated call rather than being held in view state.
    ///
    /// `.deviceOwnerAuthentication` (rather than `…WithBiometrics`) keeps the
    /// passcode fallback, so a device without biometrics can still reveal the
    /// key. Requires `NSFaceIDUsageDescription` in the app's Info.plist.
    static func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var probe: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &probe) else {
            throw Unavailable(
                reason: probe?.localizedDescription
                    ?? "This device can't verify it's you, so the key stays hidden."
            )
        }
        return try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }
}
