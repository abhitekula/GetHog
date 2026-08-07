import Foundation

/// What one fetch may cost from a small screen on a small battery.
///
/// The endpoint catalog's defaults were chosen for a phone with a scrollable
/// list and a charger nearby: a hundred dashboards, fifty event rows, a week of
/// history, every series a saved insight defines. A watch face shows one number
/// and a sparkline, on a battery that is measured in a single day, over a radio
/// that is often relaying through the phone.
///
/// So the budget is a value rather than a set of literals at the call sites.
/// Three axes, because those are the three that cost: how far back the scan
/// reaches, how many rows come back, and how many series a trimmed insight
/// keeps. Every overload below **forwards to the existing builder** with those
/// numbers substituted, so paths, categories, SQL bounds and escaping rules
/// stay written exactly once and a budgeted request is the ordinary request
/// with smaller arguments — never a second spelling that can drift.
public struct QueryBudget: Sendable, Equatable {

    /// Range lower bound, in hours — the single source both spellings derive
    /// from, so a budget cannot be 24h in one request and 6h in the next.
    public let hours: Int
    public let pageSize: Int
    /// How many series a trimmed insight keeps: the first N, in saved order.
    public let maxSeries: Int

    public init(hours: Int, pageSize: Int, maxSeries: Int) {
        self.hours = hours
        self.pageSize = pageSize
        self.maxSeries = maxSeries
    }

    /// The bound as query nodes spell it, e.g. `"-24h"`.
    public var dateFrom: String { "-\(hours)h" }

    /// The bound as the endpoints taking a `Date` floor spell it.
    public func since(now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(hours) * 3_600)
    }

    /// Wrist scale: one day, ten rows, three series.
    ///
    /// A day because a watch is a glance at *now*, and anything a week old
    /// belongs on the phone. Ten rows because that is roughly what a wrist can
    /// scroll before the gesture stops being worth it. Three series because a
    /// legend past three on that screen is unreadable, and each extra series is
    /// another aggregation ClickHouse performs.
    public static let wrist = QueryBudget(hours: 24, pageSize: 10, maxSeries: 3)
}

// MARK: - Budgeted endpoints

public extension PostHogAPI {

    static func dashboards(projectID: Int, budget: QueryBudget) -> Endpoint {
        dashboards(projectID: projectID, limit: budget.pageSize)
    }

    static func featureFlags(projectID: Int, budget: QueryBudget) -> Endpoint {
        featureFlags(projectID: projectID, limit: budget.pageSize)
    }

    static func webOverview(projectID: Int, budget: QueryBudget) -> Endpoint {
        webOverview(projectID: projectID, dateFrom: budget.dateFrom)
    }

    /// The events feed with the payload cut to what a small screen renders.
    ///
    /// The full feed selects `properties` and `properties.$current_url` because
    /// the phone has a detail screen that shows every property of an event.
    /// Nothing on a wrist does. Both are dropped, and the second one is worth
    /// naming separately: `properties.$current_url` is a JSON extraction
    /// evaluated over every row the scan touches, which is precisely the cost a
    /// budget exists to avoid — not merely bytes on the wire.
    ///
    /// What survives is what a feed row is: `uuid` for identity and for the
    /// keyset cursor, `event` for the name, `timestamp` for the age, and
    /// `distinct_id` for who. `QueryResponse` keys rows by column name, so a
    /// reader asking for a column this query does not select gets `nil` rather
    /// than a wrong value at a shifted index.
    ///
    /// `since` has no default and is not optional, for the reason the full feed
    /// documents at length: an unbounded `ORDER BY timestamp DESC` over
    /// `events` does not reliably complete. That is a property of the table,
    /// not of the columns, so it holds here identically.
    static func recentEventLines(projectID: Int, limit: Int = 25, since floor: Date) -> Endpoint {
        hogql(projectID: projectID, sql: recentEventLinesSQL(limit: limit, since: floor))
    }

    static func recentEventLines(
        projectID: Int,
        budget: QueryBudget,
        now: Date = Date()
    ) -> Endpoint {
        recentEventLines(
            projectID: projectID,
            limit: budget.pageSize,
            since: budget.since(now: now)
        )
    }
}

extension PostHogAPI {

    /// The thin feed's SQL, beside the builder that is its only caller.
    ///
    /// Deliberately not a parameter on `eventsSQL`: that function's clause
    /// assembly is about *filters and paging*, and threading a column list
    /// through it would put two unrelated decisions in one signature. What has
    /// to stay identical between the two — the time bound, the tie-safe
    /// ordering, the absence of `OFFSET` — is pinned by tests on both.
    static func recentEventLinesSQL(limit: Int, since floor: Date) -> String {
        """
        SELECT uuid, event, timestamp, distinct_id
        FROM events
        WHERE timestamp > toDateTime64('\(sqlTimestamp(floor))', 6)
        ORDER BY timestamp DESC, uuid DESC
        LIMIT \(limit)
        """
    }
}

// MARK: - Budgeted insight sources

public extension InsightRerun {

    /// `source(_:dateFrom:compare:)` with the budget's range, the comparison
    /// dropped, and `series` capped at `budget.maxSeries`.
    ///
    /// The comparison goes because a compared query asks PostHog for two
    /// entries per series — the exact opposite of a budget — and it is
    /// *removed* rather than set to false, which is the same rule `dated`
    /// already enforces: not asking to compare is a different request from
    /// asking not to.
    ///
    /// The cap keeps the **first** `maxSeries` in saved order. Not a sample and
    /// not a re-sort: the order the user saved is the order they read, so a
    /// trimmed insight is the top of their chart rather than an arbitrary
    /// slice of it. A node with fewer series is not padded, one without a
    /// `series` key is left alone, and a `series` that is not an array is left
    /// exactly as found — a malformed saved query should fail its own request
    /// and degrade one tile, not be rewritten into something that looks valid.
    static func source(_ source: JSONValue, budget: QueryBudget) -> JSONValue {
        guard case .object(let fields) = source else { return source }
        var trimmed = dated(fields, dateFrom: budget.dateFrom, compare: false)
        if case .array(let series)? = trimmed["series"], series.count > budget.maxSeries {
            trimmed["series"] = .array(Array(series.prefix(budget.maxSeries)))
        }
        return .object(trimmed)
    }
}
