import Foundation

/// Server-side outcome filter for `/single_session_summaries/`.
///
/// Three server-side values. `failure` is the one that earns this screen's
/// existence: it is a ready-made "sessions worth
/// watching" list, which is the hardest thing to produce on a phone.
public enum SessionSummaryOutcomeFilter: String, Sendable, CaseIterable, Identifiable {
    case success
    case failure
    /// Summaries the model declined to judge. A real bucket, not an error one.
    case unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .success: "Succeeded"
        case .failure: "Did not finish"
        case .unknown: "Unjudged"
        }
    }
}

/// AI session summaries.
///
/// Configuration is optional server context. GetHog neither reads nor edits it
/// during generation.
public extension PostHogAPI {

    /// Starts one server-side, individually persisted replay summary.
    ///
    /// This endpoint accepts a personal API key with `session_recording:read`.
    /// Generation performs query and LLM work, so it belongs to the shared query
    /// budget rather than the CRUD budget used by stored-summary reads.
    static func generateIndividualSessionSummary(
        projectID: Int,
        sessionID: String
    ) -> Endpoint {
        let body = try? JSONSerialization.data(
            withJSONObject: ["session_ids": [sessionID]]
        )
        return Endpoint(
            path: "/api/projects/\(projectID)/session_summaries/"
                + "create_session_summaries_individually/",
            method: "POST",
            body: body,
            category: .query
        )
    }

    /// The summaries list.
    ///
    /// Filtering happens on the server for every dimension the screen offers —
    /// `outcome`, `has_exceptions`, `distinct_id`, `session_ids`, the date
    /// range — so a filter change costs one request and never a client-side
    /// scan of a page the app happens to hold.
    ///
    /// Categorised `.crud`: a listing computes nothing, and must not bill
    /// against the `.query` budget the insight screens compete for.
    static func sessionSummaries(
        projectID: Int,
        limit: Int = 50,
        offset: Int = 0,
        outcome: SessionSummaryOutcomeFilter? = nil,
        hasExceptions: Bool? = nil,
        distinctID: String? = nil,
        sessionIDs: [String]? = nil,
        dateFrom: String? = nil,
        dateTo: String? = nil,
        order: String? = nil
    ) -> Endpoint {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let outcome {
            query.append(URLQueryItem(name: "outcome", value: outcome.rawValue))
        }
        if let hasExceptions {
            query.append(URLQueryItem(name: "has_exceptions", value: hasExceptions ? "true" : "false"))
        }
        if let distinctID, !distinctID.isEmpty {
            query.append(URLQueryItem(name: "distinct_id", value: distinctID))
        }
        if let sessionIDs, !sessionIDs.isEmpty {
            // Comma-separated, and it uses the `(team, session_id)` index — the
            // cheap way to ask "which of these recordings has a summary".
            query.append(URLQueryItem(name: "session_ids", value: sessionIDs.joined(separator: ",")))
        }
        if let dateFrom { query.append(URLQueryItem(name: "date_from", value: dateFrom)) }
        if let dateTo { query.append(URLQueryItem(name: "date_to", value: dateTo)) }
        if let order { query.append(URLQueryItem(name: "order", value: order)) }

        return Endpoint(
            path: "/api/projects/\(projectID)/single_session_summaries/",
            query: query,
            category: .crud
        )
    }

    /// One session's stored summary.
    ///
    /// **Keyed by `session_id`, not by the summary record's own `id`.** Building
    /// this from the row id answers 404, which is the same response the API
    /// gives for a session that was never summarised — so the mistake would look
    /// exactly like the ordinary case and never be noticed.
    ///
    /// A 404 here is normal: most sessions in any project have no summary. See
    /// `SessionSummaryDetail.isMissingSummary`.
    static func sessionSummary(projectID: Int, sessionID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/single_session_summaries/\(sessionID)/",
            category: .crud
        )
    }
}
