import AppKit
import GetHogKit
import GetHogUI
import Observation
import SwiftUI

// The phase-2 ambient layer's first surface (spec §4): a `MenuBarExtra` whose
// label is one user-chosen headline metric and whose window is a mini-dashboard
// over the same `SharedSnapshot` the widgets read. The iron rule carries over
// verbatim: **nothing in this file calls the PostHog API.** The render path
// reads the snapshot file; the one Refresh affordance routes through
// `AppModel.publishWidgetSnapshot()`, the app's existing, governor-metered
// machinery.

/// Names the contract this feature persists and posts. Statics rather than
/// scattered literals because two of these strings outlive the process — they
/// are `UserDefaults` keys — and two more are read by another scene, so a
/// rename is silent data loss or a dead deep link. A test pins each of them.
enum MacMenuBar {

    /// The one spec §4 setting: whether closing the last window leaves the app
    /// alive behind its menu bar item.
    static let keepOnCloseKey = "menuBarKeepOnClose"

    /// The user's chosen headline metric (`SharedSnapshot.Metric.id`).
    static let headlineMetricKey = "menuBarHeadlineMetricID"

    /// The main shell `WindowGroup`'s id, for `openWindow(id:)` from the
    /// popover.
    static let mainWindowID = "main"

    /// Posted after the popover enqueues a `PendingOpen`, so an already-open
    /// shell routes it now rather than on its next scene-phase change — unlike
    /// iOS, a popover tap does not foreground the app, so there is no phase
    /// change to piggyback on. In-process only, exactly like
    /// `LinkInbox.didChangeNotification`.
    static let pendingOpenNotification = Notification.Name("app.gethog.mac.pendingOpen")
}

// MARK: - Headline

/// Which metric leads, and how it reads in a strip a few characters wide.
///
/// Pure and static so the election and the spelling are pinned without mounting
/// a status item.
enum MenuBarHeadline {

    /// The election, in order of how explicit the user was:
    /// 1. the metric they chose by id, when the snapshot still carries it;
    /// 2. the first *enabled* `MetricWatch` whose metric the snapshot carries —
    ///    a watch is the strongest signal short of a choice, the same reasoning
    ///    `SnapshotRelevance` records;
    /// 3. the snapshot's first metric, which is the pinned dashboard's first
    ///    tile by construction (`AppModel.publishWidgetSnapshot`).
    ///
    /// A choice or a watch naming a metric the snapshot no longer carries is
    /// skipped rather than honoured blind: the dashboard it came from can be
    /// re-pinned or re-tiled between two syncs, and a label with nothing behind
    /// it is worse than the next-best metric.
    static func metric(
        in snapshot: SharedSnapshot?,
        watches: [MetricWatch],
        chosenID: String?
    ) -> SharedSnapshot.Metric? {
        guard let snapshot else { return nil }
        if let chosenID, let chosen = snapshot.metric(id: chosenID) { return chosen }
        for watch in watches where watch.isEnabled {
            if let watched = snapshot.metric(id: watch.metricID) { return watched }
        }
        return snapshot.metrics.first
    }

    /// "12.5K ↑" — value plus trend glyph, nothing else. The title would double
    /// the width for information the popover is one click away from, and an
    /// unknown direction gets no glyph rather than a misleading flat arrow —
    /// the same nil-is-not-flat rule `SharedSnapshot.Metric.previous` documents.
    static func label(for metric: SharedSnapshot.Metric) -> String {
        guard let glyph = glyph(for: metric.direction) else {
            return compact(metric.value, unit: metric.unit)
        }
        return "\(compact(metric.value, unit: metric.unit)) \(glyph)"
    }

    static func glyph(for direction: SharedSnapshot.Metric.Direction) -> String? {
        switch direction {
        case .up: "↑"
        case .down: "↓"
        case .flat: "→"
        case .unknown: nil
        }
    }

