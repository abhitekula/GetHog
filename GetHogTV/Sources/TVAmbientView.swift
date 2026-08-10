import Charts
import GetHogKit
import GetHogUI
import Observation
import SwiftUI
import UIKit

/// Which pinned metric is on screen, and how the cycle moves between them.
///
/// Kept apart from the view so the cycling rules can be tested without a
/// running screen and without waiting out a real interval — the alternative is
/// an auto-advance that only a twelve-second stopwatch can disagree with.
@MainActor
@Observable
final class TVAmbientCycler {

    /// How long one metric holds the screen.
    ///
    /// Twelve seconds is long enough to read a number, a delta and a sparkline
    /// without hurrying, and short enough that a six-tile dashboard comes back
    /// around inside about a minute. It is a constant rather than a preference
    /// because there is no settings surface on this platform to change it from
    /// — see `SettingsRoot`, which does not mount its navigation section here.
    static let interval: Duration = .seconds(12)

    private(set) var metrics: [SharedSnapshot.Metric]
    private(set) var source: SharedSnapshot.MetricSource
    private(set) var index = 0

    init(
        metrics: [SharedSnapshot.Metric] = [],
        source: SharedSnapshot.MetricSource = .unknown
    ) {
        self.metrics = metrics
        self.source = source
    }

    var isEmpty: Bool { metrics.isEmpty }

    /// `nil` rather than a crash when there is nothing pinned. An empty
    /// dashboard is a state this screen has to render, not an impossible one.
    var current: SharedSnapshot.Metric? {
        guard metrics.indices.contains(index) else { return nil }
        return metrics[index]
    }

    /// Adopts a freshly read snapshot.
    ///
    /// **Returns whether anything changed**, and does nothing at all when
    /// nothing did. The wallboard re-reads the snapshot on every tick — it is
    /// the screen most likely to be left up for a day, and the one that must
    /// not sit on yesterday's numbers — but a tick that reset the index every
    /// twelve seconds would pin the cycle to the first metric forever. Equality
    /// is the whole list, values included, so a refreshed number is adopted
    /// even when the titles are identical.
    @discardableResult
    func replace(
        metrics: [SharedSnapshot.Metric],
        source: SharedSnapshot.MetricSource = .unknown
    ) -> Bool {
        guard metrics != self.metrics || source != self.source else { return false }
        let previousID = current?.id
        self.metrics = metrics
        self.source = source
        // Held where the reader was, by identity rather than by position: a
        // snapshot that gained or lost a tile must not jump the screen to a
        // different metric mid-read. Falls back to the start when the metric
        // being shown is gone, which also keeps the index in bounds — a
        // snapshot that shrank would otherwise leave it past the end.
        index = previousID.flatMap { id in metrics.firstIndex { $0.id == id } } ?? 0
        return true
    }

    /// One step forward, wrapping. What the tick calls.
    func advance() {
        guard !metrics.isEmpty else { return }
        index = (index + 1) % metrics.count
    }

    /// One step in either direction, wrapping — what the remote's left and
    /// right calls. Backwards from the first lands on the last, which is what
    /// a ring means.
    func skip(_ direction: MoveCommandDirection) {
        guard !metrics.isEmpty else { return }
        switch direction {
        case .left: index = (index - 1 + metrics.count) % metrics.count
        case .right: index = (index + 1) % metrics.count
        default: break
        }
    }
}

/// Identity and gate for Ambient's retained-tab task.
///
/// `TabView` may retain a destination after selection moves away. Including
/// the combined presentation-and-active hold in the task identity makes either
/// transition cancel the old loop, while `shouldRun` prevents a freshly-created
/// retained task from doing any work until Ambient is genuinely active again.
struct TVAmbientCycleTaskID: Equatable {
    let clock: Int
    let isHeld: Bool

    var shouldRun: Bool { isHeld }
}

/// Whether the wallboard is currently entitled to keep the screen awake.
///
/// A separate type because the failure it prevents is a *lifecycle* bug, and
/// lifecycle bugs written as three scattered callbacks cannot be tested — which
/// is how the first version shipped one. There, the release hung entirely on
/// `onDisappear`, and a `TabView` is free to keep a tab's content alive across
/// a sidebar switch: if it does, the tick loop goes on re-asserting the flag
/// from a tab nobody is watching, and the Apple TV never sleeps again.
///
/// The rule is one line — held only while the screen is both entered and the
/// scene is active — and every transition into and out of that is a test below.
struct TVScreenAwake: Equatable {
    private(set) var isPresented = false
    private(set) var isSceneActive = true

    /// What the shell writes to `UIApplication.shared.isIdleTimerDisabled`.
    var isHeld: Bool { isPresented && isSceneActive }

    mutating func present() { isPresented = true }

    /// Leaving is sticky. A scene that goes inactive and comes back must not
    /// re-hold a screen the viewer already walked away from — this is the
    /// difference between "not on screen right now" and "dismissed".
    mutating func leave() { isPresented = false }

