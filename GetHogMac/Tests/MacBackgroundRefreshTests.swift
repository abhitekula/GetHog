import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// The Mac refresh cadence, decided without a scheduler in the room.
///
/// `MacBackgroundRefresh` itself is deliberately absent here:
/// `NSBackgroundActivityScheduler` registers real activities with a system
/// daemon this process does not own, and a test that scheduled one would leave
/// that registration behind. Everything the scheduler would ask is a pure
/// function in `MacRefreshSchedule`, so the cadence is pinned the way
/// `BackgroundRefreshPolicy`'s is in the kit.
///
/// The class's registration bookkeeping is exercised in
/// `MacBackgroundRefreshRegistrationTests` below, through a factory seam that
/// never hands an activity to the daemon. The rule above is unchanged: no real
/// scheduler is ever scheduled from a test.
@Suite("Mac refresh schedule")
@MainActor
struct MacRefreshScheduleTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("the activity mirrors the iOS task identifier")
    func identifier() {
        #expect(MacBackgroundRefresh.activityIdentifier == "app.gethog.refresh.snapshot")
    }

    @Test("the interval is the policy's floor between unattended refreshes")
    func intervalMirrorsPolicy() {
        #expect(MacRefreshSchedule.interval == BackgroundRefreshPolicy.minimumInterval)
        // Pinned as a number too, so a kit-side change to the budget shows up
        // here as a decision rather than passing silently through the mirror.
        #expect(MacRefreshSchedule.interval == 2 * 60 * 60)
    }

    @Test("the tolerance is the policy's due tolerance")
    func toleranceMirrorsPolicy() {
        #expect(MacRefreshSchedule.tolerance == BackgroundRefreshPolicy.dueTolerance)
        #expect(MacRefreshSchedule.tolerance == 5 * 60)
    }

    @Test("no credential stands the wake down, whatever else is true")
    func noCredentialStandsDown() {
        let stale = now.addingTimeInterval(-MacRefreshSchedule.interval * 3)
        #expect(MacRefreshSchedule.action(
            hasCredential: false, systemWantsDeferral: false, lastRefreshedAt: stale, now: now
        ) == .standDown)
        #expect(MacRefreshSchedule.action(
            hasCredential: false, systemWantsDeferral: true, lastRefreshedAt: nil, now: now
        ) == .standDown)
    }

    @Test("system deferral postpones even a due wake")
    func deferralPostponesADueWake() {
        let stale = now.addingTimeInterval(-MacRefreshSchedule.interval * 3)
        #expect(MacRefreshSchedule.action(
            hasCredential: true, systemWantsDeferral: true, lastRefreshedAt: stale, now: now
        ) == .deferred)
    }

    @Test("a fresh snapshot spends nothing")
    func freshSnapshotStandsDown() {
        let recent = now.addingTimeInterval(-60)
        #expect(MacRefreshSchedule.action(
            hasCredential: true, systemWantsDeferral: false, lastRefreshedAt: recent, now: now
        ) == .standDown)
    }

    @Test("no snapshot at all is due immediately")
    func missingSnapshotRefreshes() {
        #expect(MacRefreshSchedule.action(
            hasCredential: true, systemWantsDeferral: false, lastRefreshedAt: nil, now: now
        ) == .refresh)
    }

    @Test("a stale snapshot refreshes")
    func staleSnapshotRefreshes() {
        let stale = now.addingTimeInterval(-MacRefreshSchedule.interval * 3)
        #expect(MacRefreshSchedule.action(
            hasCredential: true, systemWantsDeferral: false, lastRefreshedAt: stale, now: now
        ) == .refresh)
    }

    @Test("a wake arriving inside the early tolerance still counts as due")
    func justInsideToleranceRefreshes() {
        let last = now.addingTimeInterval(-(MacRefreshSchedule.interval - MacRefreshSchedule.tolerance))
        #expect(MacRefreshSchedule.action(
            hasCredential: true, systemWantsDeferral: false, lastRefreshedAt: last, now: now
        ) == .refresh)
    }

    @Test("a wake earlier than the tolerance allows stands down")
    func justOutsideToleranceStandsDown() {
        let last = now.addingTimeInterval(-(MacRefreshSchedule.interval - MacRefreshSchedule.tolerance) + 1)
        #expect(MacRefreshSchedule.action(
            hasCredential: true, systemWantsDeferral: false, lastRefreshedAt: last, now: now
        ) == .standDown)
    }
}

