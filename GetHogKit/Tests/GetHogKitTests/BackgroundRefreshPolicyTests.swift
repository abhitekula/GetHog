import Foundation
import Testing

@testable import GetHogKit

/// The policy is a pure function of an instant and the last refresh, so these
/// tests never involve `BGTaskScheduler`, a network, or a clock.
@Suite("Background refresh policy")
struct BackgroundRefreshPolicyTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("does not schedule anything without a stored credential")
    func noCredentialMeansNoSchedule() {
        // A background wake with no key can only fail. Scheduling one anyway
        // spends the system's wake budget and teaches iOS that this app's
        // requests are worthless.
        #expect(BackgroundRefreshPolicy.shouldSchedule(hasCredential: false) == false)
        #expect(BackgroundRefreshPolicy.shouldSchedule(hasCredential: true))
    }

    @Test("never asks to run sooner than one full interval after the last refresh")
    func earliestBeginRespectsInterval() {
        let last = t0
        let soonAfter = t0.addingTimeInterval(10 * 60)

        let earliest = BackgroundRefreshPolicy.earliestBeginDate(lastRefreshedAt: last, now: soonAfter)

        #expect(earliest == last.addingTimeInterval(BackgroundRefreshPolicy.minimumInterval))
        #expect(earliest > soonAfter)
    }

    @Test("does not ask to run in the past when the last refresh is already old")
    func earliestBeginNeverTrailsNow() {
        let last = t0
        let muchLater = t0.addingTimeInterval(BackgroundRefreshPolicy.minimumInterval * 5)

        let earliest = BackgroundRefreshPolicy.earliestBeginDate(lastRefreshedAt: last, now: muchLater)

        #expect(earliest == muchLater)
    }

    @Test("waits a full interval when nothing has ever been refreshed")
    func earliestBeginWithoutHistory() {
        // Conservative on purpose: the budget being spent is the user's
        // organisation-wide one, so an unknown history buys no urgency.
        let earliest = BackgroundRefreshPolicy.earliestBeginDate(lastRefreshedAt: nil, now: t0)

        #expect(earliest == t0.addingTimeInterval(BackgroundRefreshPolicy.minimumInterval))
    }

    @Test("a wake that lands soon after a foreground sync does no work")
    func coalescesWithRecentForegroundRefresh() {
        let last = t0
        let wake = t0.addingTimeInterval(5 * 60)

        #expect(BackgroundRefreshPolicy.isDue(lastRefreshedAt: last, now: wake) == false)
    }

    @Test("a wake is due once the interval has elapsed")
    func dueAfterInterval() {
        let last = t0
        let wake = t0.addingTimeInterval(BackgroundRefreshPolicy.minimumInterval)

        #expect(BackgroundRefreshPolicy.isDue(lastRefreshedAt: last, now: wake))
    }

    @Test("a wake fired slightly early is still due")
    func toleratesAnEarlyWake() {
        // iOS treats `earliestBeginDate` as a hint and can fire either side of
        // it. Refusing a wake that arrived a minute early would throw away the
        // whole opportunity and leave the snapshot stale for another interval.
        let wake = t0.addingTimeInterval(BackgroundRefreshPolicy.minimumInterval - 60)

        #expect(BackgroundRefreshPolicy.isDue(lastRefreshedAt: t0, now: wake))
    }

    @Test("a wake with no prior refresh is always due")
    func dueWithoutHistory() {
        #expect(BackgroundRefreshPolicy.isDue(lastRefreshedAt: nil, now: t0))
    }

    @Test("the whole day of background refreshes stays a rounding error on the budget")
    func dailyCostIsNegligible() {
        // Rate limits are organisation-wide and shared with the user's own
        // integrations, so the ceiling that matters is theirs, not ours.
        //
        // The bound is stated as a *share of what PostHog allows in one hour*
        // rather than as a bare number, because the bare number has to move when
        // a section is added and a number nobody can derive moves without
        // argument. Two per cent is the line: a whole day of traffic from a
        // process the user never launched must cost less than a fiftieth of a
        // single hour's allowance, so it can never be the reason one of their
        // own integrations is throttled.
        let perDay = BackgroundRefreshPolicy.maximumRequestsPerDay

        #expect(perDay < RateLimitGovernor.defaultBudgets[.crud]!.perHour! / 50)
    }

    @Test("the sections that move slowly are not paid for on every wake")
    func slowSectionsAreNotPaidPerWake() {
        // Quota is a monthly allowance. Fetching it on every two-hourly wake
        // would spend twelve requests a day to watch a number that changes on a
        // monthly clock; it is fetched twice and carried forward in between,
        // with its own age attached so nothing presents it as current.
        #expect(BackgroundRefreshPolicy.quotaRequestsPerDay < BackgroundRefreshPolicy.refreshesPerDay)
        #expect(SharedSnapshot.QuotaDigest.refreshInterval > BackgroundRefreshPolicy.minimumInterval)
    }

    @Test("the interval is not shorter than the widget timeline it feeds")
    func cadenceMatchesWhatTheDataCanDo() {
        // A widget's own timeline already re-renders hourly from the cached
        // snapshot. Refreshing more often than that spends requests to produce
        // numbers nothing will draw before they are replaced.
        #expect(BackgroundRefreshPolicy.minimumInterval >= 3_600)
    }
}
