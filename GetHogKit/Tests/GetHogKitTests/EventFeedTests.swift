import Foundation
import Testing

@testable import GetHogKit

/// The events feed's query shape and paging arithmetic.
///
/// The events feed's deterministic query contract and paging arithmetic.
@Suite("Events feed query")
struct EventsFeedQueryTests {

    private static let floor = Date(timeIntervalSince1970: 1_767_225_600)

    static func sql(_ endpoint: Endpoint) -> String? {
        guard let body = endpoint.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let query = json["query"] as? [String: Any]
        else { return nil }
        return query["query"] as? String
    }

    @Test("every events query carries a lower time bound")
    func alwaysBounded() throws {
        // The lower bound is required for partition pruning.
        let endpoint = PostHogAPI.events(projectID: 1, limit: 50, since: Self.floor)
        let sql = try #require(Self.sql(endpoint))
        #expect(sql.contains("timestamp > toDateTime64("))
    }

    @Test("the token-filtered feed is bounded too")
    func tokenQueryBounded() throws {
        let endpoint = PostHogAPI.events(
            projectID: 1, limit: 50, since: Self.floor, tokens: [], search: nil
        )
        let sql = try #require(Self.sql(endpoint))
        #expect(sql.contains("timestamp > toDateTime64("))
    }

    @Test("orders by timestamp and uuid, so a shared timestamp has a stable tiebreak")
    func totalOrdering() throws {
        let endpoint = PostHogAPI.events(projectID: 1, limit: 50, since: Self.floor)
        let sql = try #require(Self.sql(endpoint))
        #expect(sql.contains("ORDER BY timestamp DESC, uuid DESC"))
    }

    @Test("pages on the (timestamp, uuid) pair rather than the timestamp alone")
    func tieSafeKeyset() throws {
        // Multiple events can share a timestamp. Paging with `timestamp < cursor`
        // across that boundary silently drops rows; the pair drops nothing.
        let cursor = EventCursor(timestamp: Self.floor, uuid: "abc-123")
        let endpoint = PostHogAPI.events(
            projectID: 1, limit: 50, since: Self.floor.addingTimeInterval(-86_400), before: cursor
        )
        let sql = try #require(Self.sql(endpoint))
        #expect(sql.contains("(timestamp, uuid) < (toDateTime64("))
        #expect(sql.contains("'abc-123'"))
        // OFFSET is rejected for personal API keys, so paging must stay keyset.
        #expect(!sql.uppercased().contains("OFFSET"))
    }

    @Test("omits the keyset clause on the first page but keeps the bound")
    func firstPage() throws {
        let endpoint = PostHogAPI.events(projectID: 1, limit: 25, since: Self.floor)
        let sql = try #require(Self.sql(endpoint))
        #expect(!sql.contains("(timestamp, uuid) <"))
        #expect(sql.contains("timestamp > toDateTime64("))
        #expect(sql.contains("LIMIT 25"))
    }

    @Test("keeps the properties map, so opening an event costs no second request")
    func keepsProperties() throws {
        // Measured: with the bound in place, dropping `properties` moved the
        // median from 0.97s to 0.78s. That 0.19s does not buy a per-event round
        // trip and a loading state in the detail view, so the column stays.
        let endpoint = PostHogAPI.events(projectID: 1, limit: 50, since: Self.floor)
        let sql = try #require(Self.sql(endpoint))
        #expect(sql.contains("properties"))
        #expect(sql.contains("$current_url"))
    }

    @Test("escapes a uuid cursor so it cannot break out of the literal")
    func escapesCursor() throws {
        let cursor = EventCursor(timestamp: Self.floor, uuid: "it's")
        let endpoint = PostHogAPI.events(projectID: 1, limit: 5, since: Self.floor, before: cursor)
        let sql = try #require(Self.sql(endpoint))
        #expect(sql.contains(#"it\'s"#))
    }
}

@Suite("Events feed paging")
struct EventFeedPagerTests {

    private static let now = Date(timeIntervalSince1970: 1_767_225_600)

    @Test("starts at the narrowest window, which is the cheapest query")
    func startsNarrow() {
        let pager = EventFeedPager()
        #expect(pager.window == EventFeedPager.windows[0])
        #expect(pager.cursor == nil)
        #expect(!pager.isExhausted)
    }

    @Test("bounds the first page relative to now")
    func firstPageFloor() {
        let pager = EventFeedPager()
        #expect(pager.floor(now: Self.now) == Self.now.addingTimeInterval(-pager.window))
    }

