import Foundation
import GetHogKit
import WatchKit
import WidgetKit
import os

/// The watch twin of the iOS `BackgroundRefresh`: keeps the snapshot the
/// complications read from going stale while nobody is looking.
///
/// **`BackgroundTasks.framework` does not exist in the watch SDK** — there is
/// no `BGTaskScheduler` here, so neither the iOS nor the Vision mechanism is
/// available. What watchOS offers is
/// `WKApplication.scheduleBackgroundRefresh(withPreferredDate:…)` to ask for a
/// wake, and SwiftUI's `Scene.backgroundTask(.appRefresh)` to receive it — the
/// SwiftUI delivery of `WKApplicationRefreshBackgroundTask`, which suits an app
/// with no `WKApplicationDelegate` and lets the handler be an ordinary `async`
/// function.
///
/// ## The fetch runs in-process, and that is a deliberate deviation
///
/// The task brief named `WKURLSessionRefreshBackgroundTask`. The SDK argues
/// against it here: a **background `URLSession` carries download and upload
/// tasks only**, while a watch refresh is five small sequential authenticated
/// JSON requests reduced in memory through `PostHogClient`, whose transport is
/// in-process `async`. The canonical two-wake download dance would need
/// file-based responses and a new transport seam in `GetHogKit`, which is a
/// larger change than the problem. So the refresh runs inside the
/// `.backgroundTask(.appRefresh)` action, which watchOS keeps the app alive
/// for.
///
/// **The constraint that buys, stated plainly:** the system grants that action
/// a budget, and a wake on a cold radio may not finish all five requests inside
/// it. When it does not, nothing is corrupted — `WatchModel.refresh` only
/// replaces the snapshot once it has reached the API, and a wake that reached
/// nothing leaves the previous files and their honest age alone. The cost is a
/// missed refresh, not a wrong one. Moving to a background `URLSession` would
/// remove that ceiling and is the named follow-up.
///
/// Everything this file *decides* is in `WatchRefreshSchedule` below, pure and
/// tested. What is left here is the part only the system can exercise: the
/// scheduler call, the pending stamp, and the widget reload.
@MainActor
enum WatchRefresh {

    private static let log = Logger(subsystem: "app.gethog", category: "background-refresh")

    /// When the wake we asked for is due.
    ///
    /// `UserDefaults.standard`, not the App Group: this is one process's
    /// bookkeeping about its own pending request, and no widget has any
    /// business reading it. WatchKit offers no way to ask whether a request is
    /// already outstanding — and scheduling a second one silently cancels the
    /// first — so the stamp is how this app keeps "only one at a time" true.
    static let pendingDateKey = "watchPendingRefreshDate"

    // MARK: - Scheduling

    /// Asks for the next wake, unless one is already pending or there is
    /// nothing to fetch with.
    static func scheduleNextWake(
        hasCredential: Bool,
        lastRefreshedAt: Date?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let pending = defaults.object(forKey: pendingDateKey) as? Date
        switch WatchRefreshSchedule.scheduleAction(
            hasCredential: hasCredential,
            pendingPreferredDate: pending,
            lastRefreshedAt: lastRefreshedAt,
            now: now
        ) {
        case .alreadyScheduled:
            return

        case .standDown:
            // Nothing to cancel through: WatchKit has no cancel call, and a
            // pending request with no credential simply wakes an app that will
            // stand itself down. Forgetting the stamp is what matters, so a
            // later sign-in schedules rather than believing one is in flight.
            defaults.removeObject(forKey: pendingDateKey)

        case .schedule(let preferredDate):
            WKApplication.shared().scheduleBackgroundRefresh(
                withPreferredDate: preferredDate,
                userInfo: nil
            ) { error in
                Task { @MainActor in
                    if error != nil {
                        // Expected in ordinary situations — background refresh
                        // switched off for the app, a simulator without the
                        // entitlement. The app refreshes in the foreground
                        // either way; what must not happen is a stamp claiming
                        // a wake that was never granted.
                        defaults.removeObject(forKey: pendingDateKey)
                        log.notice("Could not schedule a background refresh wake.")
                    } else {
                        defaults.set(preferredDate, forKey: pendingDateKey)
                    }
                }
            }
        }
    }

    // MARK: - Running

