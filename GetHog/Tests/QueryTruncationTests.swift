import Foundation
import GetHogKit
import Testing

@testable import GetHog

// What the screens do with `QueryResponse.isTruncated`, which is the flag that
// exists because a HogQL query with no `LIMIT` of its own is capped at 100 rows
// at HTTP 200, with no error and no warning anywhere in the payload.
//
// **The public response contract these tests are shaped around**, documented in
// `PostHogAPI+Groups.swift` and load-bearing for every assertion below:
// `hasMore` and `limit` come back **only when PostHog applied its own cap**. A
// query with no `LIMIT` returned `hasMore: false, limit: 100` over 63 rows and
// `hasMore: true, limit: 100` over 423; the identical query written `LIMIT 200`
// returned 200 rows of 423 with **neither field present**.
//
// Two consequences, and both are asserted rather than assumed:
//
//   1. Where the reader writes the SQL — the console — the flag is the whole
//      answer, and it is silent about the reader's own `LIMIT`. A screen that
//      claimed completeness from `isTruncated == false` would be inventing one.
//   2. Where the app writes the SQL with its own `LIMIT` — the session
//      timeline, the schema browser — the flag is silent *at* the ceiling, so
//      the row count is still the evidence. Replacing the count with the flag
//      would delete those notices outright.

/// Builds a `/query/` envelope with whichever envelope fields are being tested.
private func queryResponse(
    columns: [String],
    rows: [[String]],
    hasMore: Bool? = nil,
    limit: Int? = nil
) throws -> QueryResponse {
    var object: [String: Any] = [
        "columns": columns,
        "results": rows,
    ]
    if let hasMore { object["hasMore"] = hasMore }
    if let limit { object["limit"] = limit }
    return try QueryResponse.decode(from: try JSONSerialization.data(withJSONObject: object))
}

@Suite("Query truncation")
@MainActor
struct QueryTruncationTests {

    // MARK: - The SQL console

    /// The screen where the *reader* writes the query, and therefore the one
    /// most likely to omit a `LIMIT` — which is exactly what PostHog caps.
    ///
    /// The status line read "\(n) rows" unconditionally and the export was
    /// titled "Query result" with `rowCount: response.rows.count`. So
    /// `SELECT * FROM events` was answered "100 rows" and produced a 100-row
    /// file called `Query result.csv`, with nothing anywhere saying PostHog had
    /// stopped early. The number was not partial, it was the cap.
    @Test("the console reports the cap PostHog applied, in the status and in the export")
    func consoleStatesTheCap() throws {
        let store = SQLConsoleStore()
        store.response = try queryResponse(
            columns: ["event"],
            rows: (0..<100).map { ["e\($0)"] },
            hasMore: true,
            limit: 100
        )

        #expect(store.isTruncated)
        #expect(store.appliedCap == 100)
        let export = try #require(store.export)
        // The title is the file name, the share-sheet preview and the export
        // control's accessibility label — the parts of a CSV that survive being
        // forwarded to somebody who never saw the screen.
        #expect(export.title.contains("PostHog capped"))
        #expect(export.fileName.contains("PostHog capped"))
        #expect(export.rowCount == 100)
    }

    /// The reader's own `LIMIT` produces an envelope with neither field, so the
    /// console has nothing to report and must report nothing.
    ///
    /// This is the case that makes "just show a warning when rows == limit"
    /// wrong on this screen: `LIMIT 20` matching exactly twenty rows is the
    /// ordinary outcome of a deliberate query, and crying truncation over it
    /// would train the reader to ignore the one notice that matters.
    @Test("a reader's own LIMIT is not reported as truncation")
    func consoleStaysSilentOnItsReadersLimit() throws {
        let store = SQLConsoleStore()
        store.response = try queryResponse(
            columns: ["event"],
            rows: (0..<20).map { ["e\($0)"] }
        )

        #expect(!store.isTruncated)
        #expect(store.appliedCap == nil)
        #expect(try #require(store.export).title == "Query result")
    }

