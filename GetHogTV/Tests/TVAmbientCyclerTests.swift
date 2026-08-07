import Foundation
import GetHogKit
import SwiftUI
import Testing
@testable import GetHog

/// Pins the wallboard's cycling.
///
/// Written against the cycler rather than the view for a reason the interval
/// itself gives: a test that drove the real screen would have to wait twelve
/// seconds per advance to observe anything. Everything that decides *which*
/// metric is on screen lives here, so all of it can be checked in a
/// millisecond.
@Suite("TV ambient cycler")
@MainActor
struct TVAmbientCyclerTests {

    private static func metric(_ id: String) -> SharedSnapshot.Metric {
        SharedSnapshot.Metric(
            id: id,
            title: "Metric \(id)",
            value: 1,
            unit: nil,
            previous: nil,
            sparkline: [],
            dashboardID: 7
        )
    }

    private static func cycler(count: Int) -> TVAmbientCycler {
        TVAmbientCycler(metrics: (0..<count).map { metric(String($0)) })
    }

    @Test("advancing past the last metric returns to the first")
    func advanceWraps() {
        let cycler = Self.cycler(count: 3)
        cycler.advance()
        #expect(cycler.index == 1)
        cycler.advance()
        #expect(cycler.index == 2)
        // The wrap is the whole point: a wallboard that stopped on the last
        // tile would show one number until somebody walked over to it.
        cycler.advance()
        #expect(cycler.index == 0)
    }

    @Test("skipping back from the first metric lands on the last")
    func skipLeftWrapsBackwards() {
        let cycler = Self.cycler(count: 4)
        cycler.skip(.left)
        // Not clamped at zero, and not a negative index: a ring has no end to
        // stop at, and `(0 - 1) % 4` in Swift is -1, which would crash the
        // subscript below it.
        #expect(cycler.index == 3)
        #expect(cycler.current?.id == "3")
    }

    @Test("skipping forward is the same step advancing takes")
    func skipRightMatchesAdvance() {
        let skipped = Self.cycler(count: 3)
        let advanced = Self.cycler(count: 3)
        skipped.skip(.right)
        advanced.advance()
        #expect(skipped.index == advanced.index)
    }

    @Test("up and down are not cycle commands")
    func verticalMovesAreIgnored() {
        // The remote's vertical axis belongs to whatever focus does with it.
        // Treating it as a skip would make the wallboard jump under a thumb
        // that was only resting on the pad.
        let cycler = Self.cycler(count: 3)
        cycler.skip(.up)
        cycler.skip(.down)
        #expect(cycler.index == 0)
    }

    @Test("an empty snapshot vends no metric and cannot be advanced past zero")
    func emptyMetricsAreInert() {
        let cycler = TVAmbientCycler(metrics: [])
        #expect(cycler.isEmpty)
        #expect(cycler.current == nil)
        // Both of these would divide by zero or index an empty array if they
        // did not guard; the screen renders its "nothing pinned" state instead.
        cycler.advance()
        cycler.skip(.left)
        #expect(cycler.index == 0)
        #expect(cycler.current == nil)
    }

    @Test("a snapshot that dropped the metric being shown falls back to the start")
    func replaceFallsBackWhenTheReadMetricIsGone() {
        let cycler = Self.cycler(count: 5)
        cycler.advance()
        cycler.advance()
        cycler.advance()
        #expect(cycler.index == 3)
        // A dashboard that lost tiles between snapshots would otherwise leave
        // the index pointing past the end until the next tick.
        cycler.replace(metrics: [Self.metric("only")])
        #expect(cycler.index == 0)
        #expect(cycler.current?.id == "only")
    }

    @Test("an unchanged snapshot is not adopted, so the cycle keeps its place")
    func replaceIsANoOpWhenNothingChanged() {
        // **This is what makes re-reading on every tick safe.** The wallboard
        // re-reads the snapshot each cycle so it cannot sit on day-old numbers,
        // and if that read reset the index the screen would show metric one
        // forever, twelve seconds at a time.
        let cycler = Self.cycler(count: 4)
        cycler.advance()
        cycler.advance()
        #expect(cycler.index == 2)

        let same = (0..<4).map { Self.metric(String($0)) }
        #expect(cycler.replace(metrics: same) == false)
        #expect(cycler.index == 2)
        #expect(cycler.current?.id == "2")
    }

