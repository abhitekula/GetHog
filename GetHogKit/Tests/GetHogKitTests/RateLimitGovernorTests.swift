import Foundation
import Testing

@testable import GetHogKit

/// The governor is tested through `reserve(_:now:)`, which is a pure function of
/// state and a supplied instant. Tests therefore never sleep.
@Suite("Rate limit governor")
struct RateLimitGovernorTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("allows a burst up to the per-minute budget with no delay")
    func burstWithinBudget() async {
        let governor = RateLimitGovernor(
            budgets: [.analytics: RateLimitBudget(perMinute: 3, perHour: 100)]
        )

        for _ in 0..<3 {
            #expect(await governor.reserve(.analytics, now: t0) == 0)
        }
    }

    @Test("delays once the per-minute budget is exhausted")
    func delaysWhenExhausted() async {
        let governor = RateLimitGovernor(
            budgets: [.analytics: RateLimitBudget(perMinute: 2, perHour: 100)]
        )

        _ = await governor.reserve(.analytics, now: t0)
        _ = await governor.reserve(.analytics, now: t0)

        let delay = await governor.reserve(.analytics, now: t0)
        #expect(delay > 0)
        #expect(delay <= 60)
    }

    @Test("permits requests again once the window has advanced")
    func refillsOverTime() async {
        let governor = RateLimitGovernor(
            budgets: [.analytics: RateLimitBudget(perMinute: 2, perHour: 100)]
        )

        _ = await governor.reserve(.analytics, now: t0)
        _ = await governor.reserve(.analytics, now: t0)
        #expect(await governor.reserve(.analytics, now: t0) > 0)

        // A minute later the window has rolled over.
        #expect(await governor.reserve(.analytics, now: t0.addingTimeInterval(61)) == 0)
    }

    @Test("enforces the hourly budget even when the per-minute budget is free")
    func hourlyBudget() async {
        let governor = RateLimitGovernor(
            budgets: [.query: RateLimitBudget(perMinute: nil, perHour: 2)]
        )

        _ = await governor.reserve(.query, now: t0)
        _ = await governor.reserve(.query, now: t0.addingTimeInterval(120))

        let delay = await governor.reserve(.query, now: t0.addingTimeInterval(240))
        #expect(delay > 0)
    }

    @Test("honors Retry-After after a 429 for the whole category")
    func honorsRetryAfter() async {
        let governor = RateLimitGovernor(
            budgets: [.analytics: RateLimitBudget(perMinute: 100, perHour: 1000)]
        )

        await governor.penalize(.analytics, retryAfter: 30, now: t0)

        let delay = await governor.reserve(.analytics, now: t0)
        #expect(delay >= 30)
        // Jitter is added to avoid a thundering herd, but stays bounded.
        #expect(delay <= 40)

        #expect(await governor.reserve(.analytics, now: t0.addingTimeInterval(45)) == 0)
    }

    @Test("keeps categories independent so replay traffic cannot starve dashboards")
    func categoriesAreIndependent() async {
        let governor = RateLimitGovernor(
            budgets: [
                .analytics: RateLimitBudget(perMinute: 1, perHour: 10),
                .query: RateLimitBudget(perMinute: 5, perHour: 10),
            ]
        )

        _ = await governor.reserve(.analytics, now: t0)
        #expect(await governor.reserve(.analytics, now: t0) > 0)
        #expect(await governor.reserve(.query, now: t0) == 0)
    }

    @Test("ships default budgets strictly below PostHog's documented ceilings")
    func defaultsStayUnderDocumentedCeilings() {
        // Limits are organisation-wide and shared with the user's production
        // integrations, so GetHog must never budget up to the published cap.
        let defaults = RateLimitGovernor.defaultBudgets

        #expect(defaults[.analytics]!.perMinute! < 240)
        #expect(defaults[.analytics]!.perHour! < 1200)
        #expect(defaults[.query]!.perHour! < 2400)
        #expect(defaults[.crud]!.perMinute! < 480)
        #expect(defaults[.crud]!.perHour! < 4800)
    }
}
