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
    // The two failure modes are not symmetric, and that asymmetry decides it on
    // its own. A bound that is wrong in either direction — because the survey's
    // dates were edited, because responses arrived against an id before the
    // recorded `start_date`, because a project's ingestion lag straddles it —
    // drops rows *silently*: the screen renders a smaller survey than the one
    // that ran, and nothing on it says so. No bound costs a wider scan, and its
    // worst case is a query that times out, which this client raises and the
    // screen states as a failure. A results screen is also cumulative by nature:
    // it answers "what did this survey collect", not "what did it collect since
    // some date". Paying for a wide scan to keep a wrong number off the screen
    // is the trade this whole client makes, so it is made here too.
    //
    // **Unverified, and retired as a justification.** An earlier version of this
    // comment rested the same decision on a claim about PostHog's internals:
    // that PostHog rewrites `start_date` when a *stopped* survey is launched
    // again, so a `start_date` bound would drop the earlier run's responses. No
    // path that does that has been found. See `launchSurvey` and `resumeSurvey`
    // below, written from PostHog's own server source: `/launch/` does set
    // `start_date = now`, but it **refuses a survey whose `end_date` is in the
    // past** — which is every survey that was stopped — and the route that
    // actually resumes one is `PATCH {"end_date": null}`, which writes
    // `end_date` and nothing else. So the ordinary stop-then-resume cycle leaves
    // `start_date` alone.
    //
    // Be careful about how much that is worth. It is a failure to find the
    // mechanism, **not evidence against it**: it comes from reading source, not
    // from stopping a real survey, relaunching it and re-reading `start_date` —
    // which is a write, and the key this project develops against is read-only.
    // A caller who extended `end_date` into the future first would get past
    // `/launch/`'s guard and would rewrite `start_date`, so the claim is not
    // even excluded, merely unreached by the path the app offers. It is recorded
    // as unconfirmed rather than asserted in either direction, and nothing above
    // depends on it — the asymmetry is the whole argument on its own.

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

    // MARK: - Lifecycle (write)
    //
    // **Never executed.** Read out of PostHog's server source
    // (`products/surveys/backend/api/survey.py`, master, fetched 2026-07-31) and
    // its published docs; the key this project develops against is read-only, so
    // no write in this family has been sent and none of what follows is measured.
    //
    // ## There is no survey status field, so there is no status to write
    //
    // Measured (this part *is* measured, and it is a read): `GET /surveys/`
    // returns 37 keys for each of this project's six surveys and not one of them
    // is `status`. Running means `start_date` set, `end_date` unset, not
    // archived — PostHog's own `_should_survey_flags_be_active` is literally that
    // expression, and `Survey.statusText` derives the same four words the same
    // way. The four words are this app's invention; there is no server value for
    // them to disagree with. Which is why the three calls below move *dates*, and
    // why the screen's optimistic override is over a date and not over a word.
    //
    // ## The two ways to stop are not the same write
    //
    //     POST /surveys/:id/stop/    survey.save(update_fields=["end_date"])
    //                                — bypasses the serializer entirely.
    //     PATCH {"end_date": …}      runs SurveySerializerCreateUpdateOnly.update,
    //                                whose tail mirrors the survey's running state
    //                                onto targeting_flag.active and re-derives the
    //                                internal targeting flag's property filters.
    //
    // `stop/` is the one used here, deliberately, and the reason is not that it
    // is smaller but that the serializer's `update` does several other things on
    // the same request — it acts on `targeting_flag_id`, `remove_targeting_flag`,
    // `iteration_count`, and on `conditions`, where a present-but-actionless
    // value clears the survey's action associations. A one-key PATCH touches none
    // of those paths, but the *narrowest* write that cannot reach them at all is
    // the action, so that is what a phone sends.
    //
    // The price is stated rather than hidden: because `stop/` skips the
    // serializer, a stopped survey's `survey-targeting-*` flags may be left
    // reading `active: true`, where the PATCH would have deactivated them.
    // **This has not been measured and cannot be without performing a write.**
    // Corroborating read only: in this project the one launched survey has
    // `internal_targeting_flag.active: true` and all five drafts have it `false`,
    // so the mirror is real and observable — what `stop/` leaves behind is not.
    //
    // Both actions require `survey:write`.

    /// Stops a running survey.
    ///
    /// `POST /api/projects/:id/surveys/:id/stop/`, **no body**. Sets `end_date =
    /// now`. Responses already collected are kept — stopping ends collection, it
    /// does not delete anything — and the survey can be resumed afterwards.
    ///
    /// A no-op returning the current state if the survey is already stopped, and
    /// a 400 on an archived survey.
    static func stopSurvey(projectID: Int, surveyID: String) -> Endpoint {
        surveyAction(projectID: projectID, surveyID: surveyID, action: "stop")
    }

    /// Launches a draft survey.
    ///
    /// `POST /api/projects/:id/surveys/:id/launch/`, **no body**. Sets
    /// `start_date = now`, which is what makes the survey start being shown to
    /// people who match its targeting.
    ///
    /// **Refuses a survey whose `end_date` is in the past**, with *"Cannot launch
    /// a survey with end_date in the past. Extend the end_date first."* — so this
    /// is not the call that resumes a stopped survey, even though the word
    /// suggests it. `resumeSurvey` is.
    static func launchSurvey(projectID: Int, surveyID: String) -> Endpoint {
        surveyAction(projectID: projectID, surveyID: surveyID, action: "launch")
    }

    /// Resumes a stopped survey by clearing its end date.
    ///
    /// `PATCH /api/projects/:id/surveys/:id/` with `{"end_date": null}` — **one
    /// key**, and never the survey object echoed back. There is no `resume/`
    /// action on the viewset; this is the only route, and PostHog's own analytics
    /// event for the transition is `"survey resumed"`, fired when a survey that
    /// had both dates comes back with `end_date` null.
    ///
    /// The single key is the entire safety argument. This request runs
    /// `SurveySerializerCreateUpdateOnly.update()`, which on the same call would
    /// act on `targeting_flag_id`, `remove_targeting_flag`,
    /// `targeting_flag_filters`, `iteration_count` and `conditions` if they were
    /// present — and a `conditions` value carrying no `actions` clears the
    /// survey's action associations. A PATCH that helpfully echoed back the
    /// survey it had just read would walk into every one of those. Sending one
    /// key means the serializer's other branches are unreachable.
    ///
    /// Running the serializer is also the *point* here, in the one way that
    /// matters: its tail re-activates the survey's targeting flags, which is
    /// exactly what a survey going live again needs. That is the mirror image of
    /// why `stopSurvey` avoids it.
    ///
    /// There is no validation coupling `start_date` and `end_date` anywhere in
    /// the file, so a resume cannot be rejected on ordering grounds.
    static func resumeSurvey(projectID: Int, surveyID: String) -> Endpoint {
        // `JSONSerialization` with `NSNull`, not a Swift `nil`: a Swift optional
        // dropped from a dictionary literal produces `{}`, and `{}` is a PATCH
        // that changes nothing and answers 200 — the resume would silently do
        // nothing at all. The null has to reach the wire.
        let body = try? JSONSerialization.data(withJSONObject: ["end_date": NSNull()])
        return Endpoint(
            path: "/api/projects/\(projectID)/surveys/\(surveyID)/",
            method: "PATCH",
            body: body,
            category: .crud
        )
    }

    /// The two bodyless survey actions.
    ///
    /// Sends `{}` for the reason `experimentAction` does: both are declared
    /// `request=None`, DRF parses an absent body into the same empty dict, and a
    /// POST carrying a body is the only way `PostHogClient` sets a `Content-Type`
    /// header at all. Unmeasured, like everything else in this section.
    private static func surveyAction(
        projectID: Int,
        surveyID: String,
        action: String
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/surveys/\(surveyID)/\(action)/",
            method: "POST",
            body: Data("{}".utf8),
            category: .crud
        )
    }
}
