import Foundation

// Paging for the events feed.
//
// Both types here exist because of one measurement against a live project
// ([REMOVED PRIVATE DATA], ~91k events, 2026-07-30). The feed's query was:
//
//     SELECT … FROM events ORDER BY timestamp DESC LIMIT 50
//
// with no lower bound on `timestamp`. Timed cold-cache, five runs each:
//
//     no bound, all columns          median 8.53s   succeeded 1/5
//     no bound, without properties   median 9.38s   succeeded 1/5
//     7-day bound, all columns       median 0.97s   succeeded 5/5
//     7-day bound, without properties median 0.78s  succeeded 5/5
//     24-hour bound, all columns      median 0.55s  succeeded 5/5
//
// The failures were PostHog's "Query has hit the max execution time" 504 — the
// reported symptom exactly. Two conclusions the code below is built on:
//
// 1. The lower bound is the entire fix, and dropping the `properties` map is
//    not part of it: unbounded and lean was, if anything, worse. Width is not
//    the problem either — even a 730-day bound ran in 2.06s, 3/3. What costs
//    8s is the *absence* of a bound, which leaves ClickHouse unable to prune
//    partitions and forces it across the whole retention window.
// 2. Because the bound is what matters, `properties` stays selected, and the
//    event detail view keeps working with no second request. The 0.19s it
//    would save does not buy a round trip per event opened.

/// Where the next page of the events feed resumes.
///
/// The timestamp alone is not a key. Measured on live data, three events share
/// the microsecond `2026-07-29 21:21:30.322000`; paging with `timestamp < cursor`
/// across a page boundary that cut that group silently dropped its third row,
/// and no part of the app would have said a row was missing.
public struct EventCursor: Sendable, Equatable, Hashable {
    public let timestamp: Date
    public let uuid: String

    public init(timestamp: Date, uuid: String) {
        self.timestamp = timestamp
        self.uuid = uuid
    }
}

/// How far back one request may look, and what a thin page means.
///
/// Every query the feed issues is bounded, because an unbounded one does not
/// reliably complete. That creates a question the old code never had to answer:
/// a page can come back short because there is nothing older, or because this
/// particular window is thin. Those are different facts. Concluding "end of the
/// feed" from a short page would be the app asserting something the response
/// never said, so a short page widens the window instead, and only the widest
/// window is allowed to settle the question.
public struct EventFeedPager: Sendable, Equatable {

    /// Ascending. The first rung is the common case and the cheapest query; the
    /// last is the furthest back the feed will look before it is willing to say
    /// there is nothing more.
    public static let windows: [TimeInterval] = [
        7 * 86_400,
        90 * 86_400,
        730 * 86_400,
    ]

    public private(set) var cursor: EventCursor?
    public private(set) var isExhausted = false
    private var windowIndex = 0

    public init() {}

    public var window: TimeInterval { Self.windows[windowIndex] }

    /// The lower bound for the next request.
    ///
    /// Anchored to the cursor once paging has started, not to `now`: anchoring
    /// to `now` would widen the span without limit as the reader pages back,
    /// which is the unbounded query again by a slower route.
    public func floor(now: Date) -> Date {
        (cursor?.timestamp ?? now).addingTimeInterval(-window)
    }

    /// Records what a page returned and decides where the next one starts.
    public mutating func advance(rowCount: Int, limit: Int, cursor: EventCursor?) {
        if let cursor { self.cursor = cursor }

        if rowCount >= limit {
            // Dense again: go back to the cheapest window rather than carrying a
            // wide one forward for the rest of the session.
            windowIndex = 0
            isExhausted = false
        } else if windowIndex < Self.windows.count - 1 {
            // Same cursor, wider floor — so the retry covers strictly more
            // ground without re-returning anything already shown.
            windowIndex += 1
        } else {
            isExhausted = true
        }
    }

    /// Back to the first page. This is what a pull-to-refresh and each live-tail
    /// tick do.
    public mutating func restart() {
        cursor = nil
        isExhausted = false
        windowIndex = 0
    }
}

extension QueryResponse {

    /// The resume point for the next page: the last row of this one.
    ///
    /// Taken from the server's ordering rather than recomputed here. `uuid` is a
    /// ClickHouse `UUID`, whose comparison order is not its string order, so a
    /// client-side minimum could disagree with the `ORDER BY` that produced the
    /// page and step over or repeat rows. The server ordered the rows and the
    /// server evaluates the `(timestamp, uuid) <` comparison, so the two agree
    /// by construction as long as the client only points at a row.
    public func eventCursor() -> EventCursor? {
        rows.compactMap { row -> EventCursor? in
            guard let timestamp = row.date("timestamp"), let uuid = row.string("uuid") else {
                return nil
            }
            return EventCursor(timestamp: timestamp, uuid: uuid)
        }
        .last
    }
}
