import Foundation

/// Server-side outcome filter for `/single_session_summaries/`.
///
/// Three values, all verified against the live endpoint. `failure` is the one
/// that earns this screen's existence: it is a ready-made "sessions worth
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
/// **Read-only, deliberately.** Generation is a write
/// (`POST /session_summaries/create_session_summaries/`) and
/// `/session_summaries/config/` is PAT-incompatible, so a phone can never do
/// the whole loop. What it *can* do is read what someone else generated, which
/// is the half that actually suits a small screen: "did this session go wrong,
/// and where" beats scrubbing a video on a phone.
public extension PostHogAPI {

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
