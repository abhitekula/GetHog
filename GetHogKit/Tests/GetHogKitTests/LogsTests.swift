import Foundation
import Testing

@testable import GetHogKit

@Suite("Logs access state")
struct LogsStateTests {

    @Test("names a denied resource rather than reporting a malformed request")
    func deniedResourceIsNamed() {
        // The whole point: PostHog reports missing `logs` access as HTTP 400, so
        // an unnamed failure here would read as "GetHog sent a bad request"
        // and send the user hunting for a bug that does not exist.
        let state = ResourceAccessState(failure: PostHogError.accessDenied(resource: "logs"), resource: "logs", defaultScope: "logs:read")

        #expect(state == .denied(resource: "logs"))
        #expect(state.isDenied)
        #expect(state.detail(ResourceCopy(subject: "Logs", itemNoun: "log lines", emptyHint: "No log lines in this window.")).contains("logs"))
        #expect(state.detail(ResourceCopy(subject: "Logs", itemNoun: "log lines", emptyHint: "No log lines in this window.")).contains("admin"))
    }

    @Test("falls back to the logs resource when PostHog omits the name")
    func deniedFallback() {
        // The resource is scraped out of prose, so it can vanish if PostHog
        // rewords the message. Staying locked beats offering a retry that could
        // never succeed — and it must not name some other resource.
        let state = ResourceAccessState(failure: PostHogError.accessDenied(resource: nil), resource: "logs", defaultScope: "logs:read")
        #expect(state == .denied(resource: "logs"))
    }

    @Test("separates a missing key scope from a denied resource")
    func scopeIsNotDenial() {
        // Different fixes: a scope is repaired by the user editing their own API
        // key, a resource needs an organisation admin. Conflating them sends
        // someone to regenerate a key over a role problem.
        let state = ResourceAccessState(failure: PostHogError.forbidden(missingScope: "logs:read"), resource: "logs", defaultScope: "logs:read")

        #expect(state == .missingScope("logs:read"))
        #expect(state.isDenied)
        #expect(state.detail(ResourceCopy(subject: "Logs", itemNoun: "log lines", emptyHint: "No log lines in this window.")).contains("logs:read"))
    }

    @Test("treats other failures as retryable errors")
    func genericFailure() {
        let state = ResourceAccessState(failure: PostHogError.http(status: 500, detail: "boom"), resource: "logs", defaultScope: "logs:read")
        #expect(!state.isDenied)
        if case .failed = state {} else { Issue.record("expected .failed, got \(state)") }
    }

    @Test("no rows is empty, not a failure")
    func emptyIsNotFailure() {
        #expect(ResourceAccessState.resolved(rowCount: 0) == .empty)
        #expect(ResourceAccessState.resolved(rowCount: 3) == .loaded)
    }

    @Test("headlines stay short enough for ContentUnavailableView's one line")
    func headlinesAreShort() {
        // The title truncates to a single line, so qualifiers belong in `detail`.
        let states: [ResourceAccessState] = [
            .denied(resource: "logs"), .missingScope("logs:read"),
            .failed("x"), .empty, .loading, .loaded,
        ]
        #expect(states.allSatisfy { $0.headline(ResourceCopy(subject: "Logs", itemNoun: "log lines", emptyHint: "No log lines in this window.")).count <= 24 })
    }
}

@Suite("Log rows")
struct LogRowTests {

    private let payload = """
    {
      "columns": ["uuid", "timestamp", "severity_text", "body", "service_name", "trace_id"],
      "results": [
        ["01", "2026-01-28T10:00:00Z", "error", "Payment webhook failed", "billing", "abc123"],
        ["02", "2026-01-28T09:59:00Z", "INFO", "Checkout completed", "billing", "def456"]
      ]
    }
    """

    @Test("decodes rows by column name")
    func decodesRows() throws {
        let rows = LogRow.rows(from: try QueryResponse.decode(from: Data(payload.utf8)))

        #expect(rows.count == 2)
        let first = try #require(rows.first)
        #expect(first.id == "01")
        #expect(first.body == "Payment webhook failed")
        #expect(first.serviceName == "billing")
        #expect(first.traceID == "abc123")
        #expect(first.timestamp != nil)
    }

