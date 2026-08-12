import GetHogKit
import GetHogUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Thresholds on the metrics the app already publishes for its widgets.
///
/// The screen has one job beyond create/pause/delete, and it is honesty about
/// cadence. There is no server behind this: the check runs when iOS wakes the
/// app for a background refresh, which it does when it feels like it — every
/// couple of hours at best, later in Low Power Mode, and not at all if the user
/// has switched background refresh off. A screen that let someone believe these
/// were live alerts would be the same lie as an unlabelled stale chart, and this
/// app labels those everywhere.
struct MetricAlertsView: View {
    @State private var controller: MetricWatchController
    @State private var metrics: [SharedSnapshot.Metric] = []
    @State private var capturedAt: Date?
    @State private var isAddingWatch = false
    @State private var pendingDeletion: MetricWatch?

    init(snapshotStore: SharedSnapshotStore) {
        _controller = State(initialValue: MetricWatchController(store: snapshotStore))
    }

    /// Said in full on the list and in shorter form on the empty state, because
    /// whichever one a user meets first is where the expectation gets set.
    private static let cadenceFooter = """
        GetHog checks these when iOS wakes it in the background — usually every couple of hours, \
        later in Low Power Mode, and not at all while background refresh is off for the app. Expect a \
        catch-up notice, not a live alert.

        Each watch tells you once, when the metric crosses the line. It goes quiet until the metric \
        comes back and crosses again.
        """

