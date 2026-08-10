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
            request: LogsRequestDescriptor(
                authority: ResourceRequestAuthority(
                    projectID: 1,
                    region: .usCloud,
                    authSessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
                ),
                window: .day,
                search: ""
            )
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
            request: LogsRequestDescriptor(
                authority: ResourceRequestAuthority(
                    projectID: 1,
                    region: .usCloud,
                    authSessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
                ),
                window: .day,
                search: ""
            )
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
            request: LogsRequestDescriptor(
                authority: ResourceRequestAuthority(
                    projectID: 1,
                    region: .usCloud,
                    authSessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
                ),
                window: .day,
                search: ""
            )
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

// MARK: - Async resource request ownership

/// A complete synthetic HTTP reply. Test expectations below are hand-derived
/// from these immutable literals rather than decoded with production helpers.
private struct ResourceStoreReply: Sendable {
    let statusCode: Int
    let body: Data

    static func ok(_ body: String) -> Self {
        Self(statusCode: 200, body: Data(body.utf8))
    }

    static func unavailable(_ detail: String) -> Self {
        Self(
            statusCode: 503,
            body: Data(#"{"detail":"\#(detail)"}"#.utf8)
        )
    }
}

/// A real `HTTPTransport` whose held steps deliberately ignore task
/// cancellation. That makes generation ownership, rather than cooperative
/// cancellation in a test double, responsible for rejecting a late response.
private actor DelayedResourceStoreTransport: HTTPTransport {
    enum Step: Sendable {
        case immediate(ResourceStoreReply)
        case held(ResourceStoreReply)
        case cancellationAwareHeld(ResourceStoreReply)
    }

    private enum Release {
        case cancellationIgnoring(CheckedContinuation<Void, Never>)
        case cancellationAware(CheckedContinuation<Void, any Error>)
    }

    private var steps: [Step]
    private var requestCount = 0
    private var started: Set<Int> = []
    private var releases: [Int: Release] = [:]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requestCount
        requestCount += 1
        let step = try #require(steps.isEmpty ? nil : steps.removeFirst())
        let reply: ResourceStoreReply
        switch step {
        case .immediate(let value):
            reply = value
        case .held(let value):
            started.insert(index)
            await withCheckedContinuation { continuation in
                releases[index] = .cancellationIgnoring(continuation)
            }
            reply = value
        case .cancellationAwareHeld(let value):
            started.insert(index)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        releases[index] = .cancellationAware(continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancel(index) }
            }
            reply = value
        }
        return (
            reply.body,
            HTTPURLResponse(
                url: try #require(request.url),
                statusCode: reply.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func waitForRequest(
        _ index: Int,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !started.contains(index) {
            guard clock.now < deadline else {
                throw ResourceStoreTestTimeout("request \(index) did not start")
            }
            await Task.yield()
        }
    }

    func release(_ index: Int) {
        guard let release = releases.removeValue(forKey: index) else { return }
        switch release {
        case .cancellationIgnoring(let continuation): continuation.resume()
        case .cancellationAware(let continuation): continuation.resume()
        }
    }

    func observedRequestCount() -> Int {
        requestCount
    }

    private func cancel(_ index: Int) {
        guard case .cancellationAware(let continuation) = releases.removeValue(forKey: index)
        else { return }
        continuation.resume(throwing: CancellationError())
    }
}

private struct ResourceStoreTestTimeout: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// A deterministic MainActor rendezvous. `markStarted()` and the following
/// store call run without an actor hop, so a resumed test cannot race ahead of
/// the caller reaching its first suspension inside `load`.
@MainActor
private final class StoreLoadStartProbe {
    private var started = false

    func markStarted() {
        started = true
    }

    func wait(within timeout: Duration = .seconds(1)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !started {
            guard clock.now < deadline else {
                throw ResourceStoreTestTimeout("store load did not start")
            }
            await Task.yield()
        }
    }
}

private actor StoreLoadCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func completes(within timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !completed, clock.now < deadline {
            await Task.yield()
        }
        return completed
    }
}

@MainActor
private final class MutableResourceAuthority {
    var value: ResourceRequestAuthority?

    init(_ value: ResourceRequestAuthority?) {
        self.value = value
    }
}

/// Starts one store caller and bounds the wait for its continuation to resume.
/// A broken waiter path records a failed expectation instead of hanging the
/// entire selected Xcode run on `Task.value`.
@MainActor
private struct BoundedStoreLoad {
    private let task: Task<Void, Never>
    private let completion: StoreLoadCompletionProbe

