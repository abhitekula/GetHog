import Foundation

/// The two HogQL queries a survey's results are read with.
///
/// Generated rather than fixed, because the answer columns are one per question
/// and a question's answers live under a key built from its own id. The SQL is
/// exposed so tests can pin the exact text — a query this app builds from a
/// server payload is a query that can silently drift.
///
/// Both were run against project [REMOVED PRIVATE DATA] on 2026-07-30 before any of this was
/// written; the shapes they returned are recorded in
/// `Fixtures/survey_results_summary.json` and `Fixtures/survey_answers.json`.
public struct SurveyResultsQuery: Sendable {
    public let survey: Survey

    /// Enough rows to summarise a real survey on a phone without asking
    /// ClickHouse for an unbounded scan. `SurveyResults.isTruncated` reports
    /// when this bit.
    public static let responseLimit = 500

    // Deliberately no date filter, on either query.
    //
    // Bounding the scan by the survey's `start_date` would be cheaper and is
    // wrong: PostHog rewrites `start_date` when a stopped survey is launched
    // again, so the bound would silently drop every response from the earlier
    // run and the screen would report a smaller survey than the one that ran.
    // A results screen is cumulative by nature. If the scan is too wide for a
    // busy project the query times out, which reaches the reader as a stated
    // failure rather than as a quietly short number.

    /// Every event that can carry a survey outcome. `survey abandoned` is newer
    /// than the SDK this was measured against and never appears in that
    /// project's data — it is here so a project on a newer SDK is not silently
    /// under-counted.
    static let outcomeEvents = ["survey sent", "survey dismissed", "survey abandoned"]

    public init(survey: Survey) {
        self.survey = survey
    }

    /// Impressions, responses, dismissals — counted over distinct submissions,
    /// not over rows.
    ///
    /// `uniqIf(coalesce($survey_submission_id, uuid))` rather than `countIf`:
    /// PostHog can emit one event per answered question, all sharing a
    /// submission id, and bills per unique id. Older events carry no submission
    /// id at all, so the event's own uuid stands in — one event, one submission,
    /// which is exactly what those events meant.
    public var summarySQL: String {
        let id = PostHogAPI.escape(survey.id)
        return """
        SELECT
            countIf(event = 'survey shown') AS impressions,
            uniqIf(\(Self.submissionKey), event = 'survey sent') AS responses,
            countIf(event = 'survey dismissed') AS dismissals,
            countIf(event = 'survey abandoned') AS abandonments,
            uniqIf(\(Self.submissionKey), event IN ('survey dismissed', 'survey abandoned') AND properties.$survey_partially_completed) AS partials,
            min(timestamp) AS first_seen,
            max(timestamp) AS last_seen
        FROM events
        WHERE event IN ('survey shown', 'survey sent', 'survey dismissed', 'survey abandoned')
          AND properties.$survey_id = '\(id)'
        """
    }

    /// One row per outcome event, one column per question.
    ///
    /// Reads answers through `getSurveyResponse` rather than
    /// `properties['$survey_response_<id>']` directly. Both work — they were
    /// compared side by side and returned identical values — but the helper also
    /// resolves the positional keys older SDKs wrote, so it is the accessor that
    /// keeps working on a survey older than per-question ids.
    public var answersSQL: String {
        let id = PostHogAPI.escape(survey.id)
        let columns = survey.questions.enumerated().map { index, question in
            "    \(Self.accessor(for: question, index: index)) AS q\(index)"
        }
        let selection = ([
            "    \(Self.submissionKey) AS submission",
            "    timestamp",
            "    event",
        ] + columns).joined(separator: ",\n")

        return """
        SELECT
        \(selection)
        FROM events
        WHERE event IN ('survey sent', 'survey dismissed', 'survey abandoned')
          AND properties.$survey_id = '\(id)'
        ORDER BY timestamp DESC
        LIMIT \(Self.responseLimit)
        """
    }

    private static let submissionKey =
        "coalesce(nullIf(properties.$survey_submission_id, ''), toString(uuid))"

    /// The accessor for one question.
    ///
    /// The multi-select flag is not cosmetic. `getSurveyResponse(i, id, true)`
    /// compiles to `JSONExtractArrayRaw`, which returns `[]` — not an error —
    /// when the stored value is a plain string. Passing `true` for a
    /// single-choice question therefore drops every answer silently, so the flag
    /// tracks the question's declared type and nothing else.
    static func accessor(for question: SurveyQuestion, index: Int) -> String {
        let multi = question.kind.isMultiSelect
        guard let id = question.id, !id.isEmpty else {
            // No per-question id: the helper falls back to the positional key.
            // The three-argument form still needs a placeholder in the id slot,
            // and NULL is accepted there.
            return multi
                ? "getSurveyResponse(\(index), NULL, true)"
                : "getSurveyResponse(\(index))"
        }
        let escaped = PostHogAPI.escape(id)
        return multi
            ? "getSurveyResponse(\(index), '\(escaped)', true)"
            : "getSurveyResponse(\(index), '\(escaped)')"
    }
}

public extension PostHogAPI {
    /// Impressions, responses and dismissals for one survey.
    static func surveyResultsSummary(projectID: Int, survey: Survey) -> Endpoint {
        hogql(projectID: projectID, sql: SurveyResultsQuery(survey: survey).summarySQL)
    }

    /// Every submission that carries an answer, newest first.
    static func surveyResponses(projectID: Int, survey: Survey) -> Endpoint {
        hogql(projectID: projectID, sql: SurveyResultsQuery(survey: survey).answersSQL)
    }
}