    var body: some View {
        Group {
            if controller.watches.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Metric alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add alert", systemImage: "plus") { isAddingWatch = true }
                    .accessibilityLabel("Add alert")
                    .disabled(metrics.isEmpty)
            }
        }
        .task {
            controller.reload()
            metrics = controller.watchableMetrics
            capturedAt = controller.snapshotCapturedAt
            await controller.refreshAuthorization()
        }
        .sheet(isPresented: $isAddingWatch) {
            MetricWatchEditor(metrics: metrics) { metric, condition in
                Task {
                    await controller.add(
                        metricID: metric.id,
                        title: metric.title,
                        condition: condition
                    )
                }
            }
        }
        // A watch is something the user wrote, not derived data, so it never
        // disappears on a single tap.
        .confirmationDialog(
            "Delete the alert on \(pendingDeletion?.title ?? "this metric")?",
            isPresented: isConfirmingDeletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion { controller.delete(id: pendingDeletion.id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Nothing in PostHog changes. This only stops GetHog watching the number.")
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        EmptyStateView(
            title: metrics.isEmpty ? "Nothing to watch yet" : "No metric alerts",
            systemImage: "bell.badge",
            message: metrics.isEmpty
                // Not a failure: a fresh install genuinely has no snapshot until
                // the app has fetched a dashboard once.
                ? "Alerts read the same snapshot your widgets do. Open a dashboard once and its metrics become watchable here."
                : "Set a line on a metric and GetHog tells you when it crosses. Checks happen when iOS wakes the app in the background, so they arrive late rather than live.",
            actionTitle: metrics.isEmpty ? nil : "Add an alert",
            action: metrics.isEmpty ? nil : { isAddingWatch = true }
        )
    }

    // MARK: - List

    private var list: some View {
        List {
            if showsAuthorizationNotice {
                Section {
                    authorizationNotice
                        .listRowBackground(cardRowBackground)
                }
            }

            Section {
                ForEach(controller.watches) { watch in
                    row(watch)
                }
            } header: {
                HStack {
                    SectionLabel(text: "Watching", systemImage: "bell.badge")
                    Spacer()
                    // The alerts are only ever as current as this, so the age of
                    // the snapshot belongs on the screen that promises them.
                    FreshnessLabel(date: capturedAt)
                }
            } footer: {
                Text(Self.cadenceFooter)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
    }

    private func row(_ watch: MetricWatch) -> some View {
        DataRow(
            // Paused state is carried by the glyph, the word in the pill and the
            // muted tint together, never by colour alone.
            glyph: watch.isEnabled ? "bell.badge.fill" : "bell.slash.fill",
            tint: watch.isEnabled ? Theme.accent : Theme.neutralMark,
            title: watch.title,
            subtitle: watch.condition.summary,
            footnote: currentValue(for: watch),
            accessory: .pill(
                watch.isEnabled ? "On" : "Paused",
                watch.isEnabled ? Theme.Status.good : Theme.neutralMark
            )
        )
        .listRowBackground(cardRowBackground)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = watch
            }
            Button(
                watch.isEnabled ? "Pause" : "Resume",
                systemImage: watch.isEnabled ? "bell.slash" : "bell"
            ) {
                controller.setEnabled(!watch.isEnabled, id: watch.id)
            }
            .tint(Theme.accent)
        }
        .contextMenu {
            Button(
                watch.isEnabled ? "Pause" : "Resume",
                systemImage: watch.isEnabled ? "bell.slash" : "bell"
            ) {
                controller.setEnabled(!watch.isEnabled, id: watch.id)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = watch
            }
        }
    }

    /// What the metric reads in the snapshot the alerts are actually evaluated
    /// against — and a plain statement when it is no longer in there at all,
    /// which is the difference between a quiet watch and a broken one. The
    /// footnote is clipped to one line, so both stay short enough to survive it.
    private func currentValue(for watch: MetricWatch) -> String {
        guard let metric = metrics.first(where: { $0.id == watch.metricID }) else {
            return "Not in the latest snapshot"
        }
        return "Now \(metric.value.compactFormatted)"
    }

    // MARK: - Authorization

    private var showsAuthorizationNotice: Bool {
        controller.authorization == .denied || controller.authorization == .notDetermined
    }

    @ViewBuilder
    private var authorizationNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if controller.authorization == .denied {
                Label("Notifications are turned off", systemImage: "bell.slash.fill")
                    .font(Theme.Typography.title)
                Text("These watches still evaluate, but nothing can reach you until GetHog is allowed to notify you.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // visionOS joins iOS here rather than falling to the else:
                // `openSettingsURLString` is real and functional there, while
                // the `x-apple.systempreferences:` URL below means nothing.
                // Only the label differs, and the iOS string is left exactly
                // as it was — UI tests may pin it.
                #if os(iOS) || os(visionOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        #if os(iOS)
                        Label("Open iOS Settings", systemImage: "arrow.up.forward.square")
                            .font(Theme.Typography.body)
                        #else
                        Label("Open Settings", systemImage: "arrow.up.forward.square")
                            .font(Theme.Typography.body)
                        #endif
                    }
                }
                #else
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    Link(destination: url) {
                        Label("Open System Settings", systemImage: "arrow.up.forward.square")
                            .font(Theme.Typography.body)
                    }
                }
                #endif
            } else {
                Label("Notifications haven't been allowed yet", systemImage: "bell")
                    .font(Theme.Typography.title)
                Text("Without permission a watch can notice a crossing but has nowhere to say so.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow notifications") {
                    Task { await controller.requestAuthorizationIfNeeded() }
                }
                .font(Theme.Typography.body)
            }

            if let error = controller.authorizationError {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Status.criticalInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    // MARK: - Plumbing

    private var cardRowBackground: some View {
        Theme.cardBackground
            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
    }

    /// The dialog wants a `Bool` binding while the payload lives in an optional.
    private var isConfirmingDeletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }
}

// MARK: - Editor

/// Creating one watch.
///
/// The metric picker is driven by the snapshot rather than by the API on
/// purpose: the snapshot is the only thing a background wake has, so offering an
/// insight it never reduces to a metric would create a watch that could not
/// possibly fire.
private struct MetricWatchEditor: View {
    let metrics: [SharedSnapshot.Metric]
    let onSave: (SharedSnapshot.Metric, MetricWatch.Condition) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var metricID: String
    @State private var kind: Kind = .above
    @State private var threshold: Double