// MARK: - Why the wake itself is not driven here
//
// `BackgroundRefreshTests` on iOS drives `performBackgroundRefresh` end to end
// and reads the published snapshot back out of the App Group. The twin of that
// suite was written for this target and then removed, because in a Mac *Debug*
// test host it cannot measure what it claims to — for reasons that are a fact
// about the platform rather than about the refresh path:
//
//   1. `GetHogMac.entitlements` (Debug) deliberately carries no App Group. That
//      subtraction is what lets a fresh clone with no development certificate
//      build and run at all — project.yml and the entitlements file each
//      explain it at length.
//   2. On macOS `containerURL(forSecurityApplicationGroupIdentifier:)` still
//      hands back a *path* without the entitlement, where on iOS it returns
//      nil. So `SharedSnapshotStore.resolve()` takes its `isSharedContainer:
//      true` branch and points at `~/Library/Group Containers/group.app.gethog`
//      — a directory the sandbox will not let this process create. (Measured:
//      it does not exist, and every group container that does on a Mac carries
//      the Team ID prefix the kit documents.)
//   3. `AppModel.publish` writes with `try?`. A denied write is therefore
//      silent, and every read afterwards is `nil`.
//
// So such a suite fails on the container, never reaching the behaviour under
// test, and the only ways to make it pass are to grant Debug an entitlement
// that breaks the fresh-clone build or to weaken it into asserting something
// it does not mean. `AppModel.publish` hardcodes `SharedSnapshotStore.shared`,
// so there is no seam to point it at a writable directory either.
//
// The wake path is shared code fully covered by `BackgroundRefreshTests`; what
// is Mac-specific is the cadence, and that is entirely above. The Wave 5
// migration to `appGroupIdentifier(teamIDPrefix:)` is what makes a Mac
// snapshot cross a process boundary — and what makes this suite worth
// restoring.

/// Registration bookkeeping, which is everything `MacBackgroundRefresh` does
/// that `MacRefreshSchedule` does not decide.
///
/// The suite above states why a real `NSBackgroundActivityScheduler` cannot
/// appear in a test: creating one is harmless, but `schedule` hands a live
/// activity to a system daemon under the app's own identifier. The factory
/// seam is what separates those two facts — the class still makes a real
/// scheduler in the app, and here it makes a counting stub that never
/// schedules, so start/stop/restart can be observed without registering
/// anything.
///
/// This is the part that was entirely unexercised while the class had no call
/// sites at all: `start` is documented as idempotent so callers may re-run it
/// on scene changes without bookkeeping, and `GetHogMacApp` now does exactly
/// that on every `.active`. If idempotence ever broke, the app would register
/// a second activity for every window activation.
@Suite("Mac background refresh registration")
@MainActor
struct MacBackgroundRefreshRegistrationTests {

    /// Never scheduled, only counted. Overriding `schedule` is what keeps the
    /// system daemon out of this: the superclass method is the one that
    /// registers.
    private final class StubScheduler: NSBackgroundActivityScheduler {
        var invalidations = 0

        override func schedule(
            _ block: @escaping (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void
        ) {}

        override func invalidate() { invalidations += 1 }
    }

    private final class Factory {
        private(set) var made: [StubScheduler] = []

        func make(identifier: String) -> NSBackgroundActivityScheduler {
            let scheduler = StubScheduler(identifier: identifier)
            made.append(scheduler)
            return scheduler
        }
    }

    private func makeModel() -> AppModel {
        AppModel(store: InMemoryTokenStore(), transport: URLSessionTransport())
    }

    @Test("nothing is registered until something starts it")
    func inertBeforeStart() {
        let factory = Factory()
        let refresh = MacBackgroundRefresh(makeScheduler: factory.make)

        #expect(refresh.isActive == false)
        #expect(factory.made.isEmpty)
    }

    @Test("start registers exactly one activity, under the shared identifier")
    func startRegistersOnce() {
        let factory = Factory()
        let refresh = MacBackgroundRefresh(makeScheduler: factory.make)

        refresh.start(model: makeModel())

        #expect(refresh.isActive)
        #expect(factory.made.count == 1)
        #expect(factory.made.first?.identifier == MacBackgroundRefresh.activityIdentifier)
    }

    /// The property the doc comment promises and the app now leans on: the
    /// scene going active re-runs `start` every time.
    @Test("a second start while one is registered changes nothing")
    func startIsIdempotent() {
        let factory = Factory()
        let refresh = MacBackgroundRefresh(makeScheduler: factory.make)
        let model = makeModel()

        refresh.start(model: model)
        refresh.start(model: model)
        refresh.start(model: model)

        #expect(factory.made.count == 1)
        #expect(refresh.isActive)
    }

    @Test("stop invalidates the activity and forgets it")
    func stopInvalidates() {
        let factory = Factory()
        let refresh = MacBackgroundRefresh(makeScheduler: factory.make)

        refresh.start(model: makeModel())
        refresh.stop()

        #expect(refresh.isActive == false)
        #expect(factory.made.first?.invalidations == 1)
    }

    /// Sign-out stops the clock; a sign-in in the same session has to be able
    /// to start it again, which only holds if `stop` really cleared the slot
    /// rather than just invalidating what was in it.
    @Test("starting again after a stop registers a fresh activity")
    func restartRegistersAgain() {
        let factory = Factory()
        let refresh = MacBackgroundRefresh(makeScheduler: factory.make)
        let model = makeModel()

        refresh.start(model: model)
        refresh.stop()
        refresh.start(model: model)

        #expect(factory.made.count == 2)
        #expect(refresh.isActive)
    }

    @Test("stop on something never started is harmless")
    func stopWithoutStart() {
        let factory = Factory()
        let refresh = MacBackgroundRefresh(makeScheduler: factory.make)

        refresh.stop()

        #expect(refresh.isActive == false)
        #expect(factory.made.isEmpty)
    }
}
