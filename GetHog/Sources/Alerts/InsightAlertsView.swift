import GetHogKit
import GetHogUI
import SwiftUI

/// The alerts PostHog is running on one insight — see them, set one, silence one.
///
/// This screen writes a threshold onto PostHog's servers, where PostHog evaluates
/// it on a schedule and notifies the configured subscribers. GetHog spends one
/// request to create or change it and performs no recurring local polling.
///
/// ## What has and has not been seen
///
/// Every write below is **source-derived and unexecuted**. Tests inspect the
/// request locally; the deterministic demo fixture supplies populated rows used
/// to verify presentation without sending a write to PostHog.
struct InsightAlertsView: View {
    let insight: Insight

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = InsightAlertsStore()
    @State private var controller = AlertWriteController()
    @State private var isComposing = false
    @State private var pendingSnooze: PendingSnooze?
    @State private var pendingEnable: PendingEnable?

    /// A snooze waiting on its confirmation dialog. Carries both halves because
    /// the dialog has to name the alert *and* the duration, and a `Bool` plus two
    /// loose `@State`s is how those drift apart.
    private struct PendingSnooze: Identifiable {
        let alert: InsightAlert
        let snooze: AlertSnooze?
        var id: String { "\(alert.id)-\(snooze?.rawValue ?? "wake")" }
    }