    /// `WidgetNumber.compact`'s twin — that type lives in the widget extension
    /// target, which is an appex rather than a framework, so there is nothing
    /// for this target to import. Behaviour is kept identical on purpose;
    /// folding both into the kit is a recorded deferral.
    static func compact(_ value: Double, unit: String? = nil) -> String {
        let magnitude = abs(value)
        let number: String
        if magnitude >= 1_000 {
            number = value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        } else if value == value.rounded() {
            number = value.formatted(.number.precision(.fractionLength(0)))
        } else {
            number = value.formatted(.number.precision(.fractionLength(0...1)))
        }
        guard let unit, !unit.isEmpty else { return number }
        // "%" and currency symbols hug the number; word units get a space.
        if unit == "%" { return number + "%" }
        if unit.count == 1, unit.rangeOfCharacter(from: .letters) == nil { return unit + number }
        return "\(number) \(unit)"
    }

    /// Spoken form for the status item: the label alone reads as a bare number.
    static func accessibilityLabel(for metric: SharedSnapshot.Metric?) -> String {
        guard let metric else { return "GetHog" }
        return "GetHog: \(metric.title), \(compact(metric.value, unit: metric.unit))"
    }
}

// MARK: - Controller

/// The menu bar's window on the snapshot file. `@Observable` so the label and
/// the popover re-render when a reload lands; reloaded on a one-minute tick —
/// the freshness caption has to move anyway — on popover appearance, and after
/// every popover action that rewrites the file.
///
/// Deliberately not wired into `AppModel`: the file is the contract, and reading
/// it keeps this surface honest about what a widget would also see.
@MainActor
@Observable
final class MacMenuBarController {

    private(set) var snapshot: SharedSnapshot?
    private(set) var watches: [MetricWatch] = []

    /// The user's choice; `nil` lets the election in `MenuBarHeadline` decide.
    var headlineMetricID: String? {
        didSet {
            if let headlineMetricID {
                defaults.set(headlineMetricID, forKey: MacMenuBar.headlineMetricKey)
            } else {
                defaults.removeObject(forKey: MacMenuBar.headlineMetricKey)
            }
        }
    }

    let store: SharedSnapshotStore

    /// Injectable for the reason `NavPreferences`' is: the choice above is
    /// persisted, and a test that wrote the real key would change the menu bar
    /// of whatever ran next in the same process.
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(store: SharedSnapshotStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        headlineMetricID = defaults.string(forKey: MacMenuBar.headlineMetricKey)
        reload()
    }

    var headline: SharedSnapshot.Metric? {
        MenuBarHeadline.metric(in: snapshot, watches: watches, chosenID: headlineMetricID)
    }

    func reload() {
        snapshot = store.loadOrNil()
        watches = store.metricWatches()
    }

    /// How often the label catches up with a write it did not make — a
    /// background refresh, or the app's own publish. One minute because that is
    /// the resolution the freshness caption is written to; anything finer would
    /// wake the process to redraw the same words.
    static let tickInterval: Duration = .seconds(60)

    /// Idempotent; owned by the app's `@State`, so it lives for the process and
    /// never needs cancelling — a `deinit` cancel would be touching main-actor
    /// state off the actor for an object that never dies.
    func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MacMenuBarController.tickInterval)
                self?.reload()
            }
        }
    }
}

// MARK: - Label

/// What sits in the menu bar: the headline's value and trend, or the neutral
/// chart glyph before the first sync. Text-compact by design — the title, the
/// sparkline and everything else are one click away in the popover.
struct MacMenuBarLabel: View {
    let controller: MacMenuBarController

    var body: some View {
        Group {
            if let metric = controller.headline {
                Text(MenuBarHeadline.label(for: metric))
                    .monospacedDigit()
            } else {
                Image(systemName: "chart.xyaxis.line")
            }
        }
        .accessibilityLabel(MenuBarHeadline.accessibilityLabel(for: controller.headline))
        .onAppear { controller.startTicking() }
    }
}

// MARK: - Flag toggling

/// The popover's write path for quick flag toggles, kept as a state machine so
/// the gate rules are testable without an `LAContext`.
///
/// Mirrors `FlagToggleController.setActive`'s outcome handling exactly — denied
/// blocks the write, unavailable proceeds with an honest notice, passed
/// proceeds — because the menu bar must not be the one surface where
/// `BiometricGate` is decoration. `AppModel.setFlag` does not run the gate
/// itself: it is the landing half of the widget hand-off, where there is no
/// `LAContext` to run. This popover is in the app process, where there is.
///
/// The confirmation dialog is the popover's; nothing in here asks the user
/// whether they meant it, same contract as the controller it mirrors.
@MainActor
@Observable
final class MacMenuBarFlagToggler {