    /// `hasMore: false` with a `limit` present is a real shape — PostHog sends
    /// it whenever it applied a default cap the result did not reach — and it
    /// means "capped, but there was nothing more". Nothing may be claimed there.
    @Test("a cap that was not reached is not truncation")
    func consoleReadsAnUnreachedCapAsComplete() throws {
        let store = SQLConsoleStore()
        store.response = try queryResponse(
            columns: ["event"],
            rows: (0..<63).map { ["e\($0)"] },
            hasMore: false,
            limit: 100
        )

        #expect(!store.isTruncated)
        #expect(store.appliedCap == nil)
    }

    @Test("no result at all is not a truncated result")
    func consoleWithNoResult() {
        let store = SQLConsoleStore()
        #expect(!store.isTruncated)
        #expect(store.appliedCap == nil)
        #expect(store.export == nil)
    }

    // MARK: - The session timeline

    /// The defect this replaced, in one assertion: `didHitLimit` counted the
    /// *decoded* events, and `EventRow.init(row:)` is failable.
    ///
    /// A full page holding one row without an `event` column decoded to 499
    /// against a ceiling of 500, so the "showing the first N" notice vanished —
    /// silently, and precisely when the data was least trustworthy. The reader
    /// got a timeline that was both truncated and lossy, described as neither.
    @Test("an undecodable row does not retire the timeline's truncation notice")
    func timelineCountsRowsNotDecodedEvents() async throws {
        let full = SessionTimelineStore.limit
        var rows: [[String: String?]] = (0..<(full - 1)).map {
            ["uuid": "u\($0)", "event": "$pageview", "timestamp": "2026-01-12T12:00:00Z"]
        }
        // The one row `EventRow.init(row:)` returns nil for: no `event`.
        rows.append(["uuid": "u-broken", "event": nil, "timestamp": "2026-01-12T12:00:00Z"])

        let store = SessionTimelineStore()
        await store.load(
            client: client(RowTransport(columns: ["uuid", "event", "timestamp"], rows: rows)),
            projectID: 1,
            sessionID: "s1",
            window: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 3600)
        )