    static func start(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Self {
        let completion = StoreLoadCompletionProbe()
        let task = Task { @MainActor in
            await operation()
            await completion.markCompleted()
        }
        return Self(task: task, completion: completion)
    }

    func cancel() {
        task.cancel()
    }

    func finishes(within timeout: Duration = .seconds(1)) async -> Bool {
        guard await completion.completes(within: timeout) else { return false }
        await task.value
        return true
    }
}

/// Focused tests that exercise descriptor ownership without an AppModel keep a
/// hand-derived, immutable authority current for the duration of the request.
/// Production roots do not have these overloads: they pass a live model witness.
private extension LogsStore {
    func load(
        client: PostHogClient,
        request: LogsRequestDescriptor
    ) async {
        await load(
            client: client,
            request: request,
            currentAuthority: { request.authority }
        )
    }
}

private extension TracingStore {
    func load(
        client: PostHogClient,
        request: TracingRequestDescriptor
    ) async {
        await load(
            client: client,
            request: request,
            currentAuthority: { request.authority }
        )
    }
}

private extension RendersStore {
    func load(
        client: PostHogClient,
        request: RendersRequestDescriptor
    ) async {
        await load(
            client: client,
            request: request,
            currentAuthority: { request.authority }
        )
    }
}

@Suite("Async resource request ownership")
@MainActor
struct AsyncResourceRequestOwnershipTests {
    /// Production mutation caught: removing descriptor-generation ownership
    /// lets a cancelled request for the old Logs filter overwrite the new one.
    @Test("logs reject a cancellation-ignoring response from the superseded filter")
    func logsRejectSupersededFilterResponse() async throws {
        let previousDescriptor = LogsRequestDescriptor(
            authority: Self.authority(projectID: 41),
            window: .day,
            search: "legacy"
        )
        let currentDescriptor = LogsRequestDescriptor(
            authority: Self.authority(projectID: 41),
            window: .day,
            search: "current"
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.logsReply(id: "old-log", body: "Legacy result")),
            .immediate(Self.logsReply(id: "new-log", body: "Current result")),
        ])
        let store = LogsStore()
        let client = Self.client(transport)

        store.window = previousDescriptor.window
        store.search = previousDescriptor.search
        let superseded = BoundedStoreLoad.start {
            await store.load(client: client, request: previousDescriptor)
        }
        try await transport.waitForRequest(0)

        store.search = currentDescriptor.search
        superseded.cancel()
        let current = BoundedStoreLoad.start {
            await store.load(client: client, request: currentDescriptor)
        }
        #expect(await current.finishes())
        #expect(store.rows.map(\.id) == ["new-log"])

        await transport.release(0)
        #expect(await superseded.finishes())
        #expect(store.rows.map(\.id) == ["new-log"])
    }