    private enum Kind: String, CaseIterable, Identifiable {
        case above = "Above"
        case below = "Below"
        case percent = "Changes by"

        var id: String { rawValue }
    }

    init(
        metrics: [SharedSnapshot.Metric],
        onSave: @escaping (SharedSnapshot.Metric, MetricWatch.Condition) -> Void
    ) {
        self.metrics = metrics
        self.onSave = onSave
        _metricID = State(initialValue: metrics.first?.id ?? "")
        _threshold = State(initialValue: Self.seed(for: metrics.first))
    }

    private var selected: SharedSnapshot.Metric? {
        metrics.first { $0.id == metricID }
    }

    private var condition: MetricWatch.Condition {
        switch kind {
        case .above: .above(threshold)
        case .below: .below(threshold)
        case .percent: .changesByPercent(abs(threshold))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                metricSection
                if let selected { currentSection(selected) }
                conditionSection
            }
            .pageSurface()
            .navigationTitle("New alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let selected { onSave(selected, condition) }
                        dismiss()
                    }
                    .disabled(selected == nil || !threshold.isFinite)
                }
            }
            .onChange(of: metricID) { _, id in
                // A threshold left over from the previous metric is almost never
                // meaningful for the next one, and a stale number silently
                // attached to a new watch is worse than an obvious reset.
                kind = .above
                threshold = Self.seed(for: metrics.first { $0.id == id })
            }
        }
    }

    private var metricSection: some View {
        Section {
            Picker("Metric", selection: $metricID) {
                ForEach(metrics) { metric in
                    Text(metric.title).tag(metric.id)
                }
            }
        } header: {
            SectionLabel(text: "Metric", systemImage: "chart.line.uptrend.xyaxis")
        } footer: {
            Text("These are the metrics your dashboard puts in the widget snapshot. They're the only numbers GetHog has when iOS wakes it, so they're the only ones it can watch.")
        }
    }

    private func currentSection(_ metric: SharedSnapshot.Metric) -> some View {
        Section {
            MetricTile(
                label: metric.title,
                value: metric.value.compactFormatted,
                delta: (metric.value, metric.previous)
            )
            .padding(.vertical, Theme.Space.xs)
        } header: {
            SectionLabel(text: "Latest reading", systemImage: "clock")
        }
    }

    private var conditionSection: some View {
        Section {
            Picker("Condition", selection: $kind) {
                ForEach(Kind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent(kind == .percent ? "Percent" : "Value") {
                TextField("Value", value: $threshold, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }

            if kind == .percent, selected?.previous == nil {
                // Said here rather than discovered months later through silence:
                // the evaluator refuses to invent a baseline, so a percentage
                // watch on a tile with no comparison period can never fire.
                Label(
                    "This metric reports no comparison period, so a percentage watch on it can never fire.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Status.warningInk)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            SectionLabel(text: "Condition", systemImage: "slider.horizontal.3")
        } footer: {
            Text(explanation)
        }
    }

    private var explanation: String {
        guard let selected else { return "" }
        return switch kind {
        case .above:
            "You'll hear once, when \(selected.title) goes above \(MetricWatch.format(threshold)) — then nothing until it comes back below and rises again."
        case .below:
            "You'll hear once, when \(selected.title) drops below \(MetricWatch.format(threshold)) — then nothing until it recovers and falls again."
        case .percent:
            "You'll hear once, when \(selected.title) moves \(MetricWatch.format(abs(threshold)))% or more against its previous period — in either direction."
        }
    }

    /// Starts the field at the metric's own value rather than at zero, which
    /// every metric is already above and which would arm a watch that fires on
    /// the very next wake.
    private static func seed(for metric: SharedSnapshot.Metric?) -> Double {
        guard let metric, metric.value.isFinite else { return 0 }
        return metric.value.rounded()
    }
}
