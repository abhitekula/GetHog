import Foundation
import Testing

@testable import GetHogKit

/// Request construction for error tracking, including the three writes.
///
/// **Nothing here sends anything.** `Endpoint` is an inert value — a path, a
/// method and a body — so a write's shape can be pinned without a project ever
/// hearing about it. That is the whole reason these assertions are on the
/// endpoint rather than on a round trip: a deterministic unit test must not
/// mutate any remote triage queue.
///
/// Modelled on `APITests.flagToggle`, which pins the app's only other write the
/// same way.
@Suite("Error tracking endpoints")
struct ErrorTrackingAPITests {

    private func body(_ endpoint: Endpoint) throws -> String {
        String(decoding: try #require(endpoint.body), as: UTF8.self)
    }

    // MARK: - Reads

    @Test("scopes the stack-trace query to one issue and bounds it in time")
    func occurrenceQuery() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let endpoint = PostHogAPI.errorIssueOccurrence(
            projectID: 1,
            issueID: "018f3300-0000-7000-8000-000000000901",
            within: start...start.addingTimeInterval(86_400)
        )

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1/query/")
        #expect(endpoint.category == .query)

        let sql = try body(endpoint)
        #expect(sql.contains("018f3300-0000-7000-8000-000000000901"))
        #expect(sql.contains("$exception_issue_id"))
        // Bounded, for the reason the events feed and the session timeline both
        // are: the issue filter alone does not bound the event scan.
        #expect(sql.contains("timestamp >"))
        #expect(sql.contains("timestamp <"))
        #expect(sql.contains("LIMIT 1"))

        // Aliased, because a `QueryRow` lookup keyed on `$exception_list` is far
        // easier to typo than to notice. The endpoint contract names these six
        // columns explicitly.
        for column in ["uuid", "timestamp", "exception_list", "level", "fingerprint", "steps"] {
            #expect(sql.contains("AS \(column)"), "missing alias \(column)")
        }
    }