    @Test("parses severity case-insensitively")
    func severityParsing() throws {
        let rows = LogRow.rows(from: try QueryResponse.decode(from: Data(payload.utf8)))
        #expect(rows[0].severity == .error)
        #expect(rows[1].severity == .info)

        #expect(LogSeverity(text: "warning") == .warn)
        #expect(LogSeverity(text: "WARN") == .warn)
        #expect(LogSeverity(text: "critical") == .fatal)
        #expect(LogSeverity(text: "debug") == .debug)
        #expect(LogSeverity(text: nil) == .unknown)
        #expect(LogSeverity(text: "banana") == .unknown)
    }

    @Test("ranks severities so the worst sort first")
    func severityRanking() {
        let sorted = LogSeverity.allCases.sorted { $0.rank < $1.rank }
        #expect(sorted.first == .fatal)
        #expect(sorted.last == .unknown)
    }

    @Test("reads the alternative column spellings PostHog may use")
    func alternativeColumns() throws {
        // Nothing here has been seen against a real 200 — this organisation is
        // denied the resource — so both documented spellings are read rather
        // than one being picked and silently wrong.
        let json = """
        {
          "columns": ["uuid", "timestamp", "level", "message", "resource.service.name"],
          "results": [["03", "2026-01-28T10:00:00Z", "fatal", "Disk full", "worker"]]
        }
        """
        let row = try #require(LogRow.rows(from: try QueryResponse.decode(from: Data(json.utf8))).first)

        #expect(row.severity == .fatal)
        #expect(row.body == "Disk full")
        #expect(row.serviceName == "worker")
    }

    @Test("keeps rows that carry only a message, since a log line is the payload")
    func toleratesMissingMetadata() throws {
        let json = """
        {"columns": ["body"], "results": [["just a line"]]}
        """
        let rows = LogRow.rows(from: try QueryResponse.decode(from: Data(json.utf8)))

        #expect(rows.count == 1)
        #expect(rows[0].body == "just a line")
        #expect(rows[0].severity == .unknown)
        // A synthesised id keeps SwiftUI's list identity stable without a uuid.
        #expect(!rows[0].id.isEmpty)
    }

    @Test("drops rows with no message at all rather than rendering blank lines")
    func dropsEmptyRows() throws {
        let json = """
        {"columns": ["uuid", "body"], "results": [["04", null], ["05", "real"]]}
        """
        let rows = LogRow.rows(from: try QueryResponse.decode(from: Data(json.utf8)))
        #expect(rows.map(\.body) == ["real"])
    }
}

/// The copyable rendering of a single line.
///
/// Added with the log detail screen: the list truncates a message to a few
/// lines, so the detail view is the only place a long line can be read in full,
/// and "copy" is how it leaves the phone for a bug report. Pure formatting, so
/// it is tested here rather than through the view.
@Suite("Log line as text")
struct LogPlainTextTests {

    private func row(
        body: String = "Timed out after 30s",
        severity: String? = "error",
        service: String? = "checkout-api",
        trace: String? = "abc123def456789",
        timestamp: Date? = Date(timeIntervalSince1970: 1_770_000_000)
    ) -> LogRow {
        LogRow(
            id: "row-1",
            timestamp: timestamp,
            severity: LogSeverity(text: severity),
            body: body,
            serviceName: service,
            traceID: trace
        )
    }

    @Test("carries the message, severity, service and full trace id")
    func carriesEverything() {
        let text = row().plainText

        #expect(text.contains("Timed out after 30s"))
        #expect(text.contains("ERROR"))
        #expect(text.contains("checkout-api"))
        // The *full* id, not the 12-character prefix the row shows: a truncated
        // trace id cannot be pasted into a search and is worse than none.
        #expect(text.contains("abc123def456789"))
    }

    @Test("omits fields the query did not select rather than printing blanks")
    func omitsMissingFields() {
        let text = row(service: nil, trace: nil, timestamp: nil).plainText

        #expect(text.contains("Timed out after 30s"))
        #expect(!text.contains("Service:"))
        #expect(!text.contains("Trace:"))
        #expect(!text.lowercased().contains("nil"))
    }

    @Test("keeps the message on its own lines so multi-line output survives")
    func multiLineBodySurvives() {
        // Stack traces are the reason someone opens this screen; folding them
        // onto one line would defeat the detail view's whole purpose.
        let stack = "Traceback:\n  File \"a.py\", line 3\n    raise ValueError"
        let text = row(body: stack).plainText

        #expect(text.contains(stack))
    }
}