    private struct PendingEnable: Identifiable {
        let alert: InsightAlert
        let enabled: Bool
        var id: String { "\(alert.id)-\(enabled)" }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Alerts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New alert", systemImage: "plus") { isComposing = true }
                            .accessibilityLabel("New alert")
                            .disabled(!AlertableInsight.isComposable(sourceKind: insight.sourceKind))
                    }
                }
                .sheet(isPresented: $isComposing) {
                    AlertComposerView(insight: insight) { draft in
                        await create(draft)
                    }
                }
                // Confirmation before every mutating call, naming the object and
                // the direction — the `setFlagActive` precedent, which this app
                // applies to every write without exception. Never a swipe action.
                .confirmationDialog(
                    snoozeDialogTitle,
                    isPresented: Binding(
                        get: { pendingSnooze != nil },
                        set: { if !$0 { pendingSnooze = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingSnooze
                ) { pending in
                    Button(pending.snooze == nil ? "Wake it up" : "Snooze") {
                        apply(pending)
                    }
                    Button("Cancel", role: .cancel) { pendingSnooze = nil }
                } message: { pending in
                    Text(snoozeDialogMessage(pending))
                }
                .confirmationDialog(
                    enableDialogTitle,
                    isPresented: Binding(
                        get: { pendingEnable != nil },
                        set: { if !$0 { pendingEnable = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingEnable
                ) { pending in
                    Button(pending.enabled ? "Start checking" : "Pause", role: pending.enabled ? nil : .destructive) {
                        apply(pending)
                    }
                    Button("Cancel", role: .cancel) { pendingEnable = nil }
                } message: { pending in
                    Text(
                        pending.enabled
                            ? "PostHog will start evaluating \(pending.alert.displayTitle) again and e-mail its subscribers when it breaches."
                            : "PostHog will stop evaluating \(pending.alert.displayTitle) entirely. Unlike a snooze this does not expire — nobody is told until somebody starts it again."
                    )
                }
                .sensoryFeedback(.success, trigger: controller.successCount)
                .sensoryFeedback(.error, trigger: controller.failureCount)
                .sensoryFeedback(.warning, trigger: controller.filedCount)
                .task(id: model.projectID) { await load() }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if let failure = store.failure {
            // Whatever PostHog said, in PostHog's words. `/alerts/` may be
            // plan-gated or scope-gated, and this screen must never invent which.
            // `LoadFailure` carries the server's own sentence
            // for a 402, a 403 and a 400 access-control wall alike, so the screen
            // reports the wall it actually met rather than the one it expected.
            LoadFailureState(title: "Couldn't load this insight's alerts", failure: failure) {
                Task { await load() }
            }
        } else {
            list
        }
    }

    private var alerts: [InsightAlert] {
        controller.created + store.alerts
    }

    private var list: some View {
        List {
            if let message = controller.message {
                Section {
                    WriteOutcomeMessageView(message: message) { controller.dismissMessage() }
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if alerts.isEmpty && !store.isLoading {
                    emptyState
                } else {
                    ForEach(alerts) { alert in
                        row(alert)
                    }
                }
            } header: {
                SectionLabel(text: "Watching this insight", systemImage: "bell.badge")
            } footer: {
                Text(footer)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .overlay {
            if store.isLoading && alerts.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
    }

    /// Two different absences, and they are not the same sentence.
    ///
    /// "No alert is set" is a finding about the project. "PostHog cannot alert on
    /// this kind of insight" is a fact about the insight, and it is the one that
    /// explains why the New alert button is disabled — a disabled control with no
    /// reason beside it reads as a bug.
    @ViewBuilder
    private var emptyState: some View {
        if let reason = AlertableInsight.unavailableReason(sourceKind: insight.sourceKind) {
            SectionEmptyState(
                text: "Not alertable from here. \(reason)",
                systemImage: "bell.slash",
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            SectionEmptyState(
                text: "No alerts on this insight. PostHog can watch this insight's value "
                    + "and e-mail you when it crosses a line you set. It checks on its own "
                    + "schedule, whether or not this phone is on.",
                systemImage: "bell",
                actionTitle: "New alert",
                action: { isComposing = true }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func row(_ alert: InsightAlert) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            DataRow(
                glyph: glyph(for: alert),
                tint: tint(for: alert),
                title: alert.displayTitle,
                subtitle: thresholdLine(alert),
                footnote: alert.deliverySummary,
                // Two lines each, and both were measured needing it. Captured on
                // iPhone 17 Pro at the default type size, the one-line default
                // clipped the threshold line to
                // "Below 200 · checked daily · la…" — losing the *last value*,
                // which is the number that says whether the alert is anywhere
                // near its line. The subscriber list runs long for the same
                // reason `AutomationRoot`'s does: it is a list of names.
                subtitleLineLimit: 2,
                footnoteLineLimit: 2,
                accessory: .pill(stateText(alert), tint(for: alert))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spoken(alert))

            if let snoozeLine = snoozeLine(alert) {
                Text(snoozeLine)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            controls(alert)
        }
        .padding(.vertical, Theme.Space.xs)
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
        )
        .listRowSeparator(.hidden)
    }

    /// Labelled buttons, never a swipe. Two reasons, and the second is this app's
    /// rule: a swipe hides the action behind a gesture nobody discovers, and every
    /// mutating call here is supposed to name what it changes before it happens.
    ///
    /// **Every platform floor here is inside a label closure, and that is a
    /// measurement rather than a style.** `CLAUDE.md` records the rule for a
    /// borderless `Menu` — its tap region is its label's bounds — and notes that a
    /// bordered `.toggleStyle(.button)` fills its offered frame instead. A
    /// bordered **`Button`** turns out to behave like the `Menu`, not like the
    /// toggle: `Button(…).buttonStyle(.bordered).frame(minHeight: 44)` reported
    /// **29.67pt** through the accessibility bridge on iPhone 17 Pro
    /// (`AlertAndNarrowingTests.testInsightAlertsSheet`, 2026-07-31), with the
    /// `.font(.footnote)` on the row shrinking the intrinsic size and the outer
    /// frame merely recentring it. Nothing warns; the control looks fine and is
    /// two thirds of a fingertip. The floor has to go where the label is.
    @ViewBuilder
    private func controls(_ alert: InsightAlert) -> some View {
        HStack(spacing: Theme.Space.s) {
            if controller.isSnoozed(alert) {
                Button {
                    pendingSnooze = PendingSnooze(alert: alert, snooze: nil)
                } label: {
                    Label("Wake it up", systemImage: "bell")
                        .frame(minHeight: PlatformControlMetrics.minimumInteractiveLength)
                }
                .buttonStyle(.bordered)
            } else {
                Menu {
                    ForEach(AlertSnooze.allCases) { snooze in
                        Button(snooze.title) {
                            pendingSnooze = PendingSnooze(alert: alert, snooze: snooze)
                        }
                    }
                } label: {
                    Label("Snooze", systemImage: "bell.slash")
                        .frame(minHeight: PlatformControlMetrics.minimumInteractiveLength)
                }
                // Bordered, to match the button beside it. Captured before this
                // was here: a borderless Snooze next to a bordered Pause read as
                // two different *kinds* of control — one a link, one a button —
                // when they are the two halves of the same decision. The frame
                // stays inside the label regardless of the style; see the note
                // above for what the outside placement measures at.
                .buttonStyle(.bordered)
                .accessibilityLabel("Snooze \(alert.displayTitle)")
            }

            Button {
                pendingEnable = PendingEnable(
                    alert: alert, enabled: !controller.effectiveEnabled(alert)
                )
            } label: {
                Label(
                    controller.effectiveEnabled(alert) ? "Pause" : "Start",
                    systemImage: controller.effectiveEnabled(alert) ? "pause" : "play"
                )
                .frame(minHeight: PlatformControlMetrics.minimumInteractiveLength)
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)

            if controller.isBusy(alert) {
                ProgressView().controlSize(.small)
            }
        }
        .font(.footnote)
        .disabled(controller.isBusy(alert))
    }

    // MARK: - Words

    private var footer: String {
        """
        PostHog evaluates these on its own servers and e-mails the people listed on each one. \
        GetHog manages those server-side alerts, but does not deliver a separate local alert \
        notification on this device.
        """
    }

    /// State by word first, colour second — the pill carries the same text.
    private func stateText(_ alert: InsightAlert) -> String {
        if !controller.effectiveEnabled(alert) { return "Paused" }
        if controller.isSnoozed(alert) { return "Snoozed" }
        return alert.state.title
    }

    private func glyph(for alert: InsightAlert) -> String {
        if !controller.effectiveEnabled(alert) { return "bell.slash" }
        if controller.isSnoozed(alert) { return "bell.slash" }
        return alert.state == .firing ? "bell.badge" : "bell"
    }

    private func tint(for alert: InsightAlert) -> Color {
        if !controller.effectiveEnabled(alert) || controller.isSnoozed(alert) { return Theme.neutralMark }
        switch alert.state {
        case .firing, .errored: return Theme.Status.critical
        case .notFiring: return Theme.Status.good
        case .snoozed, .unknown: return Theme.neutralMark
        }
    }

    private func thresholdLine(_ alert: InsightAlert) -> String {
        var parts: [String] = []
        if let threshold = alert.thresholdSummary { parts.append(threshold) }
        if let interval = alert.calculationInterval { parts.append("checked \(interval)") }
        if let value = alert.lastValue { parts.append("last \(value.compactFormatted)") }
        return parts.isEmpty ? "No threshold reported" : parts.joined(separator: " · ")
    }

    /// When the quiet ends — and, while our own write is the only evidence, an
    /// explicit statement that this app has not been told the time.
    ///
    /// PostHog parses a snooze with `always_truncate`, so `"1d"` lands on the
    /// start of the next UTC day rather than 24 hours out. An optimistic value
    /// computed here by plain addition would be wrong by up to a day, so it is
    /// never printed as a time — only the server's own `snoozed_until` is.
    private func snoozeLine(_ alert: InsightAlert) -> String? {
        guard controller.isSnoozed(alert) else { return nil }
        if controller.snoozeOverrides[alert.id] != nil {
            return "Snoozed just now. PostHog decides the exact end time — pull to refresh to see it."
        }
        guard let until = alert.snoozedUntil else { return nil }
        return "Quiet until \(until.formatted(.relative(presentation: .named)))"
    }

    private func spoken(_ alert: InsightAlert) -> String {
        "\(alert.displayTitle), \(stateText(alert)), \(thresholdLine(alert)), \(alert.deliverySummary)"
    }

    private var snoozeDialogTitle: String {
        guard let pendingSnooze else { return "" }
        return pendingSnooze.snooze == nil
            ? "Wake \(pendingSnooze.alert.displayTitle) up?"
            : "Snooze \(pendingSnooze.alert.displayTitle)?"
    }

    private func snoozeDialogMessage(_ pending: PendingSnooze) -> String {
        guard let snooze = pending.snooze else {
            return "PostHog will start checking this again straight away, and will e-mail its subscribers if it is still breaching."
        }
        return "\(snooze.title). \(snooze.explanation) Nobody is e-mailed while it is quiet."
    }

    private var enableDialogTitle: String {
        guard let pendingEnable else { return "" }
        return pendingEnable.enabled
            ? "Start checking \(pendingEnable.alert.displayTitle)?"
            : "Pause \(pendingEnable.alert.displayTitle)?"
    }

    // MARK: - Actions

    private func apply(_ pending: PendingSnooze) {
        pendingSnooze = nil
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            await controller.setSnoozed(
                pending.snooze, alert: pending.alert, client: client, projectID: projectID
            )
        }
    }

    private func apply(_ pending: PendingEnable) {
        pendingEnable = nil
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            await controller.setEnabled(
                pending.enabled, alert: pending.alert, client: client, projectID: projectID
            )
        }
    }

    private func create(_ draft: AlertDraft) async -> Bool {
        guard let client = model.client, let projectID = model.projectID else { return false }
        return await controller.create(
            draft, insightTitle: insight.title, client: client, projectID: projectID
        )
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, insightID: insight.id)
        controller.reconcile(with: store.alerts)
    }
}

// MARK: - Store

/// The alerts on one insight.
///
/// One `.crud` request, narrowed **server-side** by `insight_id`. Filtering a
/// full page locally would be wrong rather than merely wasteful: `limit`
/// truncates before a client-side filter runs, so an insight's third alert can
/// sit past the first page and the screen would report two.
@MainActor
@Observable
final class InsightAlertsStore {
    private(set) var alerts: [InsightAlert] = []
    private(set) var isLoading = false
    private(set) var failure: LoadFailure?

    func load(client: PostHogClient, projectID: Int, insightID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<InsightAlert> = try await client.send(
                PostHogAPI.alerts(projectID: projectID, insightID: insightID)
            )
            // Firing first: an alerts screen is opened for the alert that is
            // firing. Same ordering as `AutomationRoot`'s, deliberately.
            alerts = page.results.sorted {
                ($0.state == .firing ? 0 : 1, $0.displayTitle)
                    < ($1.state == .firing ? 0 : 1, $1.displayTitle)
            }
            failure = nil
        } catch {
            failure = LoadFailure(error, loading: "alerts")
        }
    }
}
