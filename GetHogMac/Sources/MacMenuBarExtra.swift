import AppKit
import GetHogKit
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
