import Foundation

// Paging for the events feed. Every query has a time lower bound so ClickHouse
// can prune partitions, while retaining `properties` for the detail screen.

/// Where the next page of the events feed resumes.
///
/// The timestamp alone is not a key: multiple events can share one timestamp.
/// The UUID is the stable tiebreaker that prevents a boundary from dropping a
/// row.
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
/// never said, so a short page widens the window instead, and the widest window
/// is what finally settles the question.
///
/// With one exception, and it is the one that matters for whether the feed ever
/// stops: widening only makes sense while the *cursor* is still moving. A
/// response that hands back rows without a resume point past the one it was
/// given has already said it can go no further, and asking it again over a wider
/// floor is a loop, not a search. `advance(rowCount:limit:cursor:)` treats that
/// as the end at any rung.
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
    ///
    /// A page that does not fill its limit can mean three different things, and
    /// the old code collapsed two of them into "widen and ask again":
    ///
    /// - **Short or empty, but the resume point moved on.** The window was thin.
    ///   Widen and ask again from the same cursor; the lower floor covers
    ///   strictly more ground without re-returning anything already shown.
    /// - **Empty.** Same conclusion, and there is no resume point to move: no
    ///   rows *in this window* is not evidence of no rows at all.
    /// - **Rows came back, but the resume point did not move past the one this
    ///   request carried.** That is the end, whatever rung the window is on. The
    ///   next request would be this request: keyset paging resumes from the
    ///   cursor, so a response that hands back the same cursor — or none at all
    ///   — has said it cannot go further, and a wider floor cannot change that.
    ///   Widening here is an infinite loop with a spinner on top, and it is what
    ///   the events feed did: the demo fixture answers every request with the
    ///   same five rows and no `uuid` column, so the pager widened to its last
    ///   rung, `isExhausted` stayed false, and the footer promised more forever.
    public mutating func advance(rowCount: Int, limit: Int, cursor: EventCursor?) {
        // Asked before the cursor is adopted, because the question is whether
        // *this* response moved past the point it was given.
        let resumed = Self.resumes(cursor, past: self.cursor)
        if resumed, let cursor { self.cursor = cursor }

        if rowCount > 0 && !resumed {
            isExhausted = true
        } else if rowCount >= limit {
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

    /// Whether a page's resume point is genuinely further back than the one the
    /// request carried.
    ///
    /// The timestamp is compared and the uuid is only checked for *difference*,
    /// never ordered. A ClickHouse `UUID` does not compare as its string, so an
    /// order imposed here could disagree with the `ORDER BY` that produced the
    /// page — the same reason `eventCursor()` points at the server's last row
    /// instead of recomputing a minimum. Within one timestamp the server's
    /// ordering is the only one that exists, so "a different row" is as much as
    /// the client can honestly say, and it is enough: the case this has to catch
    /// is a response handing back the *identical* pair it was given.
    private static func resumes(_ page: EventCursor?, past sent: EventCursor?) -> Bool {
        guard let page else { return false }
        guard let sent else { return true }
        if page.timestamp != sent.timestamp { return page.timestamp < sent.timestamp }
        return page.uuid != sent.uuid
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
