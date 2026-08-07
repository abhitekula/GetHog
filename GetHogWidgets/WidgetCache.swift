import AppIntents
import Foundation
import GetHogKit
import GetHogUI
import SwiftUI
import WidgetKit

/// The widget extension's entire view of the outside world.
///
/// **This extension never calls the PostHog API.** Rate limits are billed per
/// *organisation* and that budget is shared with the user's own production
/// integrations — a few installed widgets, each waking on its own schedule,
/// would multiply request volume against an allowance that isn't ours to spend,
/// from a process the user never launched. The app fetches, reduces the result
/// to `SharedSnapshot`, and writes it to the App Group container; everything
/// here is a read of that file.
///
/// The consequence is deliberate: when the snapshot is missing or old, the
/// widget says so and offers to open the app. It does not quietly go and get
/// fresher data.
enum WidgetCache {

    static var store: SharedSnapshotStore { .shared }

    static func snapshot() -> SharedSnapshot? { store.loadOrNil() }

    /// Only flags the user opted in to. Outside the app there is no confirmation
    /// dialog to answer, so a flag stays invisible to widgets and Control Center
    /// until the user deliberately allows it.
    static func quickToggleFlags() -> [SharedSnapshot.Flag] {
        snapshot()?.quickToggleFlags ?? []
    }

    /// The user's metric watches, read for Smart Stack ranking only.
    ///
    /// The extension never evaluates a watch for *delivery* — that belongs to the
    /// app, which owns the notification centre and the breach latch that keeps a
    /// single incident from being announced every two hours. All this read buys is
    /// the answer to "did the user ask to be told about this number", which is the
    /// strongest signal available for whether the widget deserves the top of a
    /// stack. See `SnapshotRelevance.isBreaching`, which is careful to ask that
    /// question without touching the latch.
    static func metricWatches() -> [MetricWatch] { store.metricWatches() }

    static func quickToggleFlag(id: Int?) -> SharedSnapshot.Flag? {
        let candidates = quickToggleFlags()
        guard let id else { return candidates.first }
        // The lookup goes through the opted-in list, not the full flag list: a
        // configuration saved while a flag was allowed must stop working the
        // moment the user revokes that permission.
        return candidates.first { $0.id == id }
    }

    // MARK: Empty-state words

    /// The words for a widget with nothing to show, chosen by cause.
    ///
    /// `isSharedContainer` is false when the App Group container was unusable
    /// and the store fell back to a private directory — the ordinary state of a
    /// teamless Debug build on macOS, where either group entitlement alone
    /// makes the target refuse to build (see GetHogMac.entitlements). The app
    /// and this extension are then not talking to each other, so "Open GetHog
    /// to sync" would promise something opening the app cannot deliver. The
    /// honest words name the actual condition instead.
    ///
    /// iOS keeps its exact shipping string on every path: the unshared state
    /// exists there only in previews and unsigned test hosts, and a widget's
    /// empty state is not the place to explain those.
    static var noDataMessage: String {
        noDataMessage(sharedContainer: store.isSharedContainer)
    }

    /// Split from the property so both branches are testable from macOS, where
    /// no test can construct the other platform's container.
    static func noDataMessage(sharedContainer: Bool) -> String {
        #if os(macOS)
        if !sharedContainer {
            return "Open GetHog to connect. This build can't share data with widgets."
        }
        #endif
        return "Open GetHog to sync"
    }

    // MARK: Sample data

