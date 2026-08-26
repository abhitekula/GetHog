import Foundation

/// Current PostHog Replay Vision summary operations.
public extension PostHogAPI {
    static func generateReplayVisionSummary(
        projectID: Int,
        sessionID: String
    ) -> Endpoint {
        let payload: [String: Any] = [
            "scanner_type": "summarizer",
            "prompt": "Summarize what the user did in this session: which pages they visited, what they tried to accomplish, and any notable moments like errors, confusion, or successful completions. Be concrete and don't speculate.",
            "scanner_config": ["length": "medium"],
            "session_ids": [sessionID],
        ]
        return Endpoint(
            path: "/api/projects/\(projectID)/vision/scanners/inline_scan/",
            method: "POST",
            body: try? JSONSerialization.data(withJSONObject: payload),
            category: .query
        )
    }

    static func replayVisionObservations(
        projectID: Int,
        sessionID: String
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/vision/observations/",
            query: [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "order_by", value: "-created_at"),
                URLQueryItem(name: "limit", value: "50"),
            ],
            category: .crud
        )
    }

    static func replayVisionScannerObservations(
        projectID: Int,
        scannerID: String,
        sessionID: String
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/vision/scanners/\(scannerID)/observations/",
            query: [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "order_by", value: "-created_at"),
                URLQueryItem(name: "limit", value: "1"),
            ],
            category: .crud
        )
    }

    static func retryReplayVisionObservation(
        projectID: Int,
        observationID: String
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/vision/observations/\(observationID)/retry/",
            method: "POST",
            category: .query
        )
    }

    static func replayVisionSummaryDigests(
        projectID: Int,
        sessionIDs: [String]? = nil,
        limit: Int = 50
    ) -> Endpoint {
        let boundedLimit = min(200, max(1, limit))
        let sessionClause: String
        if let sessionIDs, !sessionIDs.isEmpty {
            let ids = sessionIDs
                .map { "'\(escape($0))'" }
                .joined(separator: ", ")
            sessionClause = "\n  AND properties.session_id IN (\(ids))"
        } else {
            sessionClause = ""
        }
        let sql = """
            SELECT
                properties.session_id AS session_id,
                argMax(properties.scanner_output_title, timestamp) AS title,
                argMax(properties.scanner_output_summary, timestamp) AS summary,
                argMax(properties.scanner_output_intent, timestamp) AS intent,
                argMax(properties.scanner_output_outcome, timestamp) AS outcome,
                argMax(properties.scanner_output_friction_points, timestamp) AS friction_points,
                argMax(properties.scanner_output_confidence, timestamp) AS confidence,
                argMax(properties.model_used, timestamp) AS model,
                max(timestamp) AS completed_at
            FROM events
            WHERE event = '$recording_observed'
              AND properties.scanner_type = 'summarizer'\(sessionClause)
            GROUP BY properties.session_id
            ORDER BY completed_at DESC
            LIMIT \(boundedLimit)
            """
        return hogql(projectID: projectID, sql: sql)
    }
}
