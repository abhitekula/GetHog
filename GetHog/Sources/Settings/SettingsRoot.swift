import GetHogUI
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import GetHogKit
import SwiftUI
import TipKit

/// Account, permissions, and limits.
///
/// Settings carries more weight in this app than in most. Two facts decide
/// whether GetHog works correctly and neither is visible anywhere else: the
/// scopes the user happened to tick when creating their key, and the fact that
/// the rate-limit budget being spent is organization-wide. Both are stated
/// plainly here rather than buried under "Advanced".
///
/// The sections are views of their own rather than computed properties of this
/// screen, because the Mac has a second container for them: `MacSettingsRoot`
/// regroups the same nine into the four panes of a ⌘, window. One set of
/// sections, two arrangements — written twice they would drift, and the
/// difference would only ever show up on one of the two platforms.
struct SettingsRoot: View {
    @Environment(AppModel.self) private var model

    /// Owned here rather than inside the cards so a row scrolling out of view
    /// and back does not discard what was already paid for. The *loading* is
    /// still triggered from the rows — see `QuotaSpendCard` — because that is
    /// what makes it lazy; only the results live at this level.
    @State private var quotaStore = QuotaStore()
    @State private var sdkHealthStore = SDKHealthStore()

    var body: some View {
        List {
            SettingsAccountSection()
            SettingsProjectSection()
            #if !os(tvOS)
            // Alerts/ is not compiled into the tvOS target: the platform cannot
            // present the notification these settings configure, and this
            // section's footer promises background delivery it could not make
            // good on.
            SettingsAlertsSection()
            // Nothing on tvOS to arrange. There is no tab-slot preference, no
            // `TabViewCustomization` (unavailable on the platform), and the
            // sidebar is fixed — so this section would be a preferences row
            // that controls nothing, which this file's own comments call a bug
            // report waiting to happen.
            SettingsNavigationSection()
            #endif
            SettingsPermissionsSection()
            SettingsAPIKeySection()
            #if os(iOS)
            // Sends the key the section above describes. iOS only:
            // WatchConnectivity exists on iPhone and watchOS, nowhere else this compiles.
            SettingsWatchSection()
            #endif
            SettingsUsageSection(quotaStore: quotaStore)
            SettingsSDKHealthSection(store: sdkHealthStore)
            SettingsAboutSection()
        }
        .listStyle(.insetGrouped)
        .pageSurface()
        // Phones and tablets keep the iPad-derived readable measure. A TV row
        // needs the wider, viewing-distance-aware measure so identifiers stay
        // intact instead of wrapping while most of the canvas sits unused.
        .measuredPairs(maxWidth: pairMeasure)
        .navigationTitle("Settings")
        // No `ProjectSwitcher()` here: the Project section below already is
        // the switcher, and two controls for one piece of state on one
        // screen is a bug report waiting to happen.
        .task { AppTips.refresh(from: model) }
    }

    private var pairMeasure: CGFloat {
        #if os(tvOS)
        Theme.Measure.televisionPair
        #else
        Theme.Measure.pair
        #endif
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

// MARK: - Account

struct SettingsAccountSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            // Not one word in these rows is prose. Every value is a name, an
            // address, an organization or a region — and a `LabeledContent`
            // stacks its value under its label at accessibility sizes, so at AX5
            // the value wraps and the hyphenation dictionary gets its chance.
            // Measured here: sample.user@example.org`, which is not this user's
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
}

// MARK: - Project

struct SettingsProjectSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            // `AppTipView` rather than `TipView`, for the contrast measured on
            // the Flags card — see `AppTipView`. **Not observed here**: this tip
            // needs `ProjectSwitchTip.hasMultipleProjects`, and the demo fixture
            // has one project, so it does not appear in any captured screenshot
            // of this screen. It is the same view with the same style, which is
            // the whole reason the style is not written twice.
            AppTipView(ProjectSwitchTip())
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
}

// MARK: - Alerts

