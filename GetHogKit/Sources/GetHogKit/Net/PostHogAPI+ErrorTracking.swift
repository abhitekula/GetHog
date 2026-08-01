import Foundation

public extension PostHogAPI {

    // MARK: - Stack traces (read)

    /// The newest `$exception` occurrence belonging to one issue, with its
    /// `$exception_list`.
    ///
    /// **Why a HogQL query and not the issue endpoint.** `GET
    /// /api/projects/:id/error_tracking/issues/:issue_id/` returns issue
    /// metadata, not exception frames. Frames live on the events, so the events
    /// are what this asks for.
    ///
    /// **Why `within` is required and has no default.** Same rule the events feed
    /// and the session timeline both had to learn: an unbounded `FROM events`
    /// denies ClickHouse partition pruning on a shared table. The issue filter
    /// alone does not bound the scan, so the window is part of the signature
    /// rather than an option on it.
    ///
    /// Callers pass the issue's own `firstSeen…lastSeen`; the padding below is a
    /// safety rail for client clocks that disagree with the server's, exactly as
    /// on `sessionEvents`.
    ///
    /// `$exception_issue_id` is a materialised column (`mat_$exception_issue_id`
    /// appears in the server's own rewritten SQL), so filtering on it is an
    /// equality test rather than a JSON extraction over every row in the window.
    static func errorIssueOccurrence(
        projectID: Int,
        issueID: String,
        within window: ClosedRange<Date>
    ) -> Endpoint {
        let padding: TimeInterval = 3600
        let from = window.lowerBound.addingTimeInterval(-padding)
        let to = window.upperBound.addingTimeInterval(padding)
        // Named columns rather than the bare property expressions: PostHog aliases
        // `properties.$exception_list` to the literal column name
        // `$exception_list`, and a `QueryRow` lookup keyed on a `$`-prefixed
        // string is a lot easier to typo than to notice.
        //
        // `$exception_steps` is selected even though it is optional. It costs
        // nothing when absent, and the alternative — a second query when an SDK
        // starts emitting breadcrumbs — costs a round trip on the screen that
        // most needs to be fast.
        let sql = """
            SELECT uuid AS uuid,
                   timestamp AS timestamp,
                   properties.$exception_list AS exception_list,
                   properties.$exception_level AS level,
                   properties.$exception_fingerprint AS fingerprint,
                   properties.$exception_steps AS steps
            FROM events
            WHERE event = '$exception'
              AND properties.$exception_issue_id = '\(escape(issueID))'
              AND timestamp > toDateTime64('\(sqlTimestamp(from))', 6)
              AND timestamp < toDateTime64('\(sqlTimestamp(to))', 6)
            ORDER BY timestamp DESC
            LIMIT 1
            """
        return hogql(projectID: projectID, sql: sql)
    }

    // MARK: - Triage (write)
    //
    // Everything below mutates shared state in a real project. They follow the
    // shape `setFlagActive` established — the app's only other write — and are
    // reached the same way: from a detail screen, behind a confirmation dialog,
    // applied optimistically and rolled back on failure. Nothing in this file
    // asks the user anything; see `ErrorTriageController`.
    //
    // The paths and body shapes below were read out of PostHog's own OpenAPI
    // document (`GET https://us.posthog.com/api/schema/?format=json`), not
    // guessed or inferred from tenant responses.

    /// Resolve, suppress, or reopen an issue.
    ///
    /// `PATCH /api/projects/:id/error_tracking/issues/:issue_id/` with a body
    /// carrying `status` alone. The document's `PatchedErrorTrackingIssueWrite`
    /// schema has three writable properties — `status`, `name`, `description` —
    /// and only `status` is sent, for the reason `setFlagActive` sends only
    /// `active`: a PATCH that carries fields nobody edited can overwrite someone
    /// else's edit with a stale copy of it.
    ///
    /// Needs `error_tracking:write` on the personal API key. A read-scoped key
    /// passes every preflight probe and fails only here, which is why the
    /// failure path names the scope.
    static func setErrorIssueStatus(
        projectID: Int,
        issueID: String,
        status: ErrorIssueStatus
    ) -> Endpoint {
        let body = try? JSONSerialization.data(withJSONObject: ["status": status.rawValue])
        return Endpoint(
            path: "/api/projects/\(projectID)/error_tracking/issues/\(issueID)/",
            method: "PATCH",
            body: body,
            category: .crud
        )
    }

    /// Assign an issue to a user or a role, or clear the assignment.
    ///
    /// `PATCH /api/projects/:id/error_tracking/issues/:issue_id/assign/` — a
    /// sub-resource of its own rather than a field on the issue PATCH above.
    /// `assignee` is `{"id": …, "type": "user"|"role"}`, or JSON `null` to
    /// unassign.
    ///
    /// The id keeps its JSON type: a user id is an integer and a role id is a
    /// UUID string. `ErrorTrackingIssueAssignee.id` is `anyOf: [string,
    /// integer]` in the schema, and `ErrorTrackingQuery` splits the same fact
    /// across two columns — `assignee_user_id` and `assignee_role_id`.
    ///
    /// The `assign` action is a DRF `@action`, and drf-spectacular documents its
    /// body with the *read*
    /// serializer — `PatchedErrorTrackingIssueRead`, whose `assignee` is
    /// `readOnly` — which cannot be what it accepts. The `{id, type}` shape here
    /// is taken from `ErrorTrackingIssueAssignee`, the schema PostHog defines
    /// for exactly this object and does not use anywhere in a read response. It
    /// is therefore encoded using the dedicated assignee schema rather than the
    /// read serializer.
    static func assignErrorIssue(
        projectID: Int,
        issueID: String,
        assignee: ErrorIssueAssignee?
    ) -> Endpoint {
        let payload: [String: Any] = ["assignee": assignee?.jsonBody ?? NSNull()]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        return Endpoint(
            path: "/api/projects/\(projectID)/error_tracking/issues/\(issueID)/assign/",
            method: "PATCH",
            body: body,
            category: .crud
        )
    }
}
