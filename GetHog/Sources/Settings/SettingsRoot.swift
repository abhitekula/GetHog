import LocalAuthentication
import GetHogKit
import SwiftUI

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

    /// A revealed key re-masks itself rather than sitting on a screen the user
    /// walked away from.
    private static let revealTimeout: Duration = .seconds(30)

    var body: some View {
        NavigationStack {
            List {
                accountSection
                projectSection
                permissionsSection
                apiKeySection
                dataSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            // No `ProjectSwitcher()` here: the Project section below already is
            // the switcher, and two controls for one piece of state on one
            // screen is a bug report waiting to happen.
            .task {
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
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
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
    }

    // MARK: - Project

    private var projectSection: some View {
        Section {
            Picker("Project", selection: Binding(
                get: { model.selectedProject?.id ?? -1 },
                set: { id in model.selectedProject = model.projects.first { $0.id == id } }
            )) {
                ForEach(model.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
        } header: {
            Text("Project")
        } footer: {
            // Timezone is not trivia: it sets every chart's day boundary, so the
            // same query can disagree with a tool configured to local time.
            Text("Charts and event timestamps follow the project's timezone, \(model.selectedProject?.timezone ?? "UTC"). Days start and end there, not on this device.")
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
            Text("Permissions")
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
                    .foregroundStyle(Theme.Status.critical)
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
            Text("API key")
        } footer: {
            Text("The key is stored in this device's Keychain, marked device-only, and never synced or uploaded. Revealing it asks for Face ID, Touch ID, or your passcode, and it re-hides itself after 30 seconds.")
        }
    }

    // MARK: - Data & limits

    private var dataSection: some View {
        Section {
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
            Text("Data & limits")
        } footer: {
            // The whole reason this meter exists. PostHog's limits are counted
            // per organisation, so requests this app makes come out of the same
            // allowance the user's production integrations depend on.
            Text("PostHog's rate limits are organisation-wide — the same budget your own production integrations spend. GetHog paces itself well below the published limits and caches responses on this device, so revisiting a dashboard doesn't cost your team another request.")
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

    private var tint: Color {
        switch status {
        case .available: Theme.Status.good
        case .locked: .orange
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(capability.title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
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