    @Test("a metric whose value moved is adopted even though its title did not")
    func replaceAdoptsChangedValues() {
        // Equality is the whole list, values included. Comparing ids or titles
        // alone would make the wallboard blind to the only thing it exists to
        // show: the number changing.
        let cycler = TVAmbientCycler(metrics: [Self.metric("a")])
        let moved = SharedSnapshot.Metric(
            id: "a", title: "Metric a", value: 99, unit: nil,
            previous: nil, sparkline: [], dashboardID: 7
        )
        #expect(cycler.replace(metrics: [moved]))
        #expect(cycler.current?.value == 99)
    }

    @Test("a refreshed snapshot holds the reader on the metric they were reading")
    func replaceHoldsPositionByIdentity() {
        // Held by identity, not by index: a snapshot that gained a tile at the
        // front would otherwise jump the screen to a different metric in the
        // middle of somebody reading it.
        let cycler = Self.cycler(count: 3)
        cycler.advance()
        #expect(cycler.current?.id == "1")

        let grown = [Self.metric("new")] + (0..<3).map { Self.metric(String($0)) }
        #expect(cycler.replace(metrics: grown))
        #expect(cycler.current?.id == "1")
        #expect(cycler.index == 2)
    }

    @Test("the cycle interval is the documented cadence")
    func intervalIsTwelveSeconds() {
        // Not a restatement of the constant against itself: this asserts the
        // *duration it amounts to*, which is what the screen's tick sleeps for
        // and what the ambient screenshot's 15-second wait is sized against.
        #expect(TVAmbientCycler.interval == .seconds(12))
        #expect(TVAmbientCycler.interval < .seconds(30))
    }

    @Test("leaving Ambient invalidates its retained tick task")
    func leavingInvalidatesTickTask() {
        let presented = TVAmbientCycleTaskID(clock: 3, isHeld: true)
        let left = TVAmbientCycleTaskID(clock: 3, isHeld: false)

        #expect(presented != left)
        #expect(presented.shouldRun)
        #expect(!left.shouldRun)
    }

    @Test("a manual skip restarts only a presented Ambient tick task")
    func manualSkipChangesPresentedTaskIdentity() {
        let before = TVAmbientCycleTaskID(clock: 3, isHeld: true)
        let after = TVAmbientCycleTaskID(clock: 4, isHeld: true)

        #expect(before != after)
        #expect(after.shouldRun)
    }

    @Test("an inactive scene invalidates Ambient even while its tab is retained")
    func inactivePresentedSceneCannotTick() {
        var awake = TVScreenAwake()
        awake.present()
        let active = TVAmbientCycleTaskID(clock: 3, isHeld: awake.isHeld)

        awake.sceneBecame(active: false)
        let inactive = TVAmbientCycleTaskID(clock: 3, isHeld: awake.isHeld)

        #expect(active.shouldRun)
        #expect(active != inactive)
        #expect(!inactive.shouldRun)
    }

    // MARK: - Keeping the screen awake

    /// The never-sleeping-TV failure mode, as transitions rather than as three
    /// callbacks nobody can drive.
    @Suite("TV screen awake hold")
    struct TVScreenAwakeTests {

        @Test("nothing is held before the wallboard is entered")
        func startsReleased() {
            #expect(!TVScreenAwake().isHeld)
        }

        @Test("entering the wallboard holds the screen")
        func presentHolds() {
            var awake = TVScreenAwake()
            awake.present()
            #expect(awake.isHeld)
        }

        @Test("leaving releases, and a tab kept alive behind the sidebar cannot re-take it")
        func leaveReleases() {
            // This is the bug. The release used to hang entirely on
            // `onDisappear`, and a `TabView` may keep a tab's content alive
            // across a sidebar switch — in which case the tick loop went on
            // re-asserting from a tab nobody was watching, forever.
            var awake = TVScreenAwake()
            awake.present()
            awake.leave()
            #expect(!awake.isHeld)
        }

        @Test("a backgrounded scene releases the hold")
        func inactiveSceneReleases() {
            var awake = TVScreenAwake()
            awake.present()
            awake.sceneBecame(active: false)
            #expect(!awake.isHeld)
        }

