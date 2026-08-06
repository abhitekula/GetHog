import Foundation
import GetHogKit
import os

/// The Mac twin of the iOS `BackgroundRefresh` (excluded from this target):
/// keeps the shared snapshot from going stale while the app runs.
///
/// macOS has no `BGTaskScheduler`. What it has is
/// `NSBackgroundActivityScheduler`, which runs repeating work while the process
/// is alive and lets the system pick the energy-cheap moment. The cadence and
/// the "is this wake worth spending requests on" decision stay pure and tested
/// — `BackgroundRefreshPolicy` in the kit, restated for this scheduler by
/// `MacRefreshSchedule` below. Everything in this class is the part only the
/// scheduler can exercise: registration, the deferral handshake, and the hop
/// onto the main actor.
///
/// Every request a wake spends goes through
/// `AppModel.performBackgroundRefresh`, hence through the model's own
/// `RateLimitGovernor` and into `SharedSnapshotStore` — the same single
/// coalesced fetch as iOS, one dashboard read feeding every ambient surface.
/// Nothing here fetches, decides what to fetch, or writes a file itself.
@MainActor
final class MacBackgroundRefresh {

    /// The app-wide instance. `GetHogMacApp` starts it once the model has
    /// bootstrapped (wired in the Wave 4 sweep); nothing else constructs one.
    static let shared = MacBackgroundRefresh()

    /// One name for the activity, mirroring the iOS task identifier so the two
    /// schedulers read as the same feature in logs and tests.
    static let activityIdentifier = "app.gethog.refresh.snapshot"

    private static let log = Logger(subsystem: "app.gethog", category: "background-refresh")

    private var scheduler: NSBackgroundActivityScheduler?

    /// Whether an activity is currently registered. The Settings consumption
    /// meter and the menu bar extra (Task 10) both want to state this.
    var isActive: Bool { scheduler != nil }

    /// Registers the repeating activity. Idempotent: a second `start` while one
    /// is registered changes nothing, so callers may re-run it on scene or
    /// credential changes without bookkeeping.
    func start(model: AppModel) {
        guard scheduler == nil else { return }

        let activity = NSBackgroundActivityScheduler(identifier: Self.activityIdentifier)
        activity.repeats = true
        activity.interval = MacRefreshSchedule.interval
        // The scheduler's tolerance and the policy's due tolerance are the same
        // number on purpose: any wake the system may legally deliver early is a
        // wake `BackgroundRefreshPolicy.isDue` will still count as due, so no
        // granted opportunity is ever turned away over minutes of purity.
        activity.tolerance = MacRefreshSchedule.tolerance
        // Unattended maintenance, not user-initiated work.
        activity.qualityOfService = .utility

        // The block runs on the scheduler's own serial queue. `shouldDefer` is
        // defined to be read exactly there, and the completion handler tolerates
        // exactly one call — kept on the single path through the switch below.
        let handle = UncheckedSendable(activity)
        activity.schedule { completion in
            let systemWantsDeferral = handle.value.shouldDefer
            let finish = UncheckedSendable(completion)
            Task { @MainActor in
                switch MacRefreshSchedule.action(
                    hasCredential: model.hasStoredCredential,
                    systemWantsDeferral: systemWantsDeferral,
                    lastRefreshedAt: model.lastSnapshotDate,
                    now: Date()
                ) {
                case .deferred:
                    finish.value(.deferred)
                case .standDown:
                    finish.value(.finished)
                case .refresh:
                    let refreshed = await model.performBackgroundRefresh()
                    if !refreshed {
                        // Expected offline or with a rejected key; the app
                        // refreshes in the foreground either way.
                        Self.log.notice("A background refresh wake could not fetch.")
                    }
                    finish.value(.finished)
                }
            }
        }
        scheduler = activity
    }

    /// Invalidates the activity. Sign-out calls this — an unattended fetch
    /// with no credential can only fail, and `MacRefreshSchedule` standing
    /// every wake down would still leave a pointless registration behind.
    func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }
}

/// The schedule decision, pure and apart from the scheduler that acts on it.
///
/// Restates `BackgroundRefreshPolicy` in the vocabulary
/// `NSBackgroundActivityScheduler` speaks — one function from facts to an
/// action, so the cadence is testable without registering an activity, exactly
/// as the iOS cadence is testable without a `BGTaskScheduler`.
enum MacRefreshSchedule {

    /// The floor between two unattended refreshes — the kit's number, resold
    /// under the name the scheduler configuration reads.
    static var interval: TimeInterval { BackgroundRefreshPolicy.minimumInterval }

    /// How far the system may move a wake, matched to how early a wake may
    /// arrive and still count as due.
    static var tolerance: TimeInterval { BackgroundRefreshPolicy.dueTolerance }

    /// What one wake should do.
    enum Action: Equatable {
        /// Spend the coalesced requests and complete `.finished`.
        case refresh
        /// Complete `.deferred`; the system re-offers the wake soon.
        case deferred
        /// Complete `.finished` without spending anything.
        case standDown
    }

    /// No credential outranks deferral — a wake that can only fail should not
    /// be re-offered — and deferral outranks staleness, because a deferred
    /// wake returns in minutes where a spent one returns in hours.
    static func action(
        hasCredential: Bool,
        systemWantsDeferral: Bool,
        lastRefreshedAt: Date?,
        now: Date
    ) -> Action {
        guard BackgroundRefreshPolicy.shouldSchedule(hasCredential: hasCredential) else {
            return .standDown
        }
        if systemWantsDeferral { return .deferred }
        guard BackgroundRefreshPolicy.isDue(lastRefreshedAt: lastRefreshedAt, now: now) else {
            return .standDown
        }
        return .refresh
    }
}

/// A value the compiler cannot prove is safe to move between isolation
/// domains, vouched for at the one call site that knows it is. The same shape
/// the iOS `BackgroundRefresh` declares privately for `BGTask`; that file is
/// excluded from this target, so the twin carries its own copy.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) { self.value = value }
}
