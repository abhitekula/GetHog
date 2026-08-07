import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

/// The wrist's unattended cadence, decided without a scheduler in the room.
///
/// `WatchRefresh` itself is deliberately absent: it calls
/// `WKApplication.scheduleBackgroundRefresh`, which registers a real request
/// with the system for the app this test bundle is hosted in, and a test that
/// scheduled one would leave it behind. Everything the scheduler would ask is a
/// pure function in `WatchRefreshSchedule`, so the cadence is pinned the way
/// `BackgroundRefreshPolicy`'s is in the kit and `MacRefreshSchedule`'s is on
/// the Mac.
@Suite("Watch refresh schedule")
struct WatchRefreshScheduleTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Cadence

    @Test("the interval is the kit's floor between unattended refreshes")
    func intervalMirrorsPolicy() {
        #expect(WatchRefreshSchedule.interval == BackgroundRefreshPolicy.minimumInterval)
        // Pinned as a number too, so a kit-side change to the budget shows up
        // here as a decision rather than passing silently through the mirror.
        #expect(WatchRefreshSchedule.interval == 2 * 60 * 60)
    }

    @Test("the cadence sits well inside the wakes watchOS grants a live complication")
    func cadenceIsInsideTheSystemBudget() {
        // The honest arithmetic: watchOS grants roughly four wakes an hour to an
        // app with an active complication. Asking for one every two hours is
        // half a wake an hour — the governing constraint is the kit's
        // organisation-wide request budget, not the system's ceiling.
        let wakesPerHour = 3_600 / WatchRefreshSchedule.interval
        #expect(wakesPerHour <= Double(WatchRefreshSchedule.systemWakesPerHour))
        #expect(wakesPerHour == 0.5)
    }

    @Test("the invalidated relevance kind is the Smart Stack widget's own")
    func stackKindMatchesTheWidget() {
        // The widget lives in the extension binary, so the app cannot name its
        // `kind` symbolically. Pinned here because a typo would silently stop
        // the stack from re-asking `relevance()` after a breach flipped.
        #expect(WatchRefreshSchedule.stackWidgetKind == "app.gethog.watch.stack")
    }

    // MARK: Scheduling

    @Test("no credential stands the scheduler down, whatever else is true")
    func noCredentialStandsDown() {
        let stale = now.addingTimeInterval(-WatchRefreshSchedule.interval * 3)
        #expect(WatchRefreshSchedule.scheduleAction(
            hasCredential: false, pendingPreferredDate: nil, lastRefreshedAt: stale, now: now
        ) == .standDown)
        #expect(WatchRefreshSchedule.scheduleAction(
            hasCredential: false,
            pendingPreferredDate: now.addingTimeInterval(3_600),
            lastRefreshedAt: nil,
            now: now
        ) == .standDown)
    }

    @Test("a request still in the future is left alone rather than replaced")
    func futurePendingRequestIsNotReplaced() {
        // Scheduling a second request silently cancels the first, and WatchKit
        // offers no way to ask whether one is outstanding — so the stamp is the
        // only thing standing between this app and a wake it keeps cancelling.
        let stale = now.addingTimeInterval(-WatchRefreshSchedule.interval * 3)
        #expect(WatchRefreshSchedule.scheduleAction(
            hasCredential: true,
            pendingPreferredDate: now.addingTimeInterval(60),
            lastRefreshedAt: stale,
            now: now
        ) == .alreadyScheduled)
    }

    @Test("a stamp whose moment has passed does not block the next request")
    func pastPendingStampDoesNotBlock() {
        let action = WatchRefreshSchedule.scheduleAction(
            hasCredential: true,
            pendingPreferredDate: now.addingTimeInterval(-60),
            lastRefreshedAt: now,
            now: now
        )
        #expect(action == .schedule(
            preferredDate: now.addingTimeInterval(WatchRefreshSchedule.interval)
        ))
    }

    @Test("the preferred date is a full interval after the last refresh")
    func preferredDateFollowsTheLastRefresh() {
        let last = now.addingTimeInterval(-30 * 60)
        #expect(WatchRefreshSchedule.scheduleAction(
            hasCredential: true, pendingPreferredDate: nil, lastRefreshedAt: last, now: now
        ) == .schedule(
            preferredDate: last.addingTimeInterval(WatchRefreshSchedule.interval)
        ))
    }

    @Test("a long-stale snapshot asks for the first opportunity, never a date in the past")
    func staleHistoryAsksForNow() {
        let last = now.addingTimeInterval(-WatchRefreshSchedule.interval * 5)
        #expect(WatchRefreshSchedule.scheduleAction(
            hasCredential: true, pendingPreferredDate: nil, lastRefreshedAt: last, now: now
        ) == .schedule(preferredDate: now))
    }

    @Test("no history is treated as just-refreshed, not as overdue")
    func noHistorySchedulesFromNow() {
        // The budget being spent belongs to the user's organisation, so not
        // knowing buys no urgency — the kit's rule, restated here.
        #expect(WatchRefreshSchedule.scheduleAction(
            hasCredential: true, pendingPreferredDate: nil, lastRefreshedAt: nil, now: now
        ) == .schedule(
            preferredDate: now.addingTimeInterval(WatchRefreshSchedule.interval)
        ))
    }

    // MARK: The granted wake

    @Test("a wake with no credential spends nothing")
    func wakeWithoutCredentialStandsDown() {
        #expect(WatchRefreshSchedule.wakeAction(
            hasCredential: false, lastRefreshedAt: nil, now: now
        ) == .standDown)
    }

    @Test("a wake with nothing cached fetches")
    func wakeWithNoHistoryRefreshes() {
        #expect(WatchRefreshSchedule.wakeAction(
            hasCredential: true, lastRefreshedAt: nil, now: now
        ) == .refresh)
    }

    @Test("a wake minutes after a foreground refresh costs nothing")
    func freshSnapshotCoalescesTheWake() {
        #expect(WatchRefreshSchedule.wakeAction(
            hasCredential: true, lastRefreshedAt: now.addingTimeInterval(-5 * 60), now: now
        ) == .standDown)
    }

    @Test("a wake on a snapshot older than the interval fetches")
    func staleSnapshotRefreshes() {
        #expect(WatchRefreshSchedule.wakeAction(
            hasCredential: true,
            lastRefreshedAt: now.addingTimeInterval(-WatchRefreshSchedule.interval * 2),
            now: now
        ) == .refresh)
    }

    @Test("a wake granted marginally early still counts as due, on both sides of the edge")
    func toleranceEdges() {
        // `earliestBeginDate` is a floor the system may overshoot, but a launch
        // can land seconds before the interval has formally elapsed. Turning
        // that away wastes the whole opportunity — the next one is hours off.
        let tolerance = BackgroundRefreshPolicy.dueTolerance
        #expect(tolerance == 5 * 60)
        let justInside = now.addingTimeInterval(-(WatchRefreshSchedule.interval - tolerance))
        let justOutside = now.addingTimeInterval(-(WatchRefreshSchedule.interval - tolerance) + 1)
        #expect(WatchRefreshSchedule.wakeAction(
            hasCredential: true, lastRefreshedAt: justInside, now: now
        ) == .refresh)
        #expect(WatchRefreshSchedule.wakeAction(
            hasCredential: true, lastRefreshedAt: justOutside, now: now
        ) == .standDown)
    }
}
