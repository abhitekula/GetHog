import AppIntents
import Foundation
import GetHogKit
import GetHogUI
import SwiftUI
import WidgetKit

/// The only route a cached metric can authoritatively name.
///
/// Both identifiers come from the same app-written snapshot. A dashboard id
/// without its project scope can resolve against whichever project happens to
/// be selected when the app opens; a project without a dashboard is merely a
/// home-screen guess. Gallery and legacy entries therefore produce no URL.
enum WidgetMetricRoute {
    static func url(projectID: Int?, dashboardID: Int?) -> URL? {
        guard let projectID, let dashboardID else { return nil }
        return URL(string: "gethog://project/\(projectID)/dashboard/\(dashboardID)")
    }
}

/// The widget extension's shared cache and refresh dependencies.
///
/// Rendering remains a local file read. A timeline request may opportunistically
/// refresh a stale snapshot, and the explicit refresh button always asks
/// PostHog, but both go through one cross-process lease and one full-snapshot
/// coordinator. Installing several widgets therefore does not multiply one
/// provider wake into several simultaneous API refreshes.
enum WidgetCache {

    static var store: SharedSnapshotStore {
        #if os(macOS) && GETHOG_UNSHARED_MAC_WIDGETS
        // Defense in depth for metadata or a future Debug-only surface: the
        // teamless extension never asks Foundation to resolve an App Group it
        // is not entitled to enter, even if a cache reader is accidentally
        // reached outside the three neutral wrappers.
        SharedSnapshotStore.resolve(container: { _ in nil })
        #else
        SharedSnapshotStore.shared
        #endif
    }

    static func snapshot() -> SharedSnapshot? { store.loadOrNil() }

    static var selectedProjectID: Int? {
        #if os(macOS) && GETHOG_UNSHARED_MAC_WIDGETS
        nil
        #else
        let defaults = UserDefaults(suiteName: SharedSnapshotStore.bundleAppGroupIdentifier)
        let id = defaults?.integer(forKey: "selectedProjectID") ?? 0
        return id == 0 ? nil : id
        #endif
    }

    /// Only flags the user opted in to. Outside the app there is no confirmation
    /// dialog to answer, so a flag stays invisible to widgets and Control Center
    /// until the user deliberately allows it.
    static func quickToggleFlags() -> [SharedSnapshot.Flag] {
        snapshot()?.quickToggleFlags ?? []
    }

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

// MARK: - Direct refresh

enum WidgetSnapshotRefresh {

    @discardableResult
    static func run(_ trigger: SnapshotRefreshTrigger) async -> SnapshotRefreshResult {
        let store = WidgetCache.store
        guard store.isSharedContainer else { return .current(nil) }
        guard let credential = try? KeychainTokenStore().load(),
              let authSessionID = credential.authSessionID else {
            return .failed(.unauthorized, retained: store.loadOrNil())
        }

        let previous = store.loadOrNil()
        guard let projectID = WidgetCache.selectedProjectID
                ?? credential.projectID
                ?? previous?.projectID else {
            return .failed(.unavailable, retained: previous)
        }
        let projectName = previous?.projectID == projectID
            ? previous?.projectName ?? "Project \(projectID)"
            : "Project \(projectID)"
        let scope = SnapshotRefreshScope(
            projectID: projectID,
            projectName: projectName,
            region: credential.region,
            authSessionID: authSessionID
        )
        let allowedFlagIDs = Set(
            previous?.projectID == projectID
                ? previous?.quickToggleFlags.map(\.id) ?? []
                : []
        )
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: credential.key, region: credential.region)
        )
        return await SnapshotRefreshCoordinator(store: store).refresh(
            trigger: trigger,
            client: client,
            scope: scope,
            quickToggleAllowed: { allowedFlagIDs.contains($0) },
            isAuthorized: {
                guard let latest = try? KeychainTokenStore().load(),
                      latest.region == scope.region,
                      latest.authSessionID == scope.authSessionID else {
                    return false
                }
                return WidgetCache.selectedProjectID.map { $0 == scope.projectID } ?? true
            }
        )
    }
}

/// Refreshes from the widget extension without opening GetHog. WidgetKit reloads
/// the originating widget after the intent completes; intentionally no
/// `reloadAllTimelines` or kind-wide reload is requested here.
struct RefreshWidgetIntent: AppIntent {

    static var title: LocalizedStringResource { "Refresh widget" }
    static var description: IntentDescription {
        IntentDescription("Refreshes this widget's shared PostHog snapshot without opening GetHog.")
    }

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await WidgetSnapshotRefresh.run(.manualWidget)
        return .result()
    }
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
