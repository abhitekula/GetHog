import Foundation

/// The three surfaces that answer "what needs my attention".
///
/// Grouped because they are read the same way — a triage pass, usually not at a
/// desk — and because all three are plain CRUD listings that compute nothing,
/// so none of them bills against the `.query` budget.
///
/// All read-only. This app cannot file a task, dismiss a report or resolve a
/// health issue, and the API surface here deliberately offers no way to try.
public extension PostHogAPI {

    /// The Inbox.
    ///
    /// Every task in the project this was built against was filed by an agent —
    /// half by a scout, half from a signal report. The list embeds `latest_run`,
    /// so run state costs no extra request per row.
    ///
    /// Archived tasks are **not** reachable here. The live list returns
    /// `archived: false` for every row while the web console shows an Archive
    /// tab with its own count, so there is a parameter this client has not
    /// found. Rather than ship a tab that would always read empty, the app
    /// shows the active queue and says so.
    static func tasks(projectID: Int, limit: Int = 50) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/tasks/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// Findings surfaced by scheduled scouts.
    ///
    /// Note the path: the resource is `signals/reports`, not `signals`. A probe
    /// of `/signals/` alone answers 404, which is easy to misread as "this
    /// project has no Signals" when the reports are in fact there.
    static func signalReports(projectID: Int, limit: Int = 50) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/signals/reports/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// Instrumentation health — outdated SDKs, ingestion warnings, unauthorised
    /// URLs, Web Vitals regressions.
    static func healthIssues(projectID: Int, limit: Int = 50) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/health_issues/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}