    @Test("bounds later pages relative to the cursor, so scrollback stays bounded")
    func laterPageFloor() {
        // Anchoring to `now` instead would make the window grow without limit as
        // the reader pages back, which is the unbounded query by another name.
        var pager = EventFeedPager()
        let cursor = EventCursor(timestamp: Self.now.addingTimeInterval(-10_000), uuid: "u")
        pager.advance(rowCount: 50, limit: 50, cursor: cursor)
        #expect(pager.floor(now: Self.now) == cursor.timestamp.addingTimeInterval(-pager.window))
    }

    @Test("a full page keeps the window narrow")
    func fullPageStaysNarrow() {
        var pager = EventFeedPager()
        pager.advance(rowCount: 50, limit: 50, cursor: EventCursor(timestamp: Self.now, uuid: "u"))
        #expect(pager.window == EventFeedPager.windows[0])
        #expect(!pager.isExhausted)
    }

    @Test("a short page widens the window instead of declaring the end")
    func shortPageWidens() {
        // A short page inside a bounded window is not evidence that there are no
        // older events — only that this window is thin. Calling it the end would
        // be the app claiming something the response never said.
        var pager = EventFeedPager()
        pager.advance(rowCount: 3, limit: 50, cursor: EventCursor(timestamp: Self.now, uuid: "u"))
        #expect(pager.window > EventFeedPager.windows[0])
        #expect(!pager.isExhausted)
    }

    @Test("widening keeps the cursor, so no row is skipped or repeated")
    func wideningKeepsCursor() {
        var pager = EventFeedPager()
        let cursor = EventCursor(timestamp: Self.now, uuid: "u")
        pager.advance(rowCount: 0, limit: 50, cursor: nil)
        #expect(pager.cursor == nil)

        var paged = EventFeedPager()
        paged.advance(rowCount: 3, limit: 50, cursor: cursor)
        #expect(paged.cursor == cursor)
    }

    @Test("declares the end only after the widest window is still short")
    func exhaustsAfterWidestWindow() {
        var pager = EventFeedPager()
        for _ in EventFeedPager.windows.indices {
            #expect(!pager.isExhausted)
            pager.advance(rowCount: 0, limit: 50, cursor: nil)
        }
        #expect(pager.isExhausted)
        #expect(pager.window == EventFeedPager.windows.last)
    }

    @Test("a page that hands back the cursor it was given is the end, not a thin window")
    func repeatedCursorIsTheEnd() {
        // Keyset paging resumes *from* the cursor, so a page that returns rows
        // and reports the same resume point has said it cannot go further. The
        // next request would be this request, at any floor.
        var pager = EventFeedPager()
        let cursor = EventCursor(timestamp: Self.now, uuid: "u")

        pager.advance(rowCount: 5, limit: 50, cursor: cursor)
        #expect(!pager.isExhausted, "The first page moved the cursor off nil; that is progress.")

        pager.advance(rowCount: 5, limit: 50, cursor: cursor)
        #expect(pager.isExhausted)
    }

    @Test("rows with no resume point at all end the feed rather than widening it")
    func rowsWithoutACursorAreTheEnd() {
        // The demo fixture's exact shape, and the defect's direct cause: five
        // rows against a page size of fifty, and no `uuid` column, so
        // `eventCursor()` has nothing to point at. Widening asks the same
        // question again and gets the same five rows, forever.
        var pager = EventFeedPager()
        pager.advance(rowCount: 5, limit: 50, cursor: nil)
        #expect(pager.isExhausted)
    }

    @Test("a source that answers every request identically still reaches the end")
    func aStallingSourceTerminates() {
        // The property the footer's spinner depends on: paging terminates. This
        // loops the way the feed does, and before the stall check it ran until
        // the guard rather than until the pager was done.
        var pager = EventFeedPager()
        let cursor = EventCursor(timestamp: Self.now, uuid: "u")
        var pages = 0
        while !pager.isExhausted && pages < 100 {
            pager.advance(rowCount: 5, limit: 50, cursor: cursor)
            pages += 1
        }
        #expect(pager.isExhausted)
        #expect(pages <= 2, "Took \(pages) pages to notice a source that never moves.")
    }

    @Test("a page reaching back up past its own cursor is refused, not adopted")
    func neverWalksTheCursorForwards() {
        // A cursor that moved *newer* would re-serve rows already on screen and
        // page the feed in a circle.
        var pager = EventFeedPager()
        let older = EventCursor(timestamp: Self.now.addingTimeInterval(-1_000), uuid: "u")
        pager.advance(rowCount: 50, limit: 50, cursor: older)

        let newer = EventCursor(timestamp: Self.now, uuid: "v")
        pager.advance(rowCount: 50, limit: 50, cursor: newer)
        #expect(pager.cursor == older)
        #expect(pager.isExhausted)
    }