        @Test("coming back to an app the viewer never left resumes the hold")
        func returningResumesWhilePresented() {
            var awake = TVScreenAwake()
            awake.present()
            awake.sceneBecame(active: false)
            awake.sceneBecame(active: true)
            #expect(awake.isHeld)
        }

        @Test("coming back does NOT resume a hold the viewer had already left")
        func returningDoesNotResurrectALeftScreen() {
            // Leaving is sticky for exactly this: a wallboard exited to the
            // sidebar, then the app backgrounded and foregrounded, must not
            // silently start holding the screen awake again from a tab nobody
            // is looking at. A single `isSceneActive` boolean would.
            var awake = TVScreenAwake()
            awake.present()
            awake.leave()
            awake.sceneBecame(active: false)
            awake.sceneBecame(active: true)
            #expect(!awake.isHeld)
        }

        @Test("re-entering after leaving holds again")
        func reentryHolds() {
            var awake = TVScreenAwake()
            awake.present()
            awake.leave()
            awake.present()
            #expect(awake.isHeld)
        }
    }

    // MARK: - Wording

    @Test("a metric with no comparison period claims no movement")
    func absentPreviousMeansNoDelta() {
        // `previous` documents nil as "not known", which is not "no change" —
        // the wallboard must not draw an arrow for a number it never compared.
        #expect(TVAmbientView.deltaPhrase(Self.metric("a")) == nil)
    }

    @Test("a fall is spoken as a fall, with the magnitude it actually was")
    func downwardDeltaReads() {
        let metric = SharedSnapshot.Metric(
            id: "a", title: "Signups", value: 750, unit: nil,
            previous: 1_000, sparkline: [], dashboardID: 1
        )
        #expect(TVAmbientView.deltaPhrase(metric) == "Down 25%")
        #expect(TVAmbientView.spoken(metric).contains("Signups"))
        #expect(TVAmbientView.spoken(metric).contains("Down 25%"))
    }

    @Test("a unit rides with the headline rather than being dropped")
    func unitJoinsTheHeadline() {
        let metric = SharedSnapshot.Metric(
            id: "a", title: "Top page", value: 4_200, unit: "/pricing",
            previous: nil, sparkline: [], dashboardID: 1
        )
        // A bar-value tile's unit is the label of the bar it came from. A
        // headline of "4.2K" with the label thrown away is a number about
        // nothing.
        #expect(TVAmbientView.headline(metric).contains("/pricing"))
    }
}