    mutating func sceneBecame(active: Bool) { isSceneActive = active }

    /// Applies the current lifecycle entitlement to the app-wide idle timer.
    ///
    /// The shell owns this state so it can release the hold *before* it changes
    /// a sidebar selection. Ambient also uses this during its own lifecycle,
    /// which keeps Select and Menu exits unchanged.
    @MainActor
    func applyIdleTimerHold() {
        UIApplication.shared.isIdleTimerDisabled = isHeld
    }
}

/// The wallboard.
///
/// A first-class sidebar destination rather than a screensaver: an Apple TV in
/// a team's room is most often *left* on a number, and the platform's own idle
/// behaviour — dimming, then the system screen saver — is the one thing that
/// would defeat that. Hence `isIdleTimerDisabled`, re-asserted on every tick
/// rather than set once: the flag is per-application and the system is free to
/// reset it when the app resigns and resumes activity, so a single write at
/// `onAppear` is a claim about a moment rather than about the session.
struct TVAmbientView: View {
    /// Where select and Menu both land. The shell passes the destination back
    /// to Dashboards, so leaving the wallboard is one press either way.
    let exit: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model
    @Environment(TVSnapshotRefreshCoordinator.self) private var snapshotRefresh

    @State private var cycler = TVAmbientCycler()
    /// Owned by the shell, which has the only synchronous hook for a direct
    /// sidebar selection away from this retained tab.
    @Binding private var awake: TVScreenAwake
    /// Bumped to restart the tick clock, so a manual skip gets a full interval
    /// rather than whatever was left of the last one.
    @State private var clock = 0

    /// Keeps the injected wake lifecycle internal to the TV shell while
    /// allowing that shell to construct the retained Ambient tab.
    init(exit: @escaping () -> Void, awake: Binding<TVScreenAwake>) {
        self.exit = exit
        _awake = awake
    }