        #expect(store.events.count == full - 1)
        #expect(store.rowsReturned == full)
        #expect(store.didHitLimit, "the page was full; one undecodable row does not make it short")
    }

    /// The flag still has to be honoured, for the case the count cannot see:
    /// PostHog capping *below* the limit the query asked for.
    @Test("the timeline honours a cap PostHog applied below its own limit")
    func timelineHonoursTheEnvelopeFlag() async throws {
        let rows: [[String: String?]] = (0..<100).map {
            ["uuid": "u\($0)", "event": "$pageview", "timestamp": "2026-01-12T12:00:00Z"]
        }
        let store = SessionTimelineStore()
        await store.load(
            client: client(
                RowTransport(
                    columns: ["uuid", "event", "timestamp"],
                    rows: rows,
                    hasMore: true,
                    limit: 100
                )
            ),
            projectID: 1,
            sessionID: "s1",
            window: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 3600)
        )

        #expect(store.rowsReturned == 100)
        #expect(store.rowsReturned < SessionTimelineStore.limit)
        #expect(store.didHitLimit)
    }

    @Test("a short page claims nothing")
    func timelineShortPage() async throws {
        let rows: [[String: String?]] = (0..<3).map {
            ["uuid": "u\($0)", "event": "$pageview", "timestamp": "2026-01-12T12:00:00Z"]
        }
        let store = SessionTimelineStore()
        await store.load(
            client: client(RowTransport(columns: ["uuid", "event", "timestamp"], rows: rows)),
            projectID: 1,
            sessionID: "s1",
            window: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 3600)
        )

        #expect(store.events.count == 3)
        #expect(!store.didHitLimit)
    }

    // MARK: - One person's events

    /// The defect this replaced is the one the spec comment warns is *worse*
    /// than never looking: a screen reading `isTruncated` as a general
    /// completeness check.
    ///
    /// `PersonEventsStore` writes its own `LIMIT 50`, so the envelope carries
    /// neither `hasMore` nor `limit` however full the page is. The store set
    /// `isTruncated = response.isTruncated` — permanently false — and the
    /// footer then read that falsity as evidence and said "and PostHog reported
    /// no more". A person with fifty thousand events was described as having
    /// fifty, in a sentence that named PostHog as the authority for it.
    @Test("a full page of one person's events is truncated, whatever the envelope says")
    func personEventsFullPage() async throws {
        let full = PersonEventsStore.limit
        let rows: [[String: String?]] = (0..<full).map { _ in
            ["event": "$pageview", "timestamp": "2026-01-12T12:00:00Z"]
        }
        let store = PersonEventsStore()
        await store.load(
            client: client(RowTransport(columns: ["event", "timestamp"], rows: rows)),
            projectID: 1,
            distinctID: "d1"
        )

        #expect(store.rowsReturned == full)
        #expect(store.isTruncated, "the page is full; the envelope is silent about our own LIMIT")
    }

    /// The same failable-initialiser trap the session timeline was corrected
    /// for. `PersonEvent.init(row:)` returns nil without an `event` column, so a
    /// decoded count would read 49 of 50 and retire the notice.
    @Test("an undecodable row does not retire the person's truncation notice")
    func personEventsCountsRowsNotDecodedEvents() async throws {
        let full = PersonEventsStore.limit
        var rows: [[String: String?]] = (0..<(full - 1)).map { _ in
            ["event": "$pageview", "timestamp": "2026-01-12T12:00:00Z"]
        }
        rows.append(["event": nil, "timestamp": "2026-01-12T12:00:00Z"])

        let store = PersonEventsStore()
        await store.load(
            client: client(RowTransport(columns: ["event", "timestamp"], rows: rows)),
            projectID: 1,
            distinctID: "d1"
        )

        #expect(store.events.count == full - 1)
        #expect(store.rowsReturned == full)
        #expect(store.isTruncated)
    }

    /// A short page is the one case where this screen may say the list is
    /// everything — and it says so from the count, not from a flag that cannot
    /// speak.
    @Test("a short page of person events claims completeness from the count")
    func personEventsShortPage() async throws {
        let rows: [[String: String?]] = (0..<3).map { _ in
            ["event": "$pageview", "timestamp": "2026-01-12T12:00:00Z"]
        }
        let store = PersonEventsStore()
        await store.load(
            client: client(RowTransport(columns: ["event", "timestamp"], rows: rows)),
            projectID: 1,
            distinctID: "d1"
        )
        #expect(store.rowsReturned == 3)
        #expect(!store.isTruncated)
    }

    /// The half the count cannot see, kept for the same reason the timeline
    /// keeps it: PostHog capping below the limit that was asked for.
    @Test("the person's events honour a cap PostHog applied below the query's own")
    func personEventsHonourTheEnvelopeFlag() async throws {
        let rows: [[String: String?]] = (0..<10).map { _ in
            ["event": "$pageview", "timestamp": "2026-01-12T12:00:00Z"]
        }
        let store = PersonEventsStore()
        await store.load(
            client: client(
                RowTransport(columns: ["event", "timestamp"], rows: rows, hasMore: true, limit: 10)
            ),
            projectID: 1,
            distinctID: "d1"
        )
        #expect(store.rowsReturned < PersonEventsStore.limit)
        #expect(store.isTruncated)
    }

    // MARK: - Logs

    /// The logs screen's count is read as "how much was logged", and its
    /// "no problems" state as a project-wide all-clear. Both were drawn from the
    /// newest 100 lines with nothing saying so, which makes a fatal at line 101
    /// invisible *and* contradicted.
    @Test("a full page of logs is reported as a page")
    func logsFullPage() async throws {
        let full = LogsStore.limit
        let rows: [[String: String?]] = (0..<full).map {
            ["uuid": "l\($0)", "body": "hello", "severity_text": "info",
             "timestamp": "2026-01-12T12:00:00Z"]
        }
        let store = LogsStore()
        await store.load(
            client: client(
                RowTransport(
                    columns: ["uuid", "body", "severity_text", "timestamp"], rows: rows
                )
            ),
            projectID: 1
        )
        #expect(store.rowsReturned == full)
        #expect(store.isTruncated)
    }

    /// `LogRow.rows(from:)` drops any line with no body, so the decoded count
    /// runs under the wire's exactly when a line could not be read.
    @Test("an unreadable log line does not retire the logs truncation notice")
    func logsCountRowsNotDecodedLines() async throws {
        let full = LogsStore.limit
        var rows: [[String: String?]] = (0..<(full - 1)).map {
            ["uuid": "l\($0)", "body": "hello", "severity_text": "info",
             "timestamp": "2026-01-12T12:00:00Z"]
        }
        rows.append(["uuid": "l-broken", "body": nil, "severity_text": "fatal",
                     "timestamp": "2026-01-12T12:00:00Z"])

        let store = LogsStore()
        await store.load(
            client: client(
                RowTransport(
                    columns: ["uuid", "body", "severity_text", "timestamp"], rows: rows
                )
            ),
            projectID: 1
        )
        #expect(store.rows.count == full - 1)
        #expect(store.rowsReturned == full)
        #expect(store.isTruncated)
    }

    @Test("a quiet window claims nothing")
    func logsShortPage() async throws {
        let rows: [[String: String?]] = (0..<4).map {
            ["uuid": "l\($0)", "body": "hello", "severity_text": "info",
             "timestamp": "2026-01-12T12:00:00Z"]
        }
        let store = LogsStore()
        await store.load(
            client: client(
                RowTransport(
                    columns: ["uuid", "body", "severity_text", "timestamp"], rows: rows
                )
            ),
            projectID: 1
        )
        #expect(!store.isTruncated)
    }

    // MARK: - Outbound links

    /// The one query on the Web screen that sends no `limit` of its own, which
    /// is the narrow case `QueryResponse.isTruncated` is reliable in — and the
    /// one section that was not reading it.
    @Test("the outbound list records the cap PostHog applied to it")
    func outboundClicksRecordTheServerCap() async throws {
        let store = WebAnalyticsStore()
        await store.loadExternalClicks(
            client: client(
                RowTransport(
                    columns: ["context.columns.url", "context.columns.visitors",
                              "context.columns.clicks"],
                    rows: [["context.columns.url": "https://example.com",
                            "context.columns.visitors": "3",
                            "context.columns.clicks": "9"]],
                    hasMore: true,
                    limit: 100
                )
            ),
            projectID: 1,
            window: .week
        )

        #expect(store.externalClicks.count == 1)
        #expect(store.externalClicksAreTruncated)
        #expect(store.externalClicksLimit == 100)
    }

    /// The authored shape from `web_external_clicks.json`: the cap is reported,
    /// and it was not reached. Nothing may be claimed from that.
    @Test("a cap the outbound query did not reach is not truncation")
    func outboundClicksUnderTheCap() async throws {
        let store = WebAnalyticsStore()
        await store.loadExternalClicks(
            client: client(
                RowTransport(
                    columns: ["context.columns.url", "context.columns.clicks"],
                    rows: [["context.columns.url": "https://example.com",
                            "context.columns.clicks": "9"]],
                    hasMore: false,
                    limit: 100
                )
            ),
            projectID: 1,
            window: .week
        )
        #expect(!store.externalClicksAreTruncated)
    }

    // MARK: - Error tracking

    /// `ErrorsOverview` folds four figures out of this one page — an issue
    /// count, a sum of occurrences, a status split and a "new in period" count —
    /// and prints them under the project's name and the window's title. The
    /// response envelope has always carried `hasMore`; the decoder dropped it,
    /// so there was nothing on the screen or behind it that could tell a total
    /// from a page sum.
    @Test("a truncated page of issues is recorded as one")
    func errorIssuesRecordCoverage() async throws {
        let store = ErrorTrackingStore()
        await store.load(
            client: client(IssueTransport(count: ErrorTrackingStore.limit, hasMore: true, limit: 50)),
            projectID: 1,
            window: .week,
            order: .users
        )

        let coverage = try #require(store.coverage)
        #expect(coverage.isTruncated)
        let note = coverage.note(shown: store.issues.count, window: "last 7 days")
        #expect(note.contains("PostHog reported more"))
    }

    @Test("a short page of issues is described as all of them")
    func errorIssuesShortPage() async throws {
        let store = ErrorTrackingStore()
        await store.load(
            client: client(IssueTransport(count: 3, hasMore: false, limit: nil)),
            projectID: 1,
            window: .week,
            order: .users
        )

        let coverage = try #require(store.coverage)
        #expect(!coverage.isTruncated)
        #expect(coverage.note(shown: 3, window: "last 7 days").contains("all 3 issues"))
    }

    // MARK: - The web-analytics export

    /// On-screen honesty has to survive the export.
    ///
    /// `WebAnalyticsRoot` draws "Top 50 pages by visitors. PostHog has more."
    /// above these very rows, and the CSV carried the rows and dropped the
    /// sentence — the wrong way round, because the file is the artifact that
    /// reaches somebody who never saw the screen, and fifty ranked rows with
    /// nothing under them read as the whole list.
    @Test("a truncated breakdown carries its caveat into the CSV")
    func breakdownExportCarriesTheCaveat() throws {
        let store = WebAnalyticsStore()
        store.rows = (0..<3).map {
            WebStatsRow(breakdownValue: "/p\($0)", visitors: Double(10 - $0), views: 20)
        }
        store.rowsAreTruncated = true
        store.rowLimit = 50

        let export = try #require(
            store.csvExports(dimension: .page).first { $0.name == WebStatsDimension.page.title }
        )
        let lines = records(export.export.data())

        // The header must still be the header — a note placed above it becomes
        // the column names in every spreadsheet that opens a .csv.
        #expect(lines.first == "Page,Visitors,Views")
        // And the caveat is the last record, where a footnote belongs and where
        // a reader who has scrolled to the end of a ranked list will meet it.
        #expect(try #require(lines.last(where: { !$0.isEmpty })).contains("Top 50"))
        // The row count names the data rows, not the note.
        #expect(export.export.rowCount == 3)
        #expect(export.export.title.contains("top 3"))
    }

    /// The untruncated case must be untouched: no note, no changed title, and a
    /// file a spreadsheet reads as three clean records.
    @Test("an untruncated breakdown exports exactly as it did")
    func breakdownExportWithoutCaveat() throws {
        let store = WebAnalyticsStore()
        store.rows = (0..<3).map {
            WebStatsRow(breakdownValue: "/p\($0)", visitors: Double(10 - $0), views: 20)
        }

        let export = try #require(
            store.csvExports(dimension: .page).first { $0.name == WebStatsDimension.page.title }
        )
        #expect(export.export.title == "Web pages")
        let lines = records(export.export.data()).filter { !$0.isEmpty }
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.components(separatedBy: ",").count == 3 })
    }

    // MARK: - Helpers

    /// Parses back what a spreadsheet would see: BOM stripped, records split.
    private func records(_ data: Data) -> [String] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.components(separatedBy: "\r\n")
    }

    private func client(_ transport: some HTTPTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: transport
        )
    }
}

