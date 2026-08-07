import Foundation
import GetHogKit
import Observation

/// Coalesces the TV shell's foreground and Ambient refresh triggers.
///
/// Ambient's display clock is intentionally quick, but its API clock is not:
/// the latter inherits `BackgroundRefreshPolicy.minimumInterval`, the same
/// organisation-wide request-budget policy used by the phone's background
/// wake. Recording attempts, not just successful snapshot dates, also prevents
/// an unreachable service from being retried every twelve seconds.
@MainActor
@Observable
final class TVSnapshotRefreshCoordinator {

    enum Result: Equatable {
        case notDue
        case inFlight
        case started
        case attempted
        case refreshed
        case cancelled
    }

    static let minimumInterval = BackgroundRefreshPolicy.minimumInterval

    private(set) var lastAttemptAt: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored
    private var operation: Task<Bool, Never>?
    @ObservationIgnored
    private var generation: UInt = 0

    /// Runs one refresh when neither a snapshot nor a previous attempt falls
    /// inside the shared floor. Concurrent foreground and Ambient triggers are
    /// folded into the request already in flight.
    func refreshIfDue(
        now: Date = Date(),
        lastSnapshotAt: Date?,
        operation refresh: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Result {
        guard !isRefreshing else { return .inFlight }
        guard Self.isDue(
            now: now,
            lastSnapshotAt: lastSnapshotAt,
            lastAttemptAt: lastAttemptAt
        ) else { return .notDue }

        lastAttemptAt = now
        isRefreshing = true
        generation &+= 1
        let currentGeneration = generation
        let task = Task { await refresh() }
        operation = task

        let refreshed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // Cancel this waiter's child directly. An actor hop that later
            // called the coordinator's unconditional `cancel()` could arrive
            // after a replacement had started and cancel the wrong generation.
            task.cancel()
        }

        return finish(
            refreshed: refreshed,
            cancelled: task.isCancelled,
            generation: currentGeneration
        )
    }

    /// Starts one due refresh and returns before its network work completes.
    ///
    /// Ambient uses this form so its twelve-second visual cycle — snapshot
    /// adoption, metric advance, and idle-timer reassertion — never waits on
    /// the dashboard/flags/health request chain. The coordinator still owns
    /// and coalesces the child, so scene cancellation remains authoritative.
    @discardableResult
    func startIfDue(
        now: Date = Date(),
        lastSnapshotAt: Date?,
        operation refresh: @escaping @MainActor @Sendable () async -> Bool
    ) -> Result {
        guard !isRefreshing else { return .inFlight }
        guard Self.isDue(
            now: now,
            lastSnapshotAt: lastSnapshotAt,
            lastAttemptAt: lastAttemptAt
        ) else { return .notDue }

        lastAttemptAt = now
        isRefreshing = true
        generation &+= 1
        let currentGeneration = generation
        let task = Task { @MainActor [weak self] in
            let refreshed = await refresh()
            let cancelled = Task.isCancelled
            _ = self?.finish(
                refreshed: refreshed,
                cancelled: cancelled,
                generation: currentGeneration
            )
            return refreshed
        }
        operation = task
        return .started
    }

    /// Cancels work owned by a scene that is no longer active.
    ///
    /// The attempt normally remains recorded: cancellation can happen after
    /// requests have reached the service, so an immediate foreground retry
    /// could double the spend. Tests may reset it to prove a clean lifecycle.
    func cancel(resetAttempt: Bool = false) {
        generation &+= 1
        operation?.cancel()
        operation = nil
        isRefreshing = false
        if resetAttempt { lastAttemptAt = nil }
    }

    /// Completes only the operation that reserved `currentGeneration`.
    /// A cancelled predecessor returning after a replacement is already in
    /// flight therefore cannot clear the replacement's task or busy state.
    private func finish(
        refreshed: Bool,
        cancelled: Bool,
        generation currentGeneration: UInt
    ) -> Result {
        guard generation == currentGeneration else { return .cancelled }
        operation = nil
        isRefreshing = false
        if cancelled { return .cancelled }
        return refreshed ? .refreshed : .attempted
    }

    static func isDue(
        now: Date,
        lastSnapshotAt: Date?,
        lastAttemptAt: Date?
    ) -> Bool {
        let reference = [lastSnapshotAt, lastAttemptAt].compactMap { $0 }.max()
        guard let reference else { return true }
        return now.timeIntervalSince(reference) >= minimumInterval
    }
}
