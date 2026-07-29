import Foundation

/// PostHog's published private-endpoint limits. Organisation-wide, and shared
/// with whatever else the user has integrated, which is why GetHog budgets
/// strictly below them.
public enum PostHogPublishedLimits {
    public static let analyticsPerMinute = 240
    public static let analyticsPerHour = 1200
    public static let queryPerHour = 2400
    public static let crudPerMinute = 480
    public static let crudPerHour = 4800
}

public struct RateLimitBudget: Sendable {
    public let perMinute: Int?
    public let perHour: Int?

    public init(perMinute: Int?, perHour: Int?) {
        self.perMinute = perMinute
        self.perHour = perHour
    }
}

/// Paces every request GetHog makes.
///
/// Rate limits are **organisation-wide**, so an over-eager phone client can
/// exhaust the budget its owner's production integrations depend on. That makes
/// this a correctness requirement rather than an optimisation.
///
/// `reserve(_:now:)` is a pure function of state and a supplied instant — it
/// returns how long the caller must wait — which keeps the policy fully testable
/// without sleeping.
public actor RateLimitGovernor {
    public enum Category: Sendable, Hashable, CaseIterable {
        /// Insights, persons, session recordings.
        case analytics
        /// The `/query/` endpoint.
        case query
        /// Reads and writes of dashboards, flags, and other resources.
        case crud
    }

    public static let defaultBudgets: [Category: RateLimitBudget] = [
        .analytics: RateLimitBudget(perMinute: 180, perHour: 900),
        .query: RateLimitBudget(perMinute: 60, perHour: 1800),
        .crud: RateLimitBudget(perMinute: 360, perHour: 3600),
    ]

    private var budgets: [Category: RateLimitBudget]
    private var minuteHits: [Category: [Date]] = [:]
    private var hourHits: [Category: [Date]] = [:]
    private var penaltyUntil: [Category: Date] = [:]

    /// Deterministic in tests, jittered in production.
    private let jitter: @Sendable (TimeInterval) -> TimeInterval

    public init(
        budgets: [Category: RateLimitBudget] = RateLimitGovernor.defaultBudgets,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { $0 * Double.random(in: 0...0.2) }
    ) {
        self.budgets = budgets
        self.jitter = jitter
    }

    /// Records an intended request and returns the delay to observe first.
    /// `0` means it may proceed immediately.
    public func reserve(_ category: Category, now: Date = Date()) -> TimeInterval {
        if let until = penaltyUntil[category], until > now {
            return until.timeIntervalSince(now)
        }

        guard let budget = budgets[category] else { return 0 }

        prune(category, now: now)

        var wait: TimeInterval = 0

        if let limit = budget.perMinute {
            let hits = minuteHits[category] ?? []
            if hits.count >= limit, let oldest = hits.first {
                wait = max(wait, 60 - now.timeIntervalSince(oldest))
            }
        }

        if let limit = budget.perHour {
            let hits = hourHits[category] ?? []
            if hits.count >= limit, let oldest = hits.first {
                wait = max(wait, 3600 - now.timeIntervalSince(oldest))
            }
        }

        guard wait <= 0 else { return wait }

        minuteHits[category, default: []].append(now)
        hourHits[category, default: []].append(now)
        return 0
    }

    /// Applies a server-instructed cool-off after a 429.
    public func penalize(_ category: Category, retryAfter: TimeInterval, now: Date = Date()) {
        let delay = retryAfter + jitter(retryAfter)
        penaltyUntil[category] = now.addingTimeInterval(delay)
    }

    /// Reserves a slot and waits for it, for callers that just want to proceed.
    public func waitForSlot(_ category: Category) async throws {
        while true {
            let delay = reserve(category)
            if delay <= 0 { return }
            try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
        }
    }

    /// Fraction of each budget consumed, for the Settings usage meter.
    public func usage(now: Date = Date()) -> [Category: Double] {
        var out: [Category: Double] = [:]
        for category in Category.allCases {
            prune(category, now: now)
            guard let budget = budgets[category] else { continue }
            var fraction = 0.0
            if let limit = budget.perMinute, limit > 0 {
                fraction = max(fraction, Double(minuteHits[category]?.count ?? 0) / Double(limit))
            }
            if let limit = budget.perHour, limit > 0 {
                fraction = max(fraction, Double(hourHits[category]?.count ?? 0) / Double(limit))
            }
            out[category] = min(fraction, 1)
        }
        return out
    }

    private func prune(_ category: Category, now: Date) {
        minuteHits[category] = (minuteHits[category] ?? []).filter { now.timeIntervalSince($0) < 60 }
        hourHits[category] = (hourHits[category] ?? []).filter { now.timeIntervalSince($0) < 3600 }
    }
}