// The whole section, not just its call site in `SettingsRoot`: the screen it
// links to lives in `Alerts/`, which the tvOS target does not compile at all
// because that platform cannot present the notification an alert exists to
// send. Compiling a section whose only row is a dead link would be a promise
// this platform cannot keep.
#if !os(tvOS)
struct SettingsAlertsSection: View {
    var body: some View {
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
}
#endif

// MARK: - Navigation

/// Where the tab bar is arranged - on a phone.
///
/// Absent on iPad, and replaced by a line pointing at the system's own
/// control: there the sidebar is rearranged by SwiftUI's Edit button and
/// this preference is not read at all. Showing an inert row would be worse
/// than showing none, because a preference that does nothing reads as a bug
/// in the app rather than as a choice about it.
///
/// The idiom check matches `RootView.isPad` deliberately - that is the one
/// thing deciding which of the two stores a device uses, and a second rule
/// here could disagree with it.
///
/// The Mac says something different again, and it has to: there is no Edit
/// button above a `.sidebarAdaptable` sidebar on macOS — the arrangement is
/// changed by dragging rows and hiding them from their context menus — and
/// the pane this section sits in carries the reset button that undoes it.
///
/// visionOS is the iPad's sentence, not the Mac's: the Vision shell renders
/// the system's Edit button in the sidebar header, which is visible in the
/// screenshot that pinned that shell's shape. It fell to the Mac's wording
/// only because the `#else` was written before there was a third platform.
///
/// tvOS never mounts this section at all — `SettingsRoot` leaves it out there
/// — because none of the three arrangements exists on that platform.
struct SettingsNavigationSection: View {
    @Environment(NavPreferences.self) private var nav

    var body: some View {
        Section {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                Text("Rearrange the sidebar with Edit, at the top of the sidebar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    TabBarSettingsView()
                } label: {
                    LabeledContent("Tab bar", value: nav.barTabs.map(\.title).joined(separator: ", "))
                }
            }
            #elseif os(visionOS)
            Text("Rearrange the sidebar with Edit, at the top of the sidebar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #elseif os(macOS)
            Text("Drag sidebar rows to reorder them, and hide a row from its own context menu.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        } header: {
            SectionLabel(text: "Navigation", systemImage: "square.grid.2x2")
        }
    }
}

// MARK: - Permissions

struct SettingsPermissionsSection: View {
    @Environment(AppModel.self) private var model

    @State private var isRechecking = false

    var body: some View {
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
            Text("Scopes are chosen when you create a personal API key. Add a missing one in PostHog, then re-check.")
        }

        if !APIKeyScopeGuidance.currentPlatformOptionalWriteActions.isEmpty {
            Section {
                ForEach(APIKeyScopeGuidance.currentPlatformOptionalWriteActions) { descriptor in
                    LabeledContent(descriptor.action) {
                        Text(descriptor.scope)
                            .font(.footnote.monospaced())
                            .typesettingLanguage(Locale.Language(identifier: "zxx"))
                            #if os(tvOS)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            #endif
                    }
                }
            } header: {
                SectionLabel(text: "Optional write actions", systemImage: "pencil.and.outline")
            } footer: {
                Text("Core read scopes support GetHog's main read surfaces. Add a write scope only when you intend to use its action; write access is not probed in advance.")
            }
        }
    }
}

// MARK: - API key

struct SettingsAPIKeySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var maskedKey = ""
    @State private var revealedKey: String?
    @State private var revealError: String?
    @State private var isConfirmingSignOut = false

    // Sensor names are user-facing hardware claims. Keep each platform's
    // spelling here, where the Vision suite can pin that a headset never
    // promises a phone or Mac sensor. tvOS has no device-owner authentication
    // at all, so its copy names the only replacement route the screen offers.
    #if os(macOS)
    static let keyStorageFooter = "The key is stored in this device's Keychain, marked device-only, and never synced or uploaded. Revealing it asks for Touch ID or your password, and it re-hides itself after 30 seconds."
    #elseif os(visionOS)
    static let keyStorageFooter = "The key is stored in this device's Keychain, marked device-only, and never synced or uploaded. Revealing it asks for Optic ID or your passcode, and it re-hides itself after 30 seconds."
    #elseif os(tvOS)
    static let keyStorageFooter = "The key is stored in this device's Keychain and never synced or uploaded. Apple TV can't verify it's you, so the key can't be revealed here — sign out and enter a new one to replace it."
    #else
    static let keyStorageFooter = "The key is stored in this device's Keychain, marked device-only, and never synced or uploaded. Revealing it asks for Face ID, Touch ID, or your passcode, and it re-hides itself after 30 seconds."
    #endif

    /// A revealed key re-masks itself rather than sitting on a screen the user
    /// walked away from.
    private static let revealTimeout: Duration = .seconds(30)