    /// The modelled hold is the lifecycle source of truth; the direct phase
    /// check closes the brief update window before `onChange` has copied a new
    /// environment phase into that model.
    private var mayCycle: Bool {
        awake.isHeld && scenePhase == .active
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
            // `.focusable()` and a tap, rather than wrapping the screen in a
            // `Button`. Focusable it must be — `onMoveCommand` only reaches a
            // focused view — but every tvOS button style paints focus, and a
            // `Button` the size of the screen therefore lifted the entire
            // wallboard onto a light card the moment it took focus. Measured,
            // not predicted: the first ambient screenshot came out white.
            // SwiftUI routes a select press to `onTapGesture` on a focusable
            // view, which is the same action with none of the chrome.
            .focusable()
            .onTapGesture(perform: leave)
            .onExitCommand(perform: leave)
            .onMoveCommand { direction in
                cycler.skip(direction)
                clock += 1
            }
            .onAppear {
                let snapshot = Self.ambientSnapshot()
                cycler.replace(metrics: snapshot.metrics, source: snapshot.source)
                awake.present()
                applyHold()
            }
            .onDisappear {
                awake.leave()
                applyHold()
            }
            // The scene going inactive releases the hold too — and coming back
            // does not re-take it if the viewer had already left, which is why
            // `leave()` is sticky rather than a second boolean.
            .onChange(of: scenePhase) { _, phase in
                awake.sceneBecame(active: phase == .active)
                applyHold()
            }
            .task(id: TVAmbientCycleTaskID(clock: clock, isHeld: mayCycle)) {
                guard mayCycle else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: TVAmbientCycler.interval)
                    // `awake.isHeld` is an explicit second gate as well as part
                    // of the task id. Even if a retained TabView delays task
                    // cancellation, leaving Ambient *or resigning active*
                    // cannot issue another refresh, advance a hidden metric,
                    // or reassert the hold after the app-level cancellation.
                    guard !Task.isCancelled, mayCycle else { return }
                    // The screen clock is twelve seconds; the API clock is the
                    // shared two-hour floor. Every cycle offers a refresh, and
                    // the coordinator coalesces it with foreground work and
                    // remembers failed attempts so an outage cannot turn into
                    // a twelve-second retry loop. Starting is deliberately
                    // non-blocking: API latency must not stretch the visual
                    // cadence or delay the idle-timer reassertion below.
                    let now = Date()
                    snapshotRefresh.startIfDue(
                        now: now,
                        lastSnapshotAt: model.lastSnapshotDate
                    ) {
                        await model.performBackgroundRefresh(now: now)
                    }
                    // Re-read before advancing. This is the screen most likely
                    // to be left up for a day, and reading the snapshot once at
                    // `onAppear` meant it would cycle day-old numbers forever on
                    // the one surface whose whole purpose is being left on.
                    // `replace` is a no-op unless the snapshot actually changed,
                    // so the cycle index is not reset every twelve seconds.
                    let snapshot = Self.ambientSnapshot()
                    cycler.replace(metrics: snapshot.metrics, source: snapshot.source)
                    cycler.advance()
                    // The periodic re-assert, through the same rule as every
                    // other write. One claim at `onAppear` is a claim about a
                    // moment; this makes it a claim about the session — but
                    // only for as long as `awake` says the wallboard is still
                    // the thing being watched. A loop that outlived its tab
                    // re-asserts nothing.
                    applyHold()
                }
            }
    }

    /// Leaves the wallboard, releasing the hold on the way out.
    ///
    /// The release cannot live in `onDisappear` alone: a `TabView` is free to
    /// keep a tab's content alive across a sidebar switch, and if it does, the
    /// tick loop above would go on re-asserting from a tab nobody is looking
    /// at. Releasing here means the two routes out of this screen — select and
    /// Menu — both hand the idle timer back explicitly, whatever the `TabView`
    /// decides to keep alive.
    private func leave() {
        awake.leave()
        applyHold()
        exit()
    }

    /// Routes Ambient lifecycle updates through the one idle-timer write.
    private func applyHold() {
        awake.applyIdleTimerHold()
    }

    /// The dashboard tiles the phone already reduced, together with whether
    /// they came from an explicit pin or the deterministic fallback. This is
    /// the same App Group snapshot Top Shelf reads, so the wallboard and shelf
    /// cannot disagree about either the metrics or their provenance.
    private static func ambientSnapshot() -> (
        metrics: [SharedSnapshot.Metric],
        source: SharedSnapshot.MetricSource
    ) {
        guard let snapshot = SharedSnapshotStore.shared.loadOrNil() else {
            return ([], .unknown)
        }
        return (snapshot.metrics, snapshot.metricSource)
    }

    @ViewBuilder
    private var content: some View {
        if let metric = cycler.current {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(metric.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Ink.secondary)

                Text(Self.provenanceCaption(cycler.source))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)

                Text(metric.value.compactFormatted)
                    .font(.system(size: 160, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)

                // The unit gets its own line rather than riding on the
                // headline. Measured: a bar-value tile's unit is the *label of
                // the bar it came from*, which on the demo data is a URL —
                // "393 example.com synthetic fixture 6" on one line shrank the
                // number to a fraction of its size to fit a string nobody
                // reads from the sofa. The figure is what a wallboard is for;
                // the label says what it counts.
                if let unit = metric.unit, !unit.isEmpty {
                    Text(unit)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(2)
                }

                if let delta = Self.deltaPhrase(metric) {
                    Text(delta)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Ink.secondary)
                }

                sparkline(metric)

                pageIndicator
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.spoken(metric, source: cycler.source))
            .accessibilityIdentifier("tv-ambient-wallboard")
        } else {
            ContentUnavailableView(
                "Nothing pinned yet",
                systemImage: "pin.slash",
                description: Text("Pinned insights appear here once a dashboard has loaded.")
            )
            .accessibilityIdentifier("tv-ambient-empty")
        }
    }

    @ViewBuilder
    private func sparkline(_ metric: SharedSnapshot.Metric) -> some View {
        if metric.sparkline.count > 1 {
            Chart(Array(metric.sparkline.enumerated()), id: \.offset) { point in
                LineMark(
                    x: .value("Point", point.offset),
                    y: .value("Value", point.element)
                )
                .foregroundStyle(SeriesPalette.color(at: 0))
                .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 180)
            // Decorative beside a number that is already spoken; a chart with no
            // axes has nothing more to tell a screen reader.
            .accessibilityHidden(true)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(cycler.metrics.indices, id: \.self) { position in
                Circle()
                    .fill(position == cycler.index ? Theme.accent : Theme.Ink.tertiary)
                    .frame(width: 12, height: 12)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Wording

    static func headline(_ metric: SharedSnapshot.Metric) -> String {
        let value = metric.value.compactFormatted
        guard let unit = metric.unit, !unit.isEmpty else { return value }
        return "\(value) \(unit)"
    }

    /// `nil` when there is no comparison period — the same contract
    /// `SharedSnapshot.Metric.previous` documents, where nil means "not known"
    /// rather than "no change".
    static func deltaPhrase(_ metric: SharedSnapshot.Metric) -> String? {
        guard let fraction = metric.deltaFraction else { return nil }
        let percent = abs(fraction).formatted(.percent.precision(.fractionLength(0)))
        return metric.direction == .flat ? "No change" : "Changed \(percent)"
    }

    static func provenanceCaption(_ source: SharedSnapshot.MetricSource) -> String {
        switch source {
        case .pinnedDashboard: "Pinned dashboard"
        case .deterministicFallback: "First dashboard (fallback)"
        case .unknown: "Dashboard snapshot"
        }
    }

    static func spoken(
        _ metric: SharedSnapshot.Metric,
        source: SharedSnapshot.MetricSource = .unknown
    ) -> String {
        [metric.title, provenanceCaption(source), headline(metric), deltaPhrase(metric)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