    struct Request: Equatable {
        let flag: SharedSnapshot.Flag
        var desiredActive: Bool { !flag.active }
    }

    /// One line the popover shows under the flags. Carries its own kind for the
    /// reason `FlagToggleMessage` does: an unavailable gate is not a failure —
    /// the write happened — and drawing it in the failure ink would say the
    /// opposite of what it means.
    struct Notice: Equatable {
        enum Kind: Equatable { case notice, failure }

        let kind: Kind
        let text: String
    }

    private(set) var pending: Request?
    private(set) var inFlightFlagID: Int?
    /// Cleared by the next request.
    private(set) var notice: Notice?

    /// Only an opted-in flag may even reach the confirmation dialog — the same
    /// gate `SharedSnapshot.quickToggleFlags` applies, restated here so a caller
    /// handing in the wrong flag is refused rather than trusted.
    func request(_ flag: SharedSnapshot.Flag) {
        guard flag.quickToggleAllowed, inFlightFlagID == nil else { return }
        notice = nil
        pending = Request(flag: flag)
    }

    func cancel() {
        pending = nil
    }

    /// Runs the gate, then the write.
    ///
    /// **The request is a parameter, not `self.pending`, and that is the whole
    /// point.** Confirming happens from a dialog button, and SwiftUI writes
    /// `false` back through the dialog's `isPresented` binding as part of the
    /// same synchronous dispatch that runs the button's action — which clears
    /// `pending`. A version of this that read `pending` on its first line found
    /// nil by the time the awaited body ran and no-oped: no gate, no write, no
    /// notice, and a switch that snapped back with nothing to explain it. The
    /// iOS twin is immune for exactly this reason — `FlagDetailView.commit(_:)`
    /// carries the desired state in as an argument.
    ///
    /// `gate` and `isGateEnabled` are injectable so tests exercise every
    /// outcome without device-owner authentication; production passes neither.
    func confirm(
        _ request: Request,
        isGateEnabled: Bool = BiometricGate.isEnabled,
        gate: () async -> BiometricGate.Outcome = BiometricGate.evaluate,
        write: (Int, Bool) async -> Void
    ) async {
        guard inFlightFlagID == nil else { return }
        pending = nil

        if isGateEnabled {
            switch await gate() {
            case .passed:
                break
            case .unavailable(let detail):
                notice = Notice(
                    kind: .notice,
                    text: "Device authentication wasn't available (\(detail)). "
                        + "This change was confirmed by dialog only."
                )
            case .denied(let detail):
                notice = Notice(
                    kind: .failure,
                    text: "Not authenticated, so \(request.flag.key) was left unchanged. \(detail)"
                )
                return
            }
        }

        inFlightFlagID = request.flag.id
        await write(request.flag.id, request.desiredActive)
        inFlightFlagID = nil
    }
}

// MARK: - Popover