    /// Handles one granted wake.
    ///
    /// Called from `GetHogWatchApp`'s `.backgroundTask(.appRefresh)`.
    ///
    /// The next wake is asked for **first, dated from now**, before any fetch:
    /// there is no repeat mode, so a wake that dies mid-flight would otherwise
    /// be the last one this app ever got. Dating it from now rather than from
    /// the snapshot means a failed wake waits a full interval instead of
    /// retrying against a budget that is not ours to spend.
    ///
    /// A background wake relaunches the app without the demo environment
    /// variables, so demo mode can never survive into an unattended fetch and
    /// needs no special case here.
    static func handleAppRefresh(
        model: WatchModel,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) async {
        defaults.removeObject(forKey: pendingDateKey)
        let lastRefreshedAt = model.snapshot?.capturedAt
        scheduleNextWake(
            hasCredential: model.hasCredential,
            lastRefreshedAt: now,
            now: now,
            defaults: defaults
        )

        guard WatchRefreshSchedule.wakeAction(
            hasCredential: model.hasCredential,
            lastRefreshedAt: lastRefreshedAt,
            now: now
        ) == .refresh else { return }

        // Unforced: the model's own fifteen-minute throttle and the client's
        // `RateLimitGovernor` still apply, and a wake minutes after a
        // foreground refresh should cost nothing.
        await model.refresh(force: false)
    }

    // MARK: - Telling the complications

    /// Called by `WatchModel` after it writes a fresher snapshot.
    ///
    /// The reload is what actually makes a complication current — the timeline
    /// cadence in `WatchWidgetRefresh` only keeps the age label honest between
    /// reloads. The relevance invalidation is separate and necessary: the Smart
    /// Stack caches the answer to `relevance()`, and the firing state that
    /// answer was computed from may have just flipped.
    static func snapshotDidPublish() {
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.invalidateRelevance(ofKind: WatchRefreshSchedule.stackWidgetKind)
    }
}

/// The refresh cadence, decided without a scheduler in the room — the split
/// `MacRefreshSchedule` and `VisionRefreshSchedule` both make.
///
/// The numbers are `BackgroundRefreshPolicy`'s, unchanged. Its two-hour floor
/// is already the strictest budget in the app and a watch-only interval would
/// be a second source of truth for a number that means the same thing here.
enum WatchRefreshSchedule {

    /// The floor between two unattended refreshes.
    ///
    /// **On the budget, honestly.** watchOS grants an app with an active
    /// complication roughly four background wakes an hour. This schedule asks
    /// for one every two hours, so the system's ceiling is not the governing
    /// constraint — the kit's organisation-wide request budget is. One wake
    /// spends `WatchModel`'s documented five requests, which is at most sixty a
    /// day unattended, against an allowance shared with whatever the user's own
    /// production integrations are doing.
    static var interval: TimeInterval { BackgroundRefreshPolicy.minimumInterval }

    /// Wakes an hour the system will grant an app with a live complication.
    /// Here to be compared against, not to be aimed at.
    static let systemWakesPerHour = 4

    /// The kind whose relevance is invalidated when the snapshot changes. The
    /// string is `WatchStackWidget.kind`, which lives in the extension binary
    /// and cannot be named from the app.
    static let stackWidgetKind = "app.gethog.watch.stack"

    /// What one scheduling opportunity should do.
    enum ScheduleAction: Equatable {
        /// Ask the system for a wake no earlier than this date.
        case schedule(preferredDate: Date)
        /// A request is already outstanding. Scheduling a second one silently
        /// cancels the first, so the right move is to leave it alone.
        case alreadyScheduled
        /// Ask for nothing and forget any stamp.
        case standDown
    }

    /// A wake with no credential can only fail, and failures teach the system
    /// that this app's background requests are not worth granting.
    static func scheduleAction(
        hasCredential: Bool,
        pendingPreferredDate: Date?,
        lastRefreshedAt: Date?,
        now: Date
    ) -> ScheduleAction {
        guard BackgroundRefreshPolicy.shouldSchedule(hasCredential: hasCredential) else {
            return .standDown
        }
        if let pendingPreferredDate, pendingPreferredDate > now {
            return .alreadyScheduled
        }
        return .schedule(
            preferredDate: BackgroundRefreshPolicy.earliestBeginDate(
                lastRefreshedAt: lastRefreshedAt, now: now
            )
        )
    }

    /// What one granted wake should do.
    enum WakeAction: Equatable {
        case refresh
        case standDown
    }

    /// The coalescing guard: the app may have been on the wrist minutes ago and
    /// refreshed in the foreground, in which case this wake has nothing to add
    /// and should cost nothing.
    static func wakeAction(hasCredential: Bool, lastRefreshedAt: Date?, now: Date) -> WakeAction {
        guard BackgroundRefreshPolicy.shouldSchedule(hasCredential: hasCredential) else {
            return .standDown
        }
        return BackgroundRefreshPolicy.isDue(lastRefreshedAt: lastRefreshedAt, now: now)
            ? .refresh
            : .standDown
    }
}
