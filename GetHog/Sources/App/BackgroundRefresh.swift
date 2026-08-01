import BackgroundTasks
import Foundation
import GetHogKit
import os

/// The `BGAppRefreshTask` that keeps the widget snapshot from going stale.
///
/// The cadence and the "is this wake worth spending requests on" decision live
/// in `BackgroundRefreshPolicy`, where they are pure and tested. Everything here
/// is the part that can only be exercised by iOS: registration, submission, and
/// the expiration handshake.
///
/// The shape follows the same rule as the widgets themselves — one coalesced
/// refresh per wake, feeding every metric from a single dashboard fetch, through
/// the same rate-limit governor as every other request. Background traffic is
/// the least supervised thing this app does, so it gets the strictest budget.
@MainActor
enum BackgroundRefresh {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in the app's Info.plist.
    /// `BGTaskScheduler` rejects an identifier that is not declared there, and it
    /// does so at registration, before any of this can run.
    static let taskIdentifier = "app.gethog.refresh.snapshot"

    private static let log = Logger(subsystem: "app.gethog", category: "background-refresh")

    // MARK: - Registration

    /// Registers the launch handler.
    ///
    /// Has to happen before the app finishes launching — `BGTaskScheduler`
    /// traps on a task identifier it was handed after that point — which is why
    /// this is called from `GetHogApp.init` rather than from a `.task`.
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
            // Almost always a missing or misspelled Info.plist identifier, which
            // is silent otherwise: the app runs, and simply never refreshes.
            log.error("Could not register the background refresh task.")
        }
    }

    // MARK: - Scheduling

    /// Asks for the next wake.
    ///
    /// Called when the app leaves the foreground and again from every completed
    /// wake. There is no repeat mode in `BGTaskScheduler`: a run that forgets to
    /// submit the next request is the last one the app ever gets.
    static func schedule(model: AppModel, refreshedAt: Date?, now: Date = Date()) {
        guard BackgroundRefreshPolicy.shouldSchedule(hasCredential: model.hasStoredCredential) else {
            cancel()
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = BackgroundRefreshPolicy.earliestBeginDate(
            lastRefreshedAt: refreshedAt, now: now
        )

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected and harmless in several ordinary situations — Low Power
            // Mode, background refresh switched off for the app, a simulator
            // without the entitlement. The app keeps working; it just refreshes
            // when the user opens it.
            log.notice("Could not submit a background refresh request.")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    // MARK: - Running

    static func handle(_ task: BGAppRefreshTask, model: AppModel, now: Date = Date()) {
        // Submitted before the work starts, not after it succeeds. A wake that
        // crashes, is expired, or is killed mid-flight would otherwise leave no
        // pending request and the app would silently stop refreshing forever.
        // Dated from now rather than from the last snapshot, so a failed wake
        // waits a full interval instead of retrying against a budget that is not
        // ours to spend.
        schedule(model: model, refreshedAt: now, now: now)

        let work = Task { @MainActor in
            let refreshed = await model.performBackgroundRefresh(now: now)
            // An expired wake reports failure even if it happened to finish:
            // it did not do what it promised inside the time it was given, and
            // saying otherwise skews the scheduler's model of this app.
            task.setTaskCompleted(success: refreshed && !Task.isCancelled)
        }

        // Only cancels. Completion stays on the one path above — `BGTask`
        // tolerates exactly one `setTaskCompleted`, and an expiration handler
        // that also completes races the work it just cancelled.
        task.expirationHandler = { work.cancel() }
    }
}

/// A value the compiler cannot prove is safe to move between isolation domains,
/// vouched for at the one call site that knows it is.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) { self.value = value }
}