    /// Used for placeholders, the widget gallery, and previews. Plausible but
    /// obviously generic, so nobody mistakes gallery art for their own numbers.
    static let sample = SharedSnapshot(
        projectID: 0,
        projectName: "Your project",
        metrics: [
            // `dashboardID` is nil throughout: these are gallery placeholders,
            // and no dashboard exists that they were read from. Naming one would
            // be inventing a destination for a tap the gallery never routes.
            .init(
                id: "1", title: "Active users", value: 12_480, unit: nil, previous: 10_920,
                sparkline: [8_900, 9_400, 10_100, 10_920, 11_600, 12_480], dashboardID: nil
            ),
            .init(
                id: "2", title: "Signups", value: 318, unit: nil, previous: 344,
                sparkline: [402, 380, 355, 344, 330, 318], dashboardID: nil
            ),
            .init(id: "3", title: "Bounce rate", value: 41.2, unit: "%", previous: 44.9,
                  sparkline: [], dashboardID: nil),
            .init(
                id: "4", title: "Errors", value: 27, unit: nil, previous: 27,
                sparkline: [31, 29, 28, 27, 27, 27], dashboardID: nil
            ),
            .init(id: "5", title: "Revenue", value: 8_640, unit: "$", previous: 7_900,
                  sparkline: [], dashboardID: nil),
            .init(id: "6", title: "Sessions", value: 44_120, unit: nil, previous: nil,
                  sparkline: [], dashboardID: nil),
        ],
        flags: [
            .init(id: 1, key: "new-onboarding", active: true, quickToggleAllowed: true),
            .init(id: 2, key: "beta-search", active: false, quickToggleAllowed: true),
        ],
        // The gallery has to show the state worth installing the widget for. A
        // sample that read "nothing to report" would look like a widget that
        // renders nothing — and the two are indistinguishable in a gallery cell.
        ingestion: .init(
            typeCount: 3,
            errorCount: 1,
            warningCount: 2,
            affectedEvents: 5_332,
            topTitle: "Cannot merge already identified",
            topSeverity: .error,
            topCount: 4_182,
            topSparkline: [12, 40, 133, 0, 9, 402, 1_180, 903, 744, 219, 88, 452],
            windowTitle: "7 days",
            capturedAt: Date()
        ),
        quota: .init(
            blockedCount: 0,
            pressingCount: 1,
            resourceCount: 18,
            topTitle: "Signals credits",
            topState: .watch,
            topUsage: 3_000,
            topLimit: 4_500,
            // Deliberately older than the snapshot, so the gallery shows the
            // "as of 4h ago" note this section carries in real life rather than
            // hiding a behaviour the user will meet on their first sync.
            capturedAt: Date().addingTimeInterval(-4 * 60 * 60)
        ),
        capturedAt: Date()
    )
}

// MARK: - Refresh policy

/// How often the extension asks WidgetKit to call the provider again.
///
/// WidgetKit gives each widget a *daily* budget of refreshes (roughly 40–70,
/// depending on how the user actually looks at the widget). Asking every 15
/// minutes would want ~96 a day, so the system would silently throttle us and
/// the cadence would become unpredictable.
///
/// Instead each timeline carries an hour of entries fifteen minutes apart. The
/// values are identical — they all come from the same snapshot — but the entry
/// dates advance, so the "Updated 20 min ago" line stays truthful without the
/// provider being woken. That is one provider call an hour, comfortably inside
/// the budget, and it leaves headroom for the reload the app triggers whenever
/// it writes a fresher snapshot. That reload, not this timer, is what actually
/// makes a widget current.
///
/// `.after` and never `.atEnd`: `.atEnd` on a timeline whose entries are already
/// in the past turns into a reload loop that burns the whole day's budget in
/// minutes.
enum WidgetRefresh {

    static let step: TimeInterval = 15 * 60
    static let horizon: TimeInterval = 60 * 60

    static func entryDates(from start: Date) -> [Date] {
        stride(from: 0, to: horizon, by: step).map { start.addingTimeInterval($0) }
    }

    static func nextReload(from start: Date) -> Date {
        start.addingTimeInterval(horizon)
    }

    static func timeline<E: TimelineEntry>(from start: Date, entry: (Date) -> E) -> Timeline<E> {
        Timeline(entries: entryDates(from: start).map(entry), policy: .after(nextReload(from: start)))
    }
}

// MARK: - Hand-off to the app

/// The only "refresh" a widget can honestly offer: open the app, which holds the
/// credentials, the rate-limit governor, and somewhere to show a failure.
struct RefreshInAppIntent: AppIntent {

    static var title: LocalizedStringResource { "Open GetHog to sync" }
    static var description: IntentDescription {
        IntentDescription("Opens GetHog so it can refresh the data your widgets show.")
    }

    /// The whole point. The extension has no business fetching, so "refresh"
    /// can only mean "hand this to the process that can".
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult { .result() }
}

extension SharedSnapshotStore {

    /// Best-effort: a failed hand-off means the app opens on its last screen
    /// instead of the requested one, which is not worth surfacing an error for
    /// in a process that has no UI.
    func requestOpen(_ open: PendingOpen) {
        try? enqueue(open)
    }

    func requestFlagWrite(_ write: PendingFlagWrite) {
        try? enqueue(write)
    }
}