/// Pins the extra gate the TV shell puts in front of `AppModel`'s shared
/// background-refresh path. Ambient ticks every twelve seconds, but a failed
/// request must not turn that display cadence into an API retry cadence.
@Suite("TV snapshot refresh coordinator")
@MainActor
struct TVSnapshotRefreshCoordinatorTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("the API floor is the shared unattended-refresh policy")
    func floorUsesSharedPolicy() {
        #expect(
            TVSnapshotRefreshCoordinator.minimumInterval
                == BackgroundRefreshPolicy.minimumInterval
        )
    }

    @Test("a TV with no previous refresh attempts immediately")
    func firstAttemptIsDue() async {
        let coordinator = TVSnapshotRefreshCoordinator()
        var calls = 0

        let result = await coordinator.refreshIfDue(now: now, lastSnapshotAt: nil) {
            calls += 1
            return true
        }

        #expect(result == .refreshed)
        #expect(calls == 1)
        #expect(coordinator.lastAttemptAt == now)
    }

    @Test("a recent snapshot keeps foreground and Ambient triggers below the floor")
    func recentSnapshotIsNotDue() async {
        let coordinator = TVSnapshotRefreshCoordinator()
        var calls = 0

        let result = await coordinator.refreshIfDue(
            now: now,
            lastSnapshotAt: now.addingTimeInterval(-TVSnapshotRefreshCoordinator.minimumInterval + 1)
        ) {
            calls += 1
            return true
        }

        #expect(result == .notDue)
        #expect(calls == 0)
    }

    @Test("a failed attempt is not retried on the next Ambient cycle")
    func failedAttemptStillStartsTheFloor() async {
        let coordinator = TVSnapshotRefreshCoordinator()
        var calls = 0
        let failed = await coordinator.refreshIfDue(now: now, lastSnapshotAt: nil) {
            calls += 1
            return false
        }
        let nextCycle = await coordinator.refreshIfDue(
            now: now.addingTimeInterval(12),
            lastSnapshotAt: nil
        ) {
            calls += 1
            return true
        }

        #expect(failed == .attempted)
        #expect(nextCycle == .notDue)
        #expect(calls == 1)
    }

    @Test("an Ambient trigger starts API work without waiting for it")
    func detachedTriggerDoesNotBlockVisualCadence() async {
        let coordinator = TVSnapshotRefreshCoordinator()

        let result = coordinator.startIfDue(now: now, lastSnapshotAt: nil) {
            while !Task.isCancelled { await Task.yield() }
            return false
        }

        #expect(result == .started)
        #expect(coordinator.isRefreshing)
        coordinator.cancel()
        while coordinator.isRefreshing { await Task.yield() }
    }

    @Test("the exact shared policy interval opens the gate again")
    func exactFloorIsDue() async {
        let coordinator = TVSnapshotRefreshCoordinator()
        _ = await coordinator.refreshIfDue(now: now, lastSnapshotAt: nil) { false }

        let result = await coordinator.refreshIfDue(
            now: now.addingTimeInterval(TVSnapshotRefreshCoordinator.minimumInterval),
            lastSnapshotAt: nil
        ) { true }

        #expect(result == .refreshed)
    }

    @Test("a second trigger coalesces while the first request is in flight")
    func concurrentTriggersCoalesce() async {
        let coordinator = TVSnapshotRefreshCoordinator()
        let first = Task {
            await coordinator.refreshIfDue(now: now, lastSnapshotAt: nil) {
                while !Task.isCancelled { await Task.yield() }
                return false
            }
        }
        while !coordinator.isRefreshing { await Task.yield() }

        var secondCalls = 0
        let second = await coordinator.refreshIfDue(
            now: now.addingTimeInterval(TVSnapshotRefreshCoordinator.minimumInterval),
            lastSnapshotAt: nil
        ) {
            secondCalls += 1
            return true
        }

        #expect(second == .inFlight)
        #expect(secondCalls == 0)
        coordinator.cancel()
        _ = await first.value
    }

    @Test("leaving the active scene cancels the operation and permits a later retry")
    func cancellationEndsLifecycle() async {
        let coordinator = TVSnapshotRefreshCoordinator()
        let first = Task {
            await coordinator.refreshIfDue(now: now, lastSnapshotAt: nil) {
                while !Task.isCancelled { await Task.yield() }
                return false
            }
        }
        while !coordinator.isRefreshing { await Task.yield() }

        coordinator.cancel(resetAttempt: true)
        let cancelled = await first.value
        let replacement = await coordinator.refreshIfDue(
            now: now.addingTimeInterval(1),
            lastSnapshotAt: nil
        ) { true }

        #expect(cancelled == .cancelled)
        #expect(replacement == .refreshed)
        #expect(!coordinator.isRefreshing)
    }

    @Test("cancelling an outer waiter cannot cancel its replacement generation")
    func outerCancellationDoesNotKillReplacement() async {
        let coordinator = TVSnapshotRefreshCoordinator()
        let first = Task {
            await coordinator.refreshIfDue(now: now, lastSnapshotAt: nil) {
                while !Task.isCancelled { await Task.yield() }
                return false
            }
        }
        while !coordinator.isRefreshing { await Task.yield() }

        // This is the exact race the old cancellation handler lost: it queued
        // an actor hop that called the coordinator's unconditional `cancel()`.
        // A replacement could start before that hop ran, then the stale hop
        // cancelled the replacement instead of the child it belonged to.
        first.cancel()
        coordinator.cancel(resetAttempt: true)
        let replacement = coordinator.startIfDue(
            now: now.addingTimeInterval(1),
            lastSnapshotAt: nil
        ) {
            while !Task.isCancelled { await Task.yield() }
            return true
        }
        #expect(replacement == .started)
        for _ in 0..<100 { await Task.yield() }

        #expect(coordinator.isRefreshing)
        coordinator.cancel()
        #expect(await first.value == .cancelled)
    }
}
