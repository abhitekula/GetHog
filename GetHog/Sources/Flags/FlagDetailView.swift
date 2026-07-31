import GetHogKit
import SwiftUI

/// The only place in the app where a feature flag can be changed.
///
/// Everything dangerous is concentrated here on purpose: reaching the switch
/// costs a deliberate tap into a flag, the switch itself does nothing until a
/// confirmation dialog is answered, and an optional device-owner check can sit
/// in front of that.
struct FlagDetailView: View {
    let flag: FeatureFlag
    let controller: FlagToggleController

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Direction of the change being confirmed. Never cleared on dismissal, so
    /// the dialog's wording doesn't flicker while it animates away.
    @State private var requestedActivation = false
    @State private var isConfirming = false
    @State private var allowsQuickToggle: Bool

    init(flag: FeatureFlag, controller: FlagToggleController) {
        self.flag = flag
        self.controller = controller
        _allowsQuickToggle = State(initialValue: FlagQuickToggle.isAllowed(flagID: flag.id))
    }

    private var isActive: Bool { controller.effectiveActive(flag) }
    private var isBusy: Bool { controller.isBusy(flag) }

    /// This flag's page in the console, shared by the toolbar link and the
    /// Handoff activity so the two can't name different pages.
    private var webURL: URL? { model.webURL(path: "feature_flags/\(flag.id)") }