/// The mini-dashboard (spec §4): headline metric with its sparkline, the health
/// verdict, and quick flag toggles — every pixel of it from the snapshot file,
/// no API call on this render path.
struct MacMenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    let controller: MacMenuBarController

    @State private var toggler = MacMenuBarFlagToggler()
    @State private var isRefreshing = false

    /// The ceiling an ambient surface can honestly manage. The flags screen
    /// holds the rest, and "Open GetHog" is one click below this list.
    static let maximumQuickToggles = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let snapshot = controller.snapshot {
                header(snapshot)
                if let metric = controller.headline {
                    headlineSection(metric)
                }
                Divider()
                healthRow(snapshot)
                if !snapshot.quickToggleFlags.isEmpty {
                    Divider()
                    flagSection(snapshot)
                }
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .padding(Theme.Space.m)
        .frame(width: 320)
        .task { controller.reload() }
        // The `presenting:` form, as `MacRootView`'s link alert uses: SwiftUI
        // holds the presented value for the dialog's whole life and hands it to
        // the builders, so the button's action owns a `Request` outright rather
        // than reading state that dismissal is about to clear. See
        // `MacMenuBarFlagToggler.confirm(_:)` for what that race cost.
        .confirmationDialog(
            toggler.pending.map { "\($0.desiredActive ? "Enable" : "Disable") \($0.flag.key)?" } ?? "",
            isPresented: Binding(
                get: { toggler.pending != nil },
                set: { if !$0 { toggler.cancel() } }
            ),
            titleVisibility: .visible,
            presenting: toggler.pending
        ) { request in
            Button(
                request.desiredActive ? "Enable for live users" : "Disable for live users",
                role: .destructive
            ) {
                Task {
                    await toggler.confirm(request) { id, active in
                        await model.setFlag(id: id, active: active)
                    }
                    controller.reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // The same claim the flag detail's dialog makes, because it is the
            // same write: this changes what production serves, in this project.
            Text(
                "This changes what \(controller.snapshot?.projectName ?? "your project") "
                    + "serves to live users right now."
            )
        }
    }

    // MARK: Sections

    private func header(_ snapshot: SharedSnapshot) -> some View {
        HStack {
            Text(snapshot.projectName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Menu {
                ForEach(snapshot.metrics) { metric in
                    Button {
                        controller.headlineMetricID = metric.id
                    } label: {
                        if metric.id == controller.headline?.id {
                            Label(metric.title, systemImage: "checkmark")
                        } else {
                            Text(metric.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "chart.bar.xaxis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Choose the menu bar metric")
        }
    }

    private func headlineSection(_ metric: SharedSnapshot.Metric) -> some View {
        Button {
            openApp(metricID: metric.id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(MenuBarHeadline.compact(metric.value, unit: metric.unit))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let glyph = MenuBarHeadline.glyph(for: metric.direction) {
                        Text(glyph)
                            .font(.title3)
                            .foregroundStyle(trendTint(metric.direction))
                    }
                }
                if metric.sparkline.count >= 2 {
                    MenuBarSparkline(points: metric.sparkline)
                        .frame(height: 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(MenuBarHeadline.accessibilityLabel(for: metric)). Opens its dashboard in GetHog."
        )
    }

    private func healthRow(_ snapshot: SharedSnapshot) -> some View {
        let verdict = snapshot.healthVerdict
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: verdict.symbolName)
                .foregroundStyle(healthTint(verdict))
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.healthHeadline)
                    .font(.callout)
                Text(snapshot.healthDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.healthSpokenLabel)
    }

    private func flagSection(_ snapshot: SharedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Quick toggles")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(snapshot.quickToggleFlags.prefix(Self.maximumQuickToggles)) { flag in
                Toggle(isOn: Binding(
                    get: { flag.active },
                    set: { _ in toggler.request(flag) }
                )) {
                    Text(flag.key)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(toggler.inFlightFlagID != nil || model.phase != .ready)
                .accessibilityLabel(
                    "Feature flag \(flag.key), \(flag.active ? "enabled" : "disabled")"
                )
            }
            if let notice = toggler.notice {
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(
                        notice.kind == .failure ? Theme.Status.criticalInk : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("No data yet")
                .font(.headline)
            Text(
                "Open GetHog and connect to PostHog; the menu bar shows your headline metric "
                    + "after the first sync."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Text(freshnessCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task {
                    isRefreshing = true
                    _ = await model.publishWidgetSnapshot()
                    controller.reload()
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing || model.phase != .ready)
            .accessibilityLabel("Refresh now")
            Button("Open GetHog") { openApp(metricID: nil) }
            overflowMenu
        }
    }

    /// Settings and Quit, behind one control so the footer stays three wide.
    ///
    /// **Quit is not optional here.** With "keep in the menu bar" on and the
    /// last window closed the app is in `.accessory`: no Dock icon, no app menu,
    /// and therefore no ⌘Q anywhere the user can reach. This popover is the
    /// app's entire presence in that mode, and every menu-bar-resident app
    /// carries its own way out. Offered unconditionally rather than only in
    /// accessory mode, because a control that appears and disappears with a
    /// window is harder to find than one that is always in the same place.
    private var overflowMenu: some View {
        Menu {
            Button("Settings…") {
                // Back into the Dock first: `openSettings` in `.accessory`
                // opens a window behind an app the switcher cannot reach.
                MacMenuBar.activateRegular()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit GetHog") { MacMenuBar.quit() }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More GetHog actions")
    }

    private var freshnessCaption: String {
        guard let snapshot = controller.snapshot else { return "Never synced" }
        let caption = WidgetFreshness.caption(forAge: snapshot.staleness())
        return snapshot.isStale() ? caption + " — stale" : caption
    }

    /// Never green-good / red-bad for a metric. `WidgetViews.tint(for direction:)`
    /// argues it in full: the snapshot says how a number moved, not whether
    /// moving that way is desirable — a drop in errors is good news and a rise
    /// in them is not. So a movement is accented in either direction, and a flat
    /// line, which is not a movement, is not.
    private func trendTint(_ direction: SharedSnapshot.Metric.Direction) -> Color {
        switch direction {
        case .up, .down: Theme.Status.accentInk
        case .flat, .unknown: .secondary
        }
    }

    private func healthTint(_ verdict: SharedSnapshot.HealthVerdict) -> Color {
        // `WidgetViews.tint(for:)`'s verdict mapping, restated over Theme's
        // inks — that type lives in the widget appex. Health has a defined
        // polarity, so red is accurate here; the glyph and the words still carry
        // the state on their own.
        switch verdict {
        case .critical: Theme.Status.criticalInk
        case .attention: Theme.Status.accentInk
        case .clear: Theme.Status.goodInk
        case .unchecked: Color.secondary
        }
    }

    // MARK: Deep link

    /// The widget idiom, in-process: record where to land, poke the shell, bring
    /// a shell window to front. `MacRootView.routePendingLinks` consumes the
    /// record and routes through the same `PostHogLink` path every other
    /// entrance uses.
    ///
    /// Written through the controller's store rather than `.shared` directly so
    /// this reads from and writes to one place; in the app they are the same
    /// store, and a controller pointed elsewhere is a test that does not mount
    /// this view.
    private func openApp(metricID: String?) {
        try? controller.store.enqueue(PendingOpen(metricID: metricID))
        NotificationCenter.default.post(name: MacMenuBar.pendingOpenNotification, object: nil)
        MacMenuBar.openMainWindow(using: openWindow)
    }
}

// MARK: - Window plumbing

extension MacMenuBar {

    /// Back into the Dock, and frontmost. Idempotent, and called before
    /// anything that needs a window: with the keep-in-menu-bar setting on, the
    /// app may be sitting in `.accessory`, where `openWindow` alone would open a
    /// window the user cannot reach through the app switcher.
    @MainActor
    static func activateRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    /// The way out of `.accessory`, where the app menu that normally carries
    /// ⌘Q does not exist. Routed through `NSApp` rather than `exit`, so the
    /// usual termination path — delegate, autosave, teardown — still runs.
    @MainActor
    static func quit() {
        NSApp.terminate(nil)
    }

    /// Fronts an existing main-shell window, or opens one. SwiftUI stamps
    /// windows from `WindowGroup(id:)` with identifiers prefixed by that id; if
    /// the prefix rule ever fails, the fallback opens a fresh shell window,
    /// whose own `onAppear` routing still lands the pending deep link.
    @MainActor
    static func openMainWindow(using openWindow: OpenWindowAction) {
        activateRegular()
        if let existing = NSApp.windows.first(where: {
            ($0.identifier?.rawValue.hasPrefix(mainWindowID) ?? false) && $0.isVisible
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: mainWindowID)
        }
    }
}

// MARK: - Sparkline

/// The widgets' hand-drawn trend line, restated over Theme's ink — the original
/// lives in the widget appex, and `IngestionWarningsRoot` already carries its
/// own copy for the same reason. Same normalisation, same flat-series middle
/// line, same half-stroke inset.
private struct MenuBarSparkline: View {
    let points: [Double]

    var body: some View {
        GeometryReader { geometry in
            let coordinates = coordinates(in: geometry.size)
            if coordinates.count >= 2 {
                ZStack {
                    area(through: coordinates, in: geometry.size)
                        .fill(Theme.Status.accentInk.opacity(0.18))
                    line(through: coordinates)
                        .stroke(
                            Theme.Status.accentInk,
                            style: StrokeStyle(
                                lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round
                            )
                        )
                }
            }
        }
        // The number beside it is the content; this is its shape.
        .accessibilityHidden(true)
    }

    private static let lineWidth: CGFloat = 2

    private func coordinates(in size: CGSize) -> [CGPoint] {
        guard points.count >= 2, let low = points.min(), let high = points.max() else { return [] }
        let span = high - low
        let step = size.width / CGFloat(points.count - 1)
        let inset = Self.lineWidth / 2
        let usable = max(0, size.height - Self.lineWidth)
        return points.enumerated().map { index, value in
            // A flat series draws down the middle rather than along an edge,
            // where half the stroke would be clipped away.
            let fraction = span > 0 ? (value - low) / span : 0.5
            return CGPoint(x: CGFloat(index) * step, y: inset + usable * (1 - fraction))
        }
    }

    private func line(through coordinates: [CGPoint]) -> Path {
        Path { $0.addLines(coordinates) }
    }

    private func area(through coordinates: [CGPoint], in size: CGSize) -> Path {
        Path { path in
            path.addLines(coordinates)
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }
}

// MARK: - Window-close policy

/// The keep-in-menu-bar rules as one pure truth table, apart from the AppKit
/// delegate that acts on them — the same split as `MacRefreshSchedule`.
///
/// The extra is inserted the whole time the app runs; the single spec §4
/// setting decides only what closing the *last* window means. Off — the
/// default, since the spec calls ambient presence optional — the process quits,
/// which is what "not kept in the menu bar" has to mean if the toggle is to
/// have any visible effect at all. On, the process stays and drops out of the
/// Dock, leaving the status item as its whole presence.
enum MenuBarWindowPolicy {

    /// Off means the menu bar item was never promised past the window, so the
    /// last close quits. This is deliberately not the delegate-less SwiftUI
    /// default, which lingers windowless in the Dock — a state in which the
    /// setting would read the same either way.
    static func shouldTerminateAfterLastWindowClosed(keepInMenuBar: Bool) -> Bool {
        !keepInMenuBar
    }

    /// `.accessory` — leave the Dock, live in the menu bar — exactly when the
    /// user asked to be kept *and* no main-capable window remains. `nil` means
    /// change nothing: a policy transition is a one-way door that only those two
    /// conditions together may open, and a tear-off window left behind is a
    /// window the Dock icon still belongs to.
    static func activationPolicy(
        keepInMenuBar: Bool,
        visibleMainCapableWindows: Int
    ) -> NSApplication.ActivationPolicy? {
        guard keepInMenuBar, visibleMainCapableWindows == 0 else { return nil }
        return .accessory
    }
}

/// The thin AppKit glue over `MenuBarWindowPolicy`. Counts windows that can
/// become main, which excludes the status item's own window and the popover
/// panel by construction.
///
/// **AppKit does still ask, with a `MenuBarExtra` inserted.** That was the open
/// question — a status item is a form of presence, and an app holding one might
/// plausibly never have been asked whether the last window's close should end
/// it. Measured on this app rather than assumed: closing the only main-capable
/// window calls the method below both ways round, terminating the process with
/// the setting off and dropping it to `.accessory` with the setting on. So
/// there is no second terminate path here; the delegate method is the whole of
/// the quit half.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MenuBarWindowPolicy.shouldTerminateAfterLastWindowClosed(keepInMenuBar: Self.keepInMenuBar)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            let closing = note.object as? NSWindow
            // After the close lands rather than during it: the closing window
            // still counts itself until the next turn of the loop.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.dropToAccessoryIfAsked(excluding: closing)
                }
            }
        }
    }

    /// Leaves the Dock once nothing is left on screen and the user asked to be
    /// kept. Idempotent — the notification arrives once per closing window and
    /// the setter is a no-op when the policy already holds.
    private static func dropToAccessoryIfAsked(excluding closing: NSWindow?) {
        let remaining = NSApp.windows.filter {
            $0 !== closing && $0.isVisible && $0.canBecomeMain
        }.count
        guard let policy = MenuBarWindowPolicy.activationPolicy(
            keepInMenuBar: keepInMenuBar,
            visibleMainCapableWindows: remaining
        ) else { return }
        NSApp.setActivationPolicy(policy)
    }

    private static var keepInMenuBar: Bool {
        UserDefaults.standard.bool(forKey: MacMenuBar.keepOnCloseKey)
    }
}