    /// Production mutation caught: moving filter invalidation back into the
    /// asynchronously scheduled replacement load lets an old reply publish in
    /// the gap after the visible Logs filter has already changed.
    @Test(
        "logs reject old work before a replacement task starts",
        arguments: [LogsFilterDimension.window, .search]
    )
    func logsRejectTheFilterSchedulingGap(_ dimension: LogsFilterDimension) async throws {
        let descriptor = LogsRequestDescriptor(
            authority: Self.authority(projectID: 44),
            window: .day,
            search: "original"
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.logsReply(id: "gap-log", body: "Must not publish")),
        ])
        let store = LogsStore()
        let client = Self.client(transport)
        store.window = descriptor.window
        store.search = descriptor.search

        let oldWork = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        switch dimension {
        case .window: store.window = .lastHour
        case .search: store.search = "replacement"
        }

        // No replacement load has started. Releasing here is the root's
        // `onChange { Task { ... } }` scheduling gap from the review finding.
        await transport.release(0)
        #expect(await oldWork.finishes())

        #expect(store.rows.isEmpty)
        #expect(store.loadedAt == nil)
    }

    /// Production mutation caught: deleting the live-authority guard from the
    /// Logs success publisher lets a held response cross a project, region, or
    /// authentication boundary that changed after the request was sent.
    @Test(
        "logs reject success when live authority changes",
        arguments: ResourceAuthorityDimension.allCases
    )
    func logsRejectSuccessForChangedLiveAuthority(
        _ dimension: ResourceAuthorityDimension
    ) async throws {
        let requestAuthority = Self.authority(projectID: 48)
        let liveAuthority = MutableResourceAuthority(requestAuthority)
        let descriptor = LogsRequestDescriptor(
            authority: requestAuthority,
            window: .day,
            search: ""
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.logsReply(id: "cross-authority-log", body: "Must not publish")),
        ])
        let store = LogsStore()
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport),
                request: descriptor,
                currentAuthority: { liveAuthority.value }
            )
        }
        try await transport.waitForRequest(0)

        liveAuthority.value = Self.changedAuthority(requestAuthority, dimension: dimension)
        await transport.release(0)
        #expect(await pending.finishes())

        #expect(store.rows.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: deleting the live-authority guard from the
    /// Logs error publisher exposes an obsolete request failure in the new
    /// project, region, or authentication session.
    @Test(
        "logs reject failure when live authority changes",
        arguments: ResourceAuthorityDimension.allCases
    )
    func logsRejectFailureForChangedLiveAuthority(
        _ dimension: ResourceAuthorityDimension
    ) async throws {
        let requestAuthority = Self.authority(projectID: 49)
        let liveAuthority = MutableResourceAuthority(requestAuthority)
        let descriptor = LogsRequestDescriptor(
            authority: requestAuthority,
            window: .day,
            search: ""
        )
        let transport = DelayedResourceStoreTransport([
            .held(.unavailable("Obsolete logs failure")),
        ])
        let store = LogsStore()
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport),
                request: descriptor,
                currentAuthority: { liveAuthority.value }
            )
        }
        try await transport.waitForRequest(0)

        liveAuthority.value = Self.changedAuthority(requestAuthority, dimension: dimension)
        await transport.release(0)
        #expect(await pending.finishes())

        #expect(store.rows.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: removing the equal-descriptor in-flight
    /// handle sends two identical Logs queries instead of sharing one result.
    @Test("logs coalesce concurrent requests for one descriptor")
    func logsCoalesceTheSameDescriptor() async throws {
        let descriptor = LogsRequestDescriptor(
            authority: Self.authority(projectID: 45), window: .day, search: ""
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.logsReply(id: "coalesced-log", body: "One request")),
            .held(Self.logsReply(id: "duplicate-log", body: "Must not be requested")),
        ])
        let store = LogsStore()
        let client = Self.client(transport)

        let first = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        let started = StoreLoadStartProbe()
        let second = BoundedStoreLoad.start {
            started.markStarted()
            await store.load(client: client, request: descriptor)
        }
        try await started.wait()
        let requestCount = await transport.observedRequestCount()
        for index in 0..<requestCount { await transport.release(index) }
        #expect(await first.finishes())
        #expect(await second.finishes())

        #expect(requestCount == 1)
        #expect(store.rows.map(\.id) == ["coalesced-log"])
    }

    /// Production mutation caught: making the first caller's task own the
    /// transport lets cancelling that caller throw `CancellationError` through
    /// the shared request and replace a remaining valid caller's result with a
    /// visible failure.
    @Test("logs keep a shared flight alive when its first caller cancels")
    func logsKeepSharedFlightForRemainingCaller() async throws {
        let descriptor = LogsRequestDescriptor(
            authority: Self.authority(projectID: 46), window: .day, search: ""
        )
        let transport = DelayedResourceStoreTransport([
            .cancellationAwareHeld(Self.logsReply(id: "shared-log", body: "Shared result")),
            .immediate(Self.logsReply(id: "duplicate-log", body: "Must not be requested")),
        ])
        let store = LogsStore()
        let client = Self.client(transport)
        let first = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        let secondStarted = StoreLoadStartProbe()
        let second = BoundedStoreLoad.start {
            secondStarted.markStarted()
            await store.load(client: client, request: descriptor)
        }
        try await secondStarted.wait()

        first.cancel()
        let cancelledCallerReturned = await first.finishes()
        await transport.release(0)
        #expect(await second.finishes())
        if !cancelledCallerReturned { _ = await first.finishes() }

        #expect(cancelledCallerReturned)
        #expect(await transport.observedRequestCount() == 1)
        #expect(store.rows.map(\.id) == ["shared-log"])
        #expect(store.state == .loaded)
    }

    /// Production mutation caught: awaiting the transport directly from a
    /// caller leaves a cancelled Logs load suspended forever when the real
    /// transport ignores cancellation.
    @Test("a cancelled logs waiter returns while its transport is still held")
    func cancelledLogsWaiterReturnsPromptly() async throws {
        let descriptor = LogsRequestDescriptor(
            authority: Self.authority(projectID: 47), window: .day, search: ""
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.logsReply(id: "cancelled-log", body: "Must not publish")),
        ])
        let store = LogsStore()
        let client = Self.client(transport)
        let pending = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)

        pending.cancel()
        let returnedBeforeTransport = await pending.finishes()
        await transport.release(0)
        if !returnedBeforeTransport { _ = await pending.finishes() }

        #expect(returnedBeforeTransport)
        #expect(store.rows.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: clearing Logs rows in the same-descriptor
    /// catch path turns a transient refresh outage into destructive data loss.
    @Test("logs keep same-scope rows when refresh fails")
    func logsKeepRowsAcrossRefreshFailure() async {
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.logsReply(id: "kept-log", body: "Keep this line")),
            .immediate(.unavailable("Synthetic logs refresh failed")),
        ])
        let store = LogsStore()
        let client = Self.client(transport)
        let descriptor = LogsRequestDescriptor(
            authority: Self.authority(projectID: 42),
            window: .day,
            search: ""
        )

        let baseline = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        #expect(await baseline.finishes())
        let loadedAt = store.loadedAt
        let refresh = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        #expect(await refresh.finishes())

        #expect(store.rows.map(\.id) == ["kept-log"])
        #expect(store.loadedAt == loadedAt)
        guard case .failed(let message) = store.state else {
            Issue.record("Expected a retryable Logs failure beside the carried row.")
            return
        }
        #expect(message.contains("Synthetic logs refresh failed"))
    }

    /// Production mutation caught: deferring a filter-boundary clear until
    /// after suspension leaves rows answering the old Logs question on screen.
    @Test("logs clear synchronously when filter authority changes")
    func logsClearAtFilterBoundary() async throws {
        let old = LogsRequestDescriptor(
            authority: Self.authority(projectID: 43), window: .day, search: "old"
        )
        let replacement = LogsRequestDescriptor(
            authority: Self.authority(projectID: 43), window: .lastHour, search: "old"
        )
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.logsReply(id: "old-filter-log", body: "Old filter")),
            .held(Self.logsReply(id: "new-filter-log", body: "New filter")),
        ])
        let store = LogsStore()
        let client = Self.client(transport)

        let baseline = BoundedStoreLoad.start {
            await store.load(client: client, request: old)
        }
        #expect(await baseline.finishes())
        let pending = BoundedStoreLoad.start {
            await store.load(client: client, request: replacement)
        }
        try await transport.waitForRequest(1)
        #expect(store.rows.isEmpty)
        #expect(store.loadedAt == nil)

        await transport.release(1)
        #expect(await pending.finishes())
    }

    /// Production mutation caught: removing descriptor-generation ownership
    /// lets a cancelled request for the old Tracing filter overwrite the new one.
    @Test("tracing rejects a cancellation-ignoring response from the superseded filter")
    func tracingRejectsSupersededFilterResponse() async throws {
        let previousDescriptor = TracingRequestDescriptor(
            authority: Self.authority(projectID: 51),
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let currentDescriptor = TracingRequestDescriptor(
            authority: Self.authority(projectID: 51),
            window: .day,
            service: "checkout",
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.tracingReply(traceID: "old-trace", service: "legacy")),
            .immediate(Self.tracingReply(traceID: "new-trace", service: "checkout")),
        ])
        let store = TracingStore()
        let client = Self.client(transport)

        store.window = previousDescriptor.window
        store.service = previousDescriptor.service
        let superseded = BoundedStoreLoad.start {
            await store.load(client: client, request: previousDescriptor)
        }
        try await transport.waitForRequest(0)

        store.service = currentDescriptor.service
        superseded.cancel()
        let current = BoundedStoreLoad.start {
            await store.load(client: client, request: currentDescriptor)
        }
        #expect(await current.finishes())
        #expect(store.traces.map(\.id) == ["new-trace"])

        await transport.release(0)
        #expect(await superseded.finishes())
        #expect(store.traces.map(\.id) == ["new-trace"])
    }

    /// Production mutation caught: deferring Tracing filter invalidation to a
    /// scheduled replacement task lets the old descriptor publish after any
    /// one of its four server-side filter dimensions has changed.
    @Test(
        "tracing rejects old work before a replacement task starts",
        arguments: [
            TracingFilterDimension.window,
            .service,
            .spanName,
            .errorsOnly,
        ]
    )
    func tracingRejectsTheFilterSchedulingGap(_ dimension: TracingFilterDimension) async throws {
        let descriptor = TracingRequestDescriptor(
            authority: Self.authority(projectID: 54),
            window: .day,
            service: nil,
            spanName: "original",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.tracingReply(traceID: "gap-trace", service: "worker")),
        ])
        let store = TracingStore()
        let client = Self.client(transport)
        store.window = descriptor.window
        store.service = descriptor.service
        store.spanName = descriptor.spanName
        store.errorsOnly = descriptor.errorsOnly

        let oldWork = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        switch dimension {
        case .window: store.window = .lastHour
        case .service: store.service = "replacement"
        case .spanName: store.spanName = "replacement"
        case .errorsOnly: store.errorsOnly = true
        }

        await transport.release(0)
        #expect(await oldWork.finishes())

        #expect(store.traces.isEmpty)
        #expect(store.loadedAt == nil)
    }

    /// Production mutation caught: deriving facet authority only from
    /// `currentRequest` loses provenance when a filter invalidation clears that
    /// descriptor, so a following project, region, or auth change can retain
    /// and union service names from the obsolete authority.
    @Test(
        "tracing drops service facets across filter then authority changes",
        arguments: ResourceAuthorityDimension.allCases
    )
    func tracingDropsFacetAcrossCompoundAuthorityBoundary(
        _ dimension: ResourceAuthorityDimension
    ) async throws {
        let previousAuthority = Self.authority(projectID: 58)
        let replacementAuthority = Self.changedAuthority(previousAuthority, dimension: dimension)
        let previous = TracingRequestDescriptor(
            authority: previousAuthority,
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let replacement = TracingRequestDescriptor(
            authority: replacementAuthority,
            window: .day,
            service: "shared-worker",
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.tracingFacetBaselineReply()),
            .held(Self.tracingReply(traceID: "replacement-shared", service: "shared-worker")),
        ])
        let store = TracingStore()

        let baseline = BoundedStoreLoad.start {
            await store.load(client: Self.client(transport), request: previous)
        }
        #expect(await baseline.finishes())
        #expect(store.services == ["legacy-only", "shared-worker"])

        // This filter mutation intentionally clears `currentRequest` while the
        // facet remains useful for the same authority.
        store.service = "shared-worker"
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport, region: replacementAuthority.region),
                request: replacement
            )
        }
        try await transport.waitForRequest(1)

        #expect(store.services.isEmpty)
        await transport.release(1)
        #expect(await pending.finishes())
        #expect(store.services == ["shared-worker"])
    }

    /// Production mutation caught: deleting the Tracing success publisher's
    /// live-authority guard allows old spans and service facets to cross any
    /// project, region, or authentication boundary.
    @Test(
        "tracing rejects success when live authority changes",
        arguments: ResourceAuthorityDimension.allCases
    )
    func tracingRejectsSuccessForChangedLiveAuthority(
        _ dimension: ResourceAuthorityDimension
    ) async throws {
        let requestAuthority = Self.authority(projectID: 59)
        let liveAuthority = MutableResourceAuthority(requestAuthority)
        let descriptor = TracingRequestDescriptor(
            authority: requestAuthority,
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.tracingReply(traceID: "cross-authority-trace", service: "worker")),
        ])
        let store = TracingStore()
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport),
                request: descriptor,
                currentAuthority: { liveAuthority.value }
            )
        }
        try await transport.waitForRequest(0)

        liveAuthority.value = Self.changedAuthority(requestAuthority, dimension: dimension)
        await transport.release(0)
        #expect(await pending.finishes())

        #expect(store.traces.isEmpty)
        #expect(store.services.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: deleting the Tracing error publisher's
    /// live-authority guard surfaces a stale failure after any authority
    /// dimension changes.
    @Test(
        "tracing rejects failure when live authority changes",
        arguments: ResourceAuthorityDimension.allCases
    )
    func tracingRejectsFailureForChangedLiveAuthority(
        _ dimension: ResourceAuthorityDimension
    ) async throws {
        let requestAuthority = Self.authority(projectID: 60)
        let liveAuthority = MutableResourceAuthority(requestAuthority)
        let descriptor = TracingRequestDescriptor(
            authority: requestAuthority,
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .held(.unavailable("Obsolete tracing failure")),
        ])
        let store = TracingStore()
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport),
                request: descriptor,
                currentAuthority: { liveAuthority.value }
            )
        }
        try await transport.waitForRequest(0)

        liveAuthority.value = Self.changedAuthority(requestAuthority, dimension: dimension)
        await transport.release(0)
        #expect(await pending.finishes())

        #expect(store.traces.isEmpty)
        #expect(store.services.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: removing the equal-descriptor in-flight
    /// handle sends duplicate Tracing queries and double-spends query budget.
    @Test("tracing coalesces concurrent requests for one descriptor")
    func tracingCoalescesTheSameDescriptor() async throws {
        let descriptor = TracingRequestDescriptor(
            authority: Self.authority(projectID: 55),
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.tracingReply(traceID: "coalesced-trace", service: "worker")),
            .held(Self.tracingReply(traceID: "duplicate-trace", service: "worker")),
        ])
        let store = TracingStore()
        let client = Self.client(transport)

        let first = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        let started = StoreLoadStartProbe()
        let second = BoundedStoreLoad.start {
            started.markStarted()
            await store.load(client: client, request: descriptor)
        }
        try await started.wait()
        let requestCount = await transport.observedRequestCount()
        for index in 0..<requestCount { await transport.release(index) }
        #expect(await first.finishes())
        #expect(await second.finishes())

        #expect(requestCount == 1)
        #expect(store.traces.map(\.id) == ["coalesced-trace"])
    }

    /// Production mutation caught: tying the Tracing transport to its first
    /// caller lets that caller's cancellation fail the coalesced request for a
    /// second caller that still owns the same descriptor.
    @Test("tracing keeps a shared flight alive when its first caller cancels")
    func tracingKeepsSharedFlightForRemainingCaller() async throws {
        let descriptor = TracingRequestDescriptor(
            authority: Self.authority(projectID: 56),
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .cancellationAwareHeld(Self.tracingReply(traceID: "shared-trace", service: "worker")),
            .immediate(Self.tracingReply(traceID: "duplicate-trace", service: "worker")),
        ])
        let store = TracingStore()
        let client = Self.client(transport)
        let first = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        let secondStarted = StoreLoadStartProbe()
        let second = BoundedStoreLoad.start {
            secondStarted.markStarted()
            await store.load(client: client, request: descriptor)
        }
        try await secondStarted.wait()

        first.cancel()
        let cancelledCallerReturned = await first.finishes()
        await transport.release(0)
        #expect(await second.finishes())
        if !cancelledCallerReturned { _ = await first.finishes() }

        #expect(cancelledCallerReturned)
        #expect(await transport.observedRequestCount() == 1)
        #expect(store.traces.map(\.id) == ["shared-trace"])
        #expect(store.state == .loaded)
    }

    /// Production mutation caught: a cancelled Tracing caller must unregister
    /// and return even when cancellation-ignoring network work never finishes.
    @Test("a cancelled tracing waiter returns while its transport is still held")
    func cancelledTracingWaiterReturnsPromptly() async throws {
        let descriptor = TracingRequestDescriptor(
            authority: Self.authority(projectID: 57),
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.tracingReply(traceID: "cancelled-trace", service: "worker")),
        ])
        let store = TracingStore()
        let client = Self.client(transport)
        let pending = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)

        pending.cancel()
        let returnedBeforeTransport = await pending.finishes()
        await transport.release(0)
        if !returnedBeforeTransport { _ = await pending.finishes() }

        #expect(returnedBeforeTransport)
        #expect(store.traces.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: clearing Tracing rows in the
    /// same-descriptor catch path destroys the last successful trace page.
    @Test("tracing keeps same-scope rows when refresh fails")
    func tracingKeepsRowsAcrossRefreshFailure() async {
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.tracingReply(traceID: "kept-trace", service: "worker")),
            .immediate(.unavailable("Synthetic tracing refresh failed")),
        ])
        let store = TracingStore()
        let client = Self.client(transport)
        let descriptor = TracingRequestDescriptor(
            authority: Self.authority(projectID: 52),
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )

        let baseline = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        #expect(await baseline.finishes())
        let loadedAt = store.loadedAt
        let refresh = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        #expect(await refresh.finishes())

        #expect(store.traces.map(\.id) == ["kept-trace"])
        #expect(store.loadedAt == loadedAt)
        guard case .failed(let message) = store.state else {
            Issue.record("Expected a retryable Tracing failure beside the carried trace.")
            return
        }
        #expect(message.contains("Synthetic tracing refresh failed"))
    }

    /// Production mutation caught: comparing only numeric project ids carries
    /// US tracing rows into the same-numbered EU project while replacement loads.
    @Test("tracing clears synchronously when region authority changes")
    func tracingClearsAtRegionBoundary() async throws {
        let old = TracingRequestDescriptor(
            authority: Self.authority(projectID: 53),
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let replacement = TracingRequestDescriptor(
            authority: ResourceRequestAuthority(
                projectID: 53,
                region: .euCloud,
                authSessionID: old.authority.authSessionID
            ),
            window: .day,
            service: nil,
            spanName: "",
            errorsOnly: false
        )
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.tracingReply(traceID: "us-trace", service: "us-worker")),
            .held(Self.tracingReply(traceID: "eu-trace", service: "eu-worker")),
        ])
        let store = TracingStore()

        let baseline = BoundedStoreLoad.start {
            await store.load(client: Self.client(transport), request: old)
        }
        #expect(await baseline.finishes())
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport, region: .euCloud),
                request: replacement
            )
        }
        try await transport.waitForRequest(1)
        #expect(store.traces.isEmpty)
        #expect(store.services.isEmpty)
        #expect(store.loadedAt == nil)

        await transport.release(1)
        #expect(await pending.finishes())
    }

    /// Production mutations caught: deferring the project-boundary clear keeps
    /// old rows visible while the replacement suspends, and keying publication
    /// only on task cancellation lets the old response replace the new project.
    @Test("renders clear at a project boundary and reject the superseded response")
    func rendersRejectSupersededProjectResponse() async throws {
        let previousProjectID = 61
        let currentProjectID = 62
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.rendersReply(id: 6_100, filename: "Old baseline.mp4")),
            .held(Self.rendersReply(id: 6_101, filename: "Old project.mp4")),
            .held(Self.rendersReply(id: 6_201, filename: "Current project.mp4")),
        ])
        let store = RendersStore()
        let client = Self.client(transport)
        let previousDescriptor = RendersRequestDescriptor(
            authority: Self.authority(projectID: previousProjectID)
        )
        let currentDescriptor = RendersRequestDescriptor(
            authority: Self.authority(projectID: currentProjectID)
        )

        let baseline = BoundedStoreLoad.start {
            await store.load(client: client, request: previousDescriptor)
        }
        #expect(await baseline.finishes())
        let superseded = BoundedStoreLoad.start {
            await store.load(client: client, request: previousDescriptor)
        }
        try await transport.waitForRequest(1)
        superseded.cancel()
        store.invalidate()

        // The authority observer has run, but SwiftUI has not scheduled the
        // replacement `.task(id:)` body yet. The old transport must already be
        // unable to publish in this root scheduling gap.
        await transport.release(1)
        #expect(await superseded.finishes())
        #expect(store.exports.isEmpty)
        #expect(store.loadedAt == nil)

        let replacement = BoundedStoreLoad.start {
            await store.load(client: client, request: currentDescriptor)
        }
        try await transport.waitForRequest(2)
        #expect(store.exports.isEmpty)
        #expect(store.loadedAt == nil)

        await transport.release(2)
        #expect(await replacement.finishes())
        #expect(store.exports.map(\.id) == [6_201])
    }

    /// Production mutation caught: relying on SwiftUI's authority observer
    /// lets an old render request publish after the real AppModel has signed
    /// out but before the observer or replacement task receives that mutation.
    @Test("renders revalidate the real model authority before publication")
    func rendersRevalidateRealModelAuthority() async throws {
        let model = AppModel(store: InMemoryTokenStore(), transport: DemoTransport())
        await model.enterDemo()
        let authority = try #require(Self.authority(from: model))
        let descriptor = RendersRequestDescriptor(authority: authority)
        let transport = DelayedResourceStoreTransport([
            .held(Self.rendersReply(id: 6_301, filename: "Signed out.mp4")),
        ])
        let store = RendersStore()
        let client = Self.client(transport)
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: client,
                request: descriptor,
                currentAuthority: { Self.authority(from: model) }
            )
        }
        try await transport.waitForRequest(0)

        // No store invalidation and no replacement load: this is the gap
        // between the real authority mutation and SwiftUI's next update pass.
        model.signOut()
        await transport.release(0)
        #expect(await pending.finishes())

        #expect(store.exports.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: deleting the Renders success publisher's
    /// live-authority guard permits a held export list to cross a project,
    /// region, or authentication boundary.
    @Test(
        "renders reject success when live authority changes",
        arguments: ResourceAuthorityDimension.allCases
    )
    func rendersRejectSuccessForChangedLiveAuthority(
        _ dimension: ResourceAuthorityDimension
    ) async throws {
        let requestAuthority = Self.authority(projectID: 63)
        let liveAuthority = MutableResourceAuthority(requestAuthority)
        let descriptor = RendersRequestDescriptor(authority: requestAuthority)
        let transport = DelayedResourceStoreTransport([
            .held(Self.rendersReply(id: 6_302, filename: "Must not publish.mp4")),
        ])
        let store = RendersStore()
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport),
                request: descriptor,
                currentAuthority: { liveAuthority.value }
            )
        }
        try await transport.waitForRequest(0)

        liveAuthority.value = Self.changedAuthority(requestAuthority, dimension: dimension)
        await transport.release(0)
        #expect(await pending.finishes())

        #expect(store.exports.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: deleting the Renders error publisher's
    /// live-authority guard exposes an obsolete export failure after any
    /// authority dimension changes.
    @Test(
        "renders reject failure when live authority changes",
        arguments: ResourceAuthorityDimension.allCases
    )
    func rendersRejectFailureForChangedLiveAuthority(
        _ dimension: ResourceAuthorityDimension
    ) async throws {
        let requestAuthority = Self.authority(projectID: 64)
        let liveAuthority = MutableResourceAuthority(requestAuthority)
        let descriptor = RendersRequestDescriptor(authority: requestAuthority)
        let transport = DelayedResourceStoreTransport([
            .held(.unavailable("Obsolete renders failure")),
        ])
        let store = RendersStore()
        let pending = BoundedStoreLoad.start {
            await store.load(
                client: Self.client(transport),
                request: descriptor,
                currentAuthority: { liveAuthority.value }
            )
        }
        try await transport.waitForRequest(0)

        liveAuthority.value = Self.changedAuthority(requestAuthority, dimension: dimension)
        await transport.release(0)
        #expect(await pending.finishes())

        #expect(store.exports.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    /// Production mutation caught: clearing Renders rows in the
    /// same-descriptor catch path destroys a usable library on a transient 503.
    @Test("renders keep same-scope rows when refresh fails")
    func rendersKeepRowsAcrossRefreshFailure() async {
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.rendersReply(id: 7_001, filename: "Kept render.mp4")),
            .immediate(.unavailable("Synthetic renders refresh failed")),
        ])
        let store = RendersStore()
        let client = Self.client(transport)
        let descriptor = RendersRequestDescriptor(
            authority: Self.authority(projectID: 71)
        )

        let baseline = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        #expect(await baseline.finishes())
        let loadedAt = store.loadedAt
        let refresh = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        #expect(await refresh.finishes())

        #expect(store.exports.map(\.id) == [7_001])
        #expect(store.loadedAt == loadedAt)
        guard case .failed(let message) = store.state else {
            Issue.record("Expected a retryable Renders failure beside the carried render.")
            return
        }
        #expect(message.contains("Synthetic renders refresh failed"))
    }

    /// Production mutation caught: omitting the authentication epoch carries
    /// one credential's render library into its same-project replacement.
    @Test("renders clear synchronously when authentication authority changes")
    func rendersClearAtAuthenticationBoundary() async throws {
        let old = RendersRequestDescriptor(authority: Self.authority(projectID: 72))
        let replacement = RendersRequestDescriptor(
            authority: ResourceRequestAuthority(
                projectID: 72,
                region: .usCloud,
                authSessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            )
        )
        let transport = DelayedResourceStoreTransport([
            .immediate(Self.rendersReply(id: 7_201, filename: "Old credential.mp4")),
            .held(Self.rendersReply(id: 7_202, filename: "New credential.mp4")),
        ])
        let store = RendersStore()
        let client = Self.client(transport)

        let baseline = BoundedStoreLoad.start {
            await store.load(client: client, request: old)
        }
        #expect(await baseline.finishes())
        let pending = BoundedStoreLoad.start {
            await store.load(client: client, request: replacement)
        }
        try await transport.waitForRequest(1)
        #expect(store.exports.isEmpty)
        #expect(store.loadedAt == nil)

        await transport.release(1)
        #expect(await pending.finishes())
    }

    /// Production mutation caught: removing the equal-descriptor in-flight
    /// handle issues two identical Renders list requests instead of one.
    @Test("renders coalesce concurrent requests for one descriptor")
    func rendersCoalesceTheSameDescriptor() async throws {
        let descriptor = RendersRequestDescriptor(
            authority: Self.authority(projectID: 73)
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.rendersReply(id: 7_301, filename: "Coalesced.mp4")),
            .held(Self.rendersReply(id: 7_302, filename: "Duplicate.mp4")),
        ])
        let store = RendersStore()
        let client = Self.client(transport)

        let first = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        let started = StoreLoadStartProbe()
        let second = BoundedStoreLoad.start {
            started.markStarted()
            await store.load(client: client, request: descriptor)
        }
        try await started.wait()
        let requestCount = await transport.observedRequestCount()
        for index in 0..<requestCount { await transport.release(index) }
        #expect(await first.finishes())
        #expect(await second.finishes())

        #expect(requestCount == 1)
        #expect(store.exports.map(\.id) == [7_301])
    }

    /// Production mutation caught: a shared Renders flight belongs to the
    /// store and all registered callers, not to whichever caller arrived first.
    @Test("renders keep a shared flight alive when its first caller cancels")
    func rendersKeepSharedFlightForRemainingCaller() async throws {
        let descriptor = RendersRequestDescriptor(
            authority: Self.authority(projectID: 74)
        )
        let transport = DelayedResourceStoreTransport([
            .cancellationAwareHeld(Self.rendersReply(id: 7_401, filename: "Shared.mp4")),
            .immediate(Self.rendersReply(id: 7_402, filename: "Duplicate.mp4")),
        ])
        let store = RendersStore()
        let client = Self.client(transport)
        let first = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)
        let secondStarted = StoreLoadStartProbe()
        let second = BoundedStoreLoad.start {
            secondStarted.markStarted()
            await store.load(client: client, request: descriptor)
        }
        try await secondStarted.wait()

        first.cancel()
        let cancelledCallerReturned = await first.finishes()
        await transport.release(0)
        #expect(await second.finishes())
        if !cancelledCallerReturned { _ = await first.finishes() }

        #expect(cancelledCallerReturned)
        #expect(await transport.observedRequestCount() == 1)
        #expect(store.exports.map(\.id) == [7_401])
        #expect(store.state == .loaded)
    }

    /// Production mutation caught: cancelling the only Renders waiter must
    /// return promptly and withdraw publication ownership even if the transport
    /// ignores cancellation forever.
    @Test("a cancelled renders waiter returns while its transport is still held")
    func cancelledRendersWaiterReturnsPromptly() async throws {
        let descriptor = RendersRequestDescriptor(
            authority: Self.authority(projectID: 75)
        )
        let transport = DelayedResourceStoreTransport([
            .held(Self.rendersReply(id: 7_501, filename: "Must not publish.mp4")),
        ])
        let store = RendersStore()
        let client = Self.client(transport)
        let pending = BoundedStoreLoad.start {
            await store.load(client: client, request: descriptor)
        }
        try await transport.waitForRequest(0)

        pending.cancel()
        let returnedBeforeTransport = await pending.finishes()
        await transport.release(0)
        if !returnedBeforeTransport { _ = await pending.finishes() }

        #expect(returnedBeforeTransport)
        #expect(store.exports.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.state == .loading)
    }

    private static func client(
        _ transport: some HTTPTransport,
        region: PostHogRegion = .usCloud
    ) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: region),
            transport: transport
        )
    }

    private static func authority(projectID: Int) -> ResourceRequestAuthority {
        ResourceRequestAuthority(
            projectID: projectID,
            region: .usCloud,
            authSessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
    }

    private static func changedAuthority(
        _ authority: ResourceRequestAuthority,
        dimension: ResourceAuthorityDimension
    ) -> ResourceRequestAuthority {
        switch dimension {
        case .project:
            ResourceRequestAuthority(
                projectID: authority.projectID + 1,
                region: authority.region,
                authSessionID: authority.authSessionID
            )
        case .region:
            ResourceRequestAuthority(
                projectID: authority.projectID,
                region: .euCloud,
                authSessionID: authority.authSessionID
            )
        case .authentication:
            ResourceRequestAuthority(
                projectID: authority.projectID,
                region: authority.region,
                authSessionID: UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
            )
        }
    }

    private static func authority(from model: AppModel) -> ResourceRequestAuthority? {
        guard
            let projectID = model.projectID,
            let region = model.client?.region,
            let authSessionID = model.authSessionID
        else { return nil }
        return ResourceRequestAuthority(
            projectID: projectID,
            region: region,
            authSessionID: authSessionID
        )
    }

    private static func logsReply(id: String, body: String) -> ResourceStoreReply {
        .ok(
            """
            {"columns":["uuid","timestamp","severity_text","body","service_name"],
             "results":[["\(id)","2026-08-09T12:00:00Z","info","\(body)","worker"]]}
            """
        )
    }

    private static func tracingReply(
        traceID: String,
        service: String
    ) -> ResourceStoreReply {
        .ok(
            """
            {"columns":["uuid","trace_id","span_id","parent_span_id","name",\
            "service_name","status_code","timestamp","duration_nano","is_root_span"],
             "results":[["event-\(traceID)","\(traceID)","span-\(traceID)",null,\
            "GET /synthetic","\(service)",1,"2026-08-09T12:00:00Z",12000000,true]]}
            """
        )
    }

    private static func tracingFacetBaselineReply() -> ResourceStoreReply {
        .ok(
            """
            {"columns":["uuid","trace_id","span_id","parent_span_id","name",\
            "service_name","status_code","timestamp","duration_nano","is_root_span"],
             "results":[
               ["event-shared","trace-shared","span-shared",null,"GET /shared",\
            "shared-worker",1,"2026-08-09T12:00:00Z",12000000,true],
               ["event-legacy","trace-legacy","span-legacy",null,"GET /legacy",\
            "legacy-only",1,"2026-08-09T12:00:00Z",12000000,true]
             ]}
            """
        )
    }

    private static func rendersReply(id: Int, filename: String) -> ResourceStoreReply {
        .ok(
            """
            {"count":1,"next":null,"previous":null,"results":[{
              "id":\(id),"dashboard":null,"insight":null,"export_format":"video/mp4",
              "created_at":"2026-08-09T12:00:00Z","has_content":true,
              "export_context":{"session_recording_id":"synthetic-\(id)",
                "file_size_bytes":1024,"video_duration_s":12.0},
              "filename":"\(filename)","expires_after":"2026-08-10T12:00:00Z",
              "exception":null,"user_access_level":"viewer"
            }]}
            """
        )
    }
}

enum LogsFilterDimension: Sendable {
    case window
    case search
}

enum TracingFilterDimension: Sendable {
    case window
    case service
    case spanName
    case errorsOnly
}

enum ResourceAuthorityDimension: CaseIterable, Sendable {
    case project
    case region
    case authentication
}