    var body: some View {
        List {
            identitySection
            reachRow
            toggleSection
            quickToggleSection
            releaseConditionsSection
            if flag.isMultivariate { variantsSection }
        }
        .pageSurface()
        .navigationTitle(flag.key)
        // Inline only where inline is free. On iPhone the title shares the bar
        // with the back button and costs nothing, which is why that screen is a
        // single clean bar. On iPad the floating tab bar owns the centre of the
        // top bar, so an inline title on a *pushed* screen cannot go there and
        // takes a row of its own — measured at ~90pt spent centring one string,
        // with the back chevron stranded far to its left and no other content in
        // the row. A standard title claims the same row and reads as the page
        // header every other iPad screen here has: leading-aligned, with the
        // project under it.
        //
        // This is the opposite correction to the one on roots, for the same
        // reason. A root forced inline *loses* its title, because it has no
        // second row to fall back to; see `ScreenChrome` in `DesignKit`.
        .navigationBarTitleDisplayMode(sizeClass == .compact ? .inline : .large)
        // Regular width only, where there is a row to put it in. Which project
        // this flag belongs to is not decoration on this screen — it is the one
        // screen in the app that writes to production, and the confirmation
        // dialog already names the project for the same reason.
        .navigationSubtitle(sizeClass == .compact ? "" : model.selectedProject?.name ?? "")
        // Titled with the key rather than the display name, for the same reason
        // the navigation bar is: the key is what the rollout conditions, the
        // confirmation dialog and the console all call this flag.
        .handoff(webURL: webURL, title: flag.key)
        .toolbar {
            if let url = webURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .accessibilityLabel("Open this flag in PostHog")
                }
            }
        }
        .confirmationDialog(
            requestedActivation ? "Enable \(flag.key)?" : "Disable \(flag.key)?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(
                requestedActivation ? "Enable for live users" : "Disable for live users",
                role: .destructive
            ) {
                commit(requestedActivation)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationDetail)
        }
        .sensoryFeedback(.success, trigger: controller.successCount)
        .sensoryFeedback(.error, trigger: controller.failureCount)
        // Offered back from the home screen icon. A flag you were just looking
        // at is the thing most likely to be worth another ten seconds.
        .onAppear {
            guard let projectID = model.projectID else { return }
            QuickActions.recordVisit(.featureFlag(id: flag.id), title: flag.key, projectID: projectID)
            QuickActions.refresh(projectID: projectID)
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(flag.key)
                    .font(.body.monospaced())
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    StatusPill(
                        text: isActive ? "Enabled" : "Disabled",
                        tint: isActive ? Theme.Status.good : Color.secondary
                    )
                    // Archived is orthogonal to on/off, and an archived flag
                    // that is still enabled is exactly the case worth naming.
                    if flag.archived {
                        StatusPill(text: "Archived", tint: Color.secondary)
                    }
                }

                // Uncapped, unlike the list rows: nothing here has to hold an
                // even height, so a long description stays whole on screen as
                // well as in speech.
                if let name = flag.name, !name.isEmpty, name != flag.key {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// How far this flag reaches, stated before the switch is in view. The
    /// numbers that decide whether flipping it is a small act or a large one
    /// should not be something the reader has to scroll for.
    private var reachRow: some View {
        StatStrip {
            // No rollout cap means everyone the conditions match, which is
            // 100% — not zero.
            MetricTile(
                label: "Rollout",
                value: FlagFormat.percent(flag.rolloutPercentage ?? 100),
                compact: true
            )
            MetricTile(
                label: "Condition sets",
                value: (flag.filters?.groups?.count ?? 0).formatted(),
                compact: true
            )
            if flag.isMultivariate {
                MetricTile(label: "Variants", value: flag.variants.count.formatted(), compact: true)
            }
        }
        // The strip is chrome, not a row: it sits on the page ground and brings
        // its own insets.
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var toggleSection: some View {
        Section {
            Toggle(isOn: activationRequest) {
                // The spinner rides in the label so the switch itself never
                // moves while a write is in flight.
                HStack(spacing: 8) {
                    Text("Flag enabled")
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving change")
                    }
                }
            }
            .disabled(isBusy)

            if let message = controller.message {
                ToggleMessageView(message: message) { controller.dismissMessage() }
            }
        } header: {
            SectionLabel(text: "Live state", systemImage: "switch.2")
        } footer: {
            Text(
                "Changing this writes to PostHog straight away and affects users in production. You'll be asked to confirm first."
            )
        }
    }

    private var quickToggleSection: some View {
        Section {
            Toggle("Allow quick toggle", isOn: $allowsQuickToggle)
                .onChange(of: allowsQuickToggle) { _, allowed in
                    FlagQuickToggle.setAllowed(allowed, flagID: flag.id)
                }
        } footer: {
            Text(
                "Off by default. Turning this on exposes \(flag.key) to Control Center and widgets, where it can be flipped without opening the app — and without the confirmation step above."
            )
        }
    }

    private var releaseConditionsSection: some View {
        Section {
            let groups = flag.filters?.groups ?? []
            if groups.isEmpty {
                Text("No conditions set. This flag applies to everyone it's evaluated for.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    ReleaseConditionRow(index: index, group: group)
                }
            }
        } header: {
            SectionLabel(text: "Release conditions", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var variantsSection: some View {
        Section {
            VariantDistributionBar(variants: flag.variants)
                .listRowSeparator(.hidden)

            ForEach(Array(flag.variants.enumerated()), id: \.element.id) { index, variant in
                VariantRow(index: index, variant: variant)
            }
        } header: {
            SectionLabel(text: "Variants", systemImage: "arrow.triangle.branch")
        }
    }

    // MARK: - Toggling

    /// Reflects the server (or our own in-flight override), and treats a tap as
    /// a *request* rather than a change: the switch springs back and only moves
    /// for real once the dialog — and any biometric gate — is satisfied.
    private var activationRequest: Binding<Bool> {
        Binding(
            get: { isActive },
            set: { desired in
                guard desired != isActive else { return }
                requestedActivation = desired
                isConfirming = true
            }
        )
    }

    private var confirmationDetail: String {
        let target = model.selectedProject.map { " in \($0.name)" } ?? ""
        let direction = requestedActivation
            ? "Everyone matching its release conditions will start getting it."
            : "Everyone currently getting it will stop."
        return "This affects live users\(target) immediately. \(direction)"
    }

    private func commit(_ desired: Bool) {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            await controller.setActive(
                desired, flag: flag, client: client, projectID: projectID
            )
        }
    }
}

/// One release condition group, rendered as a sentence plus its filters.
private struct ReleaseConditionRow: View {
    let index: Int
    let group: FlagGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Set \(index + 1)")

            // A missing rollout percentage means "no cap", not "nobody".
            Text("Rolled out to \(FlagFormat.percent(group.rolloutPercentage ?? 100)) of matching users")
                .font(.subheadline)

            let properties = group.properties ?? []
            if properties.isEmpty {
                Text("Matches everyone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(properties.enumerated()), id: \.offset) { _, property in
                    Label(property.summary, systemImage: "line.3.horizontal.decrease")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Proportional split across variants.
///
/// Decorative: it is hidden from VoiceOver because the exact percentages are
/// listed underneath, where they are readable at any Dynamic Type size.
private struct VariantDistributionBar: View {
    let variants: [FlagVariant]

    private var weights: [Double] {
        let raw = variants.map { $0.rolloutPercentage ?? 0 }
        let total = raw.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1 / Double(max(variants.count, 1)), count: variants.count)
        }
        return raw.map { $0 / total }
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(weights.enumerated()), id: \.offset) { index, weight in
                    SeriesPalette.color(at: index)
                        .frame(width: max(0, proxy.size.width * weight))
                }
            }
        }
        .frame(height: 12)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

private struct VariantRow: View {
    let index: Int
    let variant: FlagVariant

    var body: some View {
        HStack(spacing: 10) {
            // Symbol as well as colour, so a variant is identifiable without hue.
            Image(systemName: SeriesPalette.symbol(at: index))
                .font(.caption2)
                .foregroundStyle(SeriesPalette.color(at: index))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(variant.key)
                    .font(.subheadline.monospaced())
                if let name = variant.name, !name.isEmpty, name != variant.key {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text(FlagFormat.percent(variant.rolloutPercentage ?? 0))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(variant.key), \(FlagFormat.percent(variant.rolloutPercentage ?? 0)) of traffic"
        )
    }
}

/// Inline outcome of the last write attempt.
private struct ToggleMessageView: View {
    let message: FlagToggleMessage
    var onDismiss: () -> Void

    private var isFailure: Bool { message.kind == .failure }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isFailure ? Theme.Status.critical : Color.secondary)
                .accessibilityHidden(true)

            Text(message.text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.vertical, 2)
    }
}
