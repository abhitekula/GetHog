#if os(visionOS)
import BackgroundTasks
import Foundation
import GetHogKit
import os

/// The Vision twin of the iOS `BackgroundRefresh` (excluded from this target):
/// keeps the shared snapshot from going stale.
///
/// visionOS speaks `BGTaskScheduler`, not `NSBackgroundActivityScheduler`, so
/// the mechanism here is the iOS one rather than the Mac's — register before
/// launch ends, ask for the next wake from the top of every wake, and run one
/// coalesced fetch through `AppModel.performBackgroundRefresh`, hence through
/// the model's own `RateLimitGovernor` and into `SharedSnapshotStore`. Nothing
/// here fetches, decides what to fetch, or writes a file itself.
///
/// The cadence stays pure and testable in `VisionRefreshSchedule` below, the
/// same split `MacRefreshSchedule` makes.
@MainActor
enum VisionRefresh {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in this target's
    /// Info.plist — `BGTaskScheduler` rejects an undeclared identifier at
    /// registration, before any of this can run. The same name as the iOS task
    /// and the Mac activity, on purpose: one feature, one string in the logs.
    static let taskIdentifier = "app.gethog.refresh.snapshot"

    private static let log = Logger(subsystem: "app.gethog", category: "background-refresh")

    // MARK: - Registration

    /// Registers the launch handler.
    ///
    /// Called from `GetHogVisionApp.init` rather than from a `.task`, because
    /// `BGTaskScheduler` traps on an identifier handed to it after the app has
    /// finished launching.
    static func register(model: AppModel) {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            // The scheduler hands this task to exactly one launch handler and
            // never touches it again, so moving it to the main actor is safe;
            // `BGTask` simply predates `Sendable` and cannot say so itself.
            let handoff = UncheckedSendable(task)
            Task { @MainActor in handle(handoff.value, model: model) }
        }

        if !registered {
            // Almost always a missing or misspelled Info.plist identifier,
            // which is silent otherwise: the app runs and never refreshes.
            log.error("Could not register the background refresh task.")
        }
    }

    // MARK: - Scheduling

    /// Asks for the next wake.
    ///
    /// There is no repeat mode in `BGTaskScheduler`: a run that forgets to
    /// submit the next request is the last one the app ever gets.
    static func schedule(model: AppModel, refreshedAt: Date?, now: Date = Date()) {
        switch VisionRefreshSchedule.action(
            hasCredential: model.hasStoredCredential,
            lastRefreshedAt: refreshedAt,
            now: now
        ) {
        case .standDown:
            cancel()

        case .schedule(let earliestBeginDate):
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = earliestBeginDate
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // Expected and harmless in several ordinary situations —
                // background refresh switched off for the app, a simulator
                // without the entitlement. The app refreshes in the foreground
                // either way.
                log.notice("Could not submit a background refresh request.")
            }
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    // MARK: - Running

    static func handle(_ task: BGAppRefreshTask, model: AppModel, now: Date = Date()) {
        // Submitted before the work starts, not after it succeeds. A wake that
        // crashes, expires or is killed mid-flight would otherwise leave no
        // pending request and the app would silently stop refreshing forever.
        // Dated from now rather than from the last snapshot, so a failed wake
        // waits a full interval instead of retrying against a budget that is
        // not ours to spend.
        schedule(model: model, refreshedAt: now, now: now)

        let work = Task { @MainActor in
            let refreshed = await model.performBackgroundRefresh(now: now)
            // An expired wake reports failure even if it happened to finish: it
            // did not do what it promised inside the time it was given, and
            // saying otherwise skews the scheduler's model of this app.
            task.setTaskCompleted(success: refreshed && !Task.isCancelled)
        }

        // Only cancels. Completion stays on the one path above — `BGTask`
        // tolerates exactly one `setTaskCompleted`, and an expiration handler
        // that also completes races the work it just cancelled.
        task.expirationHandler = { work.cancel() }
    }
}

/// The schedule decision, pure and apart from the scheduler that acts on it —
/// the same split `MacRefreshSchedule` makes, restated for a scheduler with no
/// deferral handshake.
///
/// The cadence is `BackgroundRefreshPolicy`'s, unchanged. Its two-hour floor is
/// already the strictest budget in the app, and a Vision-only interval would be
/// a second source of truth for a number that means the same thing here.
enum VisionRefreshSchedule {

    /// What one scheduling opportunity should do.
    enum Action: Equatable {
        /// Submit a request the system may not begin before this date.
        case schedule(earliestBeginDate: Date)
        /// Cancel any pending request and ask for nothing.
        case standDown
    }

    /// A wake with no credential can only fail, and failures teach the system
    /// that this app's background requests are not worth granting.
    static func action(hasCredential: Bool, lastRefreshedAt: Date?, now: Date) -> Action {
        guard BackgroundRefreshPolicy.shouldSchedule(hasCredential: hasCredential) else {
            return .standDown
        }
        return .schedule(
            earliestBeginDate: BackgroundRefreshPolicy.earliestBeginDate(
                lastRefreshedAt: lastRefreshedAt,
                now: now
            )
        )
    }
}

/// A value the compiler cannot prove is safe to move between isolation domains,
/// vouched for at the one call site that knows it is. The same shape the iOS
/// `BackgroundRefresh` declares privately for `BGTask`; that file is excluded
/// from this target, so the twin carries its own copy.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) { self.value = value }
}
#endif