    @Test("escapes an issue id rather than pasting it into the SQL")
    func occurrenceQueryEscapesIssueID() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let endpoint = PostHogAPI.errorIssueOccurrence(
            projectID: 1,
            issueID: "abc' OR '1'='1",
            within: start...start.addingTimeInterval(60)
        )
        let sql = try body(endpoint)
        #expect(sql.contains(#"abc\\' OR \\'1\\'=\\'1"#))
        // The bare, unescaped form must not survive anywhere in the statement.
        #expect(!sql.contains("= 'abc' OR"))
    }

    /// Padding is a safety rail, not a filter: `$exception_issue_id` already
    /// decides membership, and client clocks disagree with the server's. Same
    /// reasoning as `sessionEvents`.
    @Test("pads the window so a client clock skew doesn't hide the only event")
    func occurrenceQueryPadsWindow() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let endpoint = PostHogAPI.errorIssueOccurrence(
            projectID: 1,
            issueID: "i",
            within: start...start
        )
        let sql = try body(endpoint)
        #expect(sql.contains(PostHogAPI.sqlTimestamp(start.addingTimeInterval(-3600))))
        #expect(sql.contains(PostHogAPI.sqlTimestamp(start.addingTimeInterval(3600))))
    }

    // MARK: - Writes
    //
    // Paths and bodies below come from PostHog's OpenAPI document
    // (`GET /api/schema/?format=json`, fetched 2026-07-30). None has been sent.

    @Test("resolves an issue with a PATCH carrying only the status field")
    func resolveIssue() throws {
        let endpoint = PostHogAPI.setErrorIssueStatus(
            projectID: 1_001,
            issueID: "018f3300-0000-7000-8000-000000000901",
            status: .resolved
        )

        #expect(endpoint.method == "PATCH")
        #expect(
            endpoint.path
                == "/api/projects/1001/error_tracking/issues/018f3300-0000-7000-8000-000000000901/"
        )
        #expect(endpoint.category == .crud)

        let json = try body(endpoint)
        #expect(json.contains("\"status\":\"resolved\""))
        // Only `status`. `PatchedErrorTrackingIssueWrite` also accepts `name` and
        // `description`, and a PATCH that carries fields nobody edited can
        // overwrite someone else's edit with a stale copy of it — the same
        // reason `setFlagActive` sends `active` alone.
        #expect(!json.contains("\"name\""))
        #expect(!json.contains("\"description\""))
    }

    @Test("suppresses and reopens through the same endpoint")
    func suppressAndReopen() throws {
        let suppress = PostHogAPI.setErrorIssueStatus(projectID: 1, issueID: "i", status: .suppressed)
        #expect(suppress.method == "PATCH")
        #expect(suppress.path == "/api/projects/1/error_tracking/issues/i/")
        #expect(try body(suppress).contains("\"status\":\"suppressed\""))

        let reopen = PostHogAPI.setErrorIssueStatus(projectID: 1, issueID: "i", status: .active)
        #expect(try body(reopen).contains("\"status\":\"active\""))
    }

    /// The write enum is narrower than the read enum on purpose. PostHog reports
    /// five statuses; `ErrorTrackingIssueWriteStatusEnum` accepts three, and the
    /// PATCH body's own description says *"Deprecated archived and
    /// pending_release values are rejected."*
    @Test("cannot express a status PostHog documents that it refuses")
    func writableStatusesExcludeTheDeprecatedTwo() {
        #expect(ErrorIssueStatus.allCases.map(\.rawValue) == ["active", "resolved", "suppressed"])
        #expect(ErrorIssueStatus(rawValue: "archived") == nil)
        #expect(ErrorIssueStatus(rawValue: "pending_release") == nil)

        // …but an issue already in one of them still displays as itself.
        #expect(ErrorIssueReadStatus(rawValue: "archived")?.title == "Archived")
        #expect(ErrorIssueReadStatus(rawValue: "pending_release")?.title == "Pending release")
    }

    /// Suppression is the only triage action that changes what the project
    /// *stores*: PostHog documents that "suppressing an issue will drop any
    /// associated exceptions", and dropped events are unbilled events. The flag
    /// is what keeps it out of swipe actions and gives it its own dialog.
    @Test("marks suppression as the destructive one and says why")
    func suppressionIsFlaggedDestructive() {
        #expect(ErrorIssueStatus.suppressed.isDestructive)
        #expect(!ErrorIssueStatus.resolved.isDestructive)
        #expect(!ErrorIssueStatus.active.isDestructive)

        #expect(ErrorIssueStatus.suppressed.consequence.contains("drop"))
        // Resolve's surprise runs the other way, and someone resolving an issue
        // from a phone should know it can come back on its own.
        #expect(ErrorIssueStatus.resolved.consequence.contains("reopens itself"))
    }

    @Test("assigns to a user with an integer id on the assign sub-resource")
    func assignToUser() throws {
        let endpoint = PostHogAPI.assignErrorIssue(
            projectID: 1_001,
            issueID: "harbor-issue-a",
            assignee: .user(710_001)
        )

        #expect(endpoint.method == "PATCH")
        #expect(endpoint.path == "/api/projects/1001/error_tracking/issues/harbor-issue-a/assign/")
        #expect(endpoint.category == .crud)

        let json = try body(endpoint)
        // The id keeps its JSON type. A quoted identifier is a different value
        // to an integer, and a successful status would hide the difference.
        #expect(json.contains("\"id\":710001"))
        #expect(!json.contains("\"710001\""))
        #expect(json.contains("\"type\":\"user\""))
    }

    /// PostHog assigns to roles as well as people — "assign issues to specific
    /// PostHog roles or teammates" — and a role id is a uuid string where a user
    /// id is an integer.
    @Test("assigns to a role with a string id")
    func assignToRole() throws {
        let endpoint = PostHogAPI.assignErrorIssue(
            projectID: 1,
            issueID: "i",
            assignee: ErrorIssueAssignee(
                identifier: .text("018f3300-0000-7000-8000-000000000999"),
                kind: .role
            )
        )
        let json = try body(endpoint)
        #expect(json.contains("\"id\":\"018f3300-0000-7000-8000-000000000999\""))
        #expect(json.contains("\"type\":\"role\""))
    }

    @Test("unassigns by sending an explicit null")
    func unassign() throws {
        let endpoint = PostHogAPI.assignErrorIssue(projectID: 1, issueID: "i", assignee: nil)
        let json = try body(endpoint)
        // Explicitly `null`, not an omitted key: PATCH treats a missing field as
        // "leave it alone", which would silently do nothing.
        #expect(json.contains("\"assignee\":null"))
    }

    @Test("round-trips an assignee through the shape PostHog returns")
    func assigneeDecoding() throws {
        let user = try JSONDecoder().decode(
            ErrorIssueAssignee.self,
            from: Data(#"{"id":710001,"type":"user"}"#.utf8)
        )
        #expect(user.identifier == .number(710_001))
        #expect(user.kind == .user)

        let role = try JSONDecoder().decode(
            ErrorIssueAssignee.self,
            from: Data(#"{"id":"018f3300-0000-7000-8000-000000000999","type":"role"}"#.utf8)
        )
        #expect(role.identifier == .text("018f3300-0000-7000-8000-000000000999"))
        #expect(role.kind == .role)
    }
}