/// Answers any request with a column-oriented `/query/` envelope.
///
/// Takes the rows as dictionaries keyed by column so a row with a *missing*
/// value can be expressed — which is the whole point for the timeline test,
/// where the failure being reproduced is one row that no decoder can read.
private struct RowTransport: HTTPTransport {
    let columns: [String]
    let rows: [[String: String?]]
    var hasMore: Bool?
    var limit: Int?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var object: [String: Any] = [
            "columns": columns,
            "results": rows.map { row in
                columns.map { (row[$0] ?? nil).map { $0 as Any } ?? NSNull() }
            },
        ]
        if let hasMore { object["hasMore"] = hasMore }
        if let limit { object["limit"] = limit }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (try JSONSerialization.data(withJSONObject: object), response)
    }
}

/// Answers with an `ErrorTrackingQuery` envelope: row *objects* rather than the
/// positional arrays `RowTransport` sends, because that is the shape
/// `ErrorTrackingResponse` decodes.
private struct IssueTransport: HTTPTransport {
    let count: Int
    var hasMore: Bool
    var limit: Int?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var object: [String: Any] = [
            "results": (0..<count).map { index in
                [
                    "id": "issue-\(index)",
                    "name": "SyntheticIssueFault",
                    "status": "active",
                    "aggregations": ["occurrences": 10, "sessions": 4, "users": 2],
                ] as [String: Any]
            },
            "hasMore": hasMore,
        ]
        if let limit { object["limit"] = limit }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (try JSONSerialization.data(withJSONObject: object), response)
    }
}