    @Test("a short page that did move the cursor still widens rather than stopping")
    func realProgressStillWidens() {
        // The stall check must not swallow the case widening exists for: three
        // rows from a thin week is not evidence that there is no fourth.
        var pager = EventFeedPager()
        pager.advance(rowCount: 3, limit: 50, cursor: EventCursor(timestamp: Self.now, uuid: "a"))
        #expect(!pager.isExhausted)

        pager.advance(
            rowCount: 3,
            limit: 50,
            cursor: EventCursor(timestamp: Self.now.addingTimeInterval(-9_000), uuid: "b")
        )
        #expect(!pager.isExhausted)
        #expect(pager.window == EventFeedPager.windows[2])
    }

    @Test("two rows sharing a timestamp are different rows, so paging is progressing")
    func aTieIsStillProgress() {
        // Within one microsecond the server's ordering is the only one there is
        // — a ClickHouse UUID does not compare as its string — so the client can
        // only ask whether the row is a different row. It is.
        var pager = EventFeedPager()
        pager.advance(rowCount: 5, limit: 50, cursor: EventCursor(timestamp: Self.now, uuid: "a"))
        pager.advance(rowCount: 5, limit: 50, cursor: EventCursor(timestamp: Self.now, uuid: "b"))
        #expect(!pager.isExhausted)
    }

    @Test("a full page after widening returns to the narrow window")
    func denseAgainNarrows() {
        var pager = EventFeedPager()
        pager.advance(rowCount: 0, limit: 50, cursor: nil)
        #expect(pager.window > EventFeedPager.windows[0])

        pager.advance(rowCount: 50, limit: 50, cursor: EventCursor(timestamp: Self.now, uuid: "u"))
        #expect(pager.window == EventFeedPager.windows[0])
    }

    @Test("restarting returns to the first page, which is what live tail does")
    func restart() {
        var pager = EventFeedPager()
        pager.advance(rowCount: 0, limit: 50, cursor: nil)
        pager.advance(rowCount: 0, limit: 50, cursor: nil)
        pager.restart()
        #expect(pager.cursor == nil)
        #expect(!pager.isExhausted)
        #expect(pager.window == EventFeedPager.windows[0])
    }

    @Test("the widest window is finite, so the feed can always state what it searched")
    func windowsAreFinite() {
        #expect(!EventFeedPager.windows.isEmpty)
        #expect(EventFeedPager.windows == EventFeedPager.windows.sorted())
    }
}

@Suite("Events feed cursor")
struct EventCursorTests {

    private func response(_ rows: [(String, String)]) throws -> QueryResponse {
        let results = rows.map { "[\"\($0.0)\", \"\($0.1)\"]" }.joined(separator: ",")
        let json = #"{"columns":["uuid","timestamp"],"results":[\#(results)]}"#
        return try QueryResponse.decode(from: Data(json.utf8))
    }

    @Test("resumes inside a tie group rather than stepping over the rest of it")
    func resumesInsideATie() throws {
        // Authored tie case: two rows share a microsecond.
        let response = try response([
            ("018f7e00-0000-7000-8000-000000000006", "2026-01-15T10:00:00Z"),
            ("018f7e00-0000-7000-8000-000000000005", "2026-01-15T10:00:00Z"),
        ])
        let cursor = try #require(response.eventCursor())
        #expect(cursor.uuid == "018f7e00-0000-7000-8000-000000000005")
        #expect(cursor.timestamp == PostHogDate.parse("2026-01-15T10:00:00Z"))
    }

    @Test("points at the server's last row rather than recomputing an order")
    func trustsTheServerOrdering() throws {
        // `uuid` is a ClickHouse UUID and does not compare as its string. A
        // client-side minimum would be a second, disagreeing opinion about the
        // ordering; pointing at the last row cannot disagree with it.
        let response = try response([
            ("aaaa", "2026-01-15T10:00:00Z"),
            ("zzzz", "2026-01-15T09:00:00Z"),
        ])
        let cursor = try #require(response.eventCursor())
        #expect(cursor.uuid == "zzzz")
    }

    @Test("has no cursor when the page is empty")
    func emptyPage() throws {
        let response = try response([])
        #expect(response.eventCursor() == nil)
    }
}