    var body: some View {
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
            // These four sat on the whole `List` while this section was a
            // property of it. On the row they behave the same and reach further:
            // the row is present wherever the section is, so the Mac's Settings
            // window gets the timeout and the scene-phase re-mask for free. The
            // one difference is that scrolling the row out of view now also
            // re-masks a revealed key, which is strictly the safer direction.
            .task { loadMaskedKey() }
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
                Button("Sign out", role: .destructive) {
                    #if os(iOS)
                    // A queued transfer outlives the keychain entry sign-out is
                    // about to delete, so discard its old bearer key first.
                    WatchHandoffController().cancelQueued()
                    #endif
                    model.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your API key is deleted from this device's Keychain and the cached data is cleared. You'll need the key again to sign back in.")
            }

            #if !os(tvOS)
            // Revealing is gated on device-owner authentication, and tvOS has
            // none to offer — `LAContext`'s policies are unavailable there. A
            // Reveal button that skipped the gate would put a live credential
            // on a screen in a shared room with nothing asked of anybody, so
            // the affordance is absent rather than unguarded. The footer below
            // says so in words.
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
            #endif

            if let revealError {
                Label(revealError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.Status.criticalInk)
            }

            #if !os(tvOS)
            // Nowhere to open it. The tvOS footer below already names the one
            // route that exists on this platform — sign out and enter a new
            // key — rather than offering a row that leads nowhere.
            if let url = model.client?.region.apiKeySettingsURL {
                Link(destination: url) {
                    Label("Manage keys in PostHog", systemImage: "arrow.up.forward.square")
                }
            }
            #endif

            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            SectionLabel(text: "API key", systemImage: "lock")
        } footer: {
            Text(Self.keyStorageFooter)
        }
    }

    private func loadMaskedKey() {
        guard let key = try? model.store.load()?.key else { return }
        maskedKey = SettingsRoot.mask(key)
    }

    #if !os(tvOS)
    private func reveal() async {
        revealError = nil
        do {
            // Lower-cased on the Mac for the same reason `BiometricGate.reason`
            // forks: macOS prepends "GetHog is trying to", and the clause has
            // to read as part of that sentence. iOS and visionOS present the
            // reason as its own line, so they share the imperative register.
            #if os(macOS)
            let reason = "reveal your PostHog API key"
            #else
            let reason = "Reveal your PostHog API key"
            #endif
            guard try await DeviceOwnerGate.authenticate(reason: reason) else {
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
    #endif
}

// MARK: - Usage & limits

/// One section, two budgets, deliberately in that order.
///
/// The plan quota is what PostHog meters and bills the organization for; the
/// rate-limit meter under it is GetHog's own share of a *different*
/// organization-wide allowance. They were built at different times for
/// different reasons, but a reader arriving here is asking one question —
/// what is this costing us — and answering it in two unrelated places, with
/// two different colour languages, would make the smaller of the two look
/// like the whole story. So they share a section, a palette and a footer,
/// and the footer's job is to say which is which.
struct SettingsUsageSection: View {
    @Environment(AppModel.self) private var model

    /// Owned by the container rather than here, for the reason `SettingsRoot`
    /// records: a row scrolling out of view and back must not discard what was
    /// already paid for.
    let quotaStore: QuotaStore

    @State private var cacheBytes: Int64 = 0

    var body: some View {
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
            .task { await loadCacheSize() }

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
            // per organization, so requests this app makes come out of the same
            // allowance the user's production integrations depend on.
            Text("Two allowances, both counted per organization. The quota above is what PostHog meters your plan against; the meter below it is GetHog's own share of PostHog's rate limits — the same budget your production integrations spend. The app paces itself well below the published limits and caches responses on this device, so revisiting a dashboard doesn't cost your team another request.")
        }
    }

    private func loadCacheSize() async {
        cacheBytes = Int64(await model.cache.totalSizeBytes())
    }

    private func clearCache() async {
        await model.cache.clear()
        await loadCacheSize()
    }
}

// MARK: - SDK health

struct SettingsSDKHealthSection: View {
    let store: SDKHealthStore

    var body: some View {
        Section {
            SDKHealthCard(store: store)
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
}

// MARK: - About

struct SettingsAboutSection: View {
    var body: some View {
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

// The whole gate is absent on tvOS: `LAPolicy`, `canEvaluatePolicy` and
// `evaluatePolicy` are unavailable there, and the one caller — the Reveal
// button — is absent for the same reason.
#if !os(tvOS)
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
#endif
