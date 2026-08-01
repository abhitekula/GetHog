import Foundation
import Testing

@testable import GetHogKit

// These fixtures form one fictional survey dataset with fixed February 2026 dates.
// The summary, definitions, submissions, and answer keys deliberately cross-link
// so aggregation tests exercise the same contracts as a real response without
// carrying any captured workspace values.

private enum SurveyFixture {
    static func dashboardFeedback() throws -> Survey {
        let page = try Page<Survey>.decode(
            from: Fixture.data("survey_definition_dashboard_feedback.json")
        )
        #expect(page.results.count == 2)
        return try #require(page.results.first)
    }

    static func syntheticNPS() throws -> Survey {
        let page = try Page<Survey>.decode(from: Fixture.data("survey_definition_synthetic_nps.json"))
        #expect(page.results.count == 2)
        return try #require(page.results.first)
    }

    static func summary() throws -> QueryResponse {
        try QueryResponse.decode(from: Fixture.data("survey_results_summary.json"))
    }

    static func answers() throws -> QueryResponse {
        try QueryResponse.decode(from: Fixture.data("survey_answers.json"))
    }

    static func syntheticAnswers() throws -> QueryResponse {
        try QueryResponse.decode(from: Fixture.data("survey_answers_synthetic_nps.json"))
    }
}

@Suite("Survey question definitions")
struct SurveyQuestionDefinitionTests {

    @Test("decodes the fields a rating question needs to be aggregated at all")
    func decodesRatingFields() throws {
        let survey = try SurveyFixture.dashboardFeedback()
        let rating = try #require(survey.questions.first { $0.kind == .rating })

        #expect(survey.questions.count == 6)
        #expect(rating.id == "q-satisfaction")
        #expect(rating.scale == 5)
        #expect(rating.display == "emoji")
        #expect(rating.lowerBoundLabel == "Very difficult synthetic fixture 25")
        #expect(rating.upperBoundLabel == "Very easy synthetic fixture 26")
    }

    @Test("reads the optional flag, so a thin answer count isn't misread as drop-off")
    func decodesOptional() throws {
        let survey = try SurveyFixture.dashboardFeedback()
        #expect(survey.questions[4].isOptional == true)
        #expect(survey.questions[1].isOptional == false)
    }

    @Test("maps every question type this project uses, and keeps unknown ones nameable")
    func mapsKinds() throws {
        let survey = try SurveyFixture.dashboardFeedback()
        #expect(survey.questions.map(\.kind) == [.singleChoice, .open, .open, .rating, .open, .open])
        #expect(SurveyQuestionKind(rawType: "sculpture") == .unsupported("sculpture"))
        #expect(SurveyQuestionKind(rawType: nil) == .unsupported("unknown"))
    }

    @Test("only multiple choice reads as multi-select")
    func multiSelect() {
        #expect(SurveyQuestionKind.multipleChoice.isMultiSelect)
        #expect(!SurveyQuestionKind.singleChoice.isMultiSelect)
        #expect(!SurveyQuestionKind.rating.isMultiSelect)
    }
}

@Suite("Survey results HogQL")
struct SurveyResultsQueryTests {

    @Test("counts distinct submissions, not events, so a split submission counts once")
    func summaryDedupes() throws {
        let sql = SurveyResultsQuery(survey: try SurveyFixture.dashboardFeedback()).summarySQL

        #expect(sql.contains("uniqIf(coalesce(nullIf(properties.$survey_submission_id, ''), toString(uuid)), event = 'survey sent') AS responses"))
        #expect(!sql.contains("countIf(event = 'survey sent')"))
        #expect(sql.contains("properties.$survey_id = 'survey-demo-feedback-2026'"))
    }

    @Test("counts abandonments separately from dismissals")
    func summaryCoversAbandoned() throws {
        let sql = SurveyResultsQuery(survey: try SurveyFixture.dashboardFeedback()).summarySQL
        #expect(sql.contains("countIf(event = 'survey abandoned') AS abandonments"))
        #expect(sql.contains("event IN ('survey shown', 'survey sent', 'survey dismissed', 'survey abandoned')"))
    }

    @Test("selects one column per question, keyed on the question's own id")
    func answersColumns() throws {
        let sql = SurveyResultsQuery(survey: try SurveyFixture.dashboardFeedback()).answersSQL

        #expect(sql.contains("getSurveyResponse(0, 'q-feedback-topic') AS q0"))
        #expect(sql.contains("getSurveyResponse(3, 'q-satisfaction') AS q3"))
        #expect(sql.contains("getSurveyResponse(4, 'q-note') AS q4"))
        #expect(sql.contains("LIMIT 500"))
    }

    @Test("reads dismissals too — that is where partial answers arrive")
    func answersIncludeDismissals() throws {
        let sql = SurveyResultsQuery(survey: try SurveyFixture.dashboardFeedback()).answersSQL
        #expect(sql.contains("event IN ('survey sent', 'survey dismissed', 'survey abandoned')"))
    }

    @Test("passes the array flag only for multiple choice")
    func multiSelectAccessor() throws {
        let survey = try SurveyFixture.syntheticNPS()
        #expect(survey.questions.count == 4)
        let sql = SurveyResultsQuery(survey: survey).answersSQL

        // The rating and open questions must NOT ask for an array:
        // JSONExtractArrayRaw over a scalar returns [] and loses every answer.
        #expect(sql.contains("getSurveyResponse(0, 'q-nps') AS q0"))
        #expect(sql.contains("getSurveyResponse(1, 'q-resources', true) AS q1"))
        #expect(sql.contains("getSurveyResponse(2, 'q-comment') AS q2"))
    }

    @Test("falls back to the positional accessor when a question has no id")
    func positionalAccessor() {
        let plain = SurveyQuestion(type: "open", question: "Why?")
        let multi = SurveyQuestion(type: "multiple_choice", question: "Which?")

        #expect(SurveyResultsQuery.accessor(for: plain, index: 2) == "getSurveyResponse(2)")
        #expect(SurveyResultsQuery.accessor(for: multi, index: 3) == "getSurveyResponse(3, NULL, true)")
    }

    @Test("escapes an id rather than pasting it into a string literal")
    func escapesID() {
        let question = SurveyQuestion(id: "it's-a-trap", type: "open")
        #expect(SurveyResultsQuery.accessor(for: question, index: 0) == "getSurveyResponse(0, 'it\\'s-a-trap')")
    }
}

@Suite("Survey results summary")
struct SurveyResultsSummaryTests {

    @Test("reads the fictional feedback funnel")
    func decodesSummary() throws {
        let response = try SurveyFixture.summary()
        #expect(response.rows.count == 2)
        let summary = SurveyResultsSummary.decode(from: response)

        #expect(summary.impressions == 37)
        #expect(summary.responses == 2)
        #expect(summary.dismissals == 9)
        #expect(summary.abandonments == 4)
        #expect(summary.partials == 2)
        #expect(summary.answeringSubmissions == 4)
    }

    @Test("a rate with no impressions is unknown, not zero")
    func rateNeedsDenominator() {
        let empty = SurveyResultsSummary(
            impressions: 0, responses: 0, partials: 0, dismissals: 0, abandonments: 0
        )
        #expect(empty.responseRate == nil)
        #expect(empty.dismissalRate == nil)
        #expect(empty.isEmpty)
    }

    @Test("converts counts into rates")
    func rates() throws {
        let summary = SurveyResultsSummary.decode(from: try SurveyFixture.summary())
        let response = try #require(summary.responseRate)
        let dismissal = try #require(summary.dismissalRate)

        #expect(abs(response - 2.0 / 37.0) < 0.0001)
        #expect(abs(dismissal - 9.0 / 37.0) < 0.0001)
    }

    @Test("carries the window the events actually span")
    func window() throws {
        let summary = SurveyResultsSummary.decode(from: try SurveyFixture.summary())
        let first = try #require(summary.firstSeen)
        let last = try #require(summary.lastSeen)
        #expect(first < last)
    }
}

@Suite("Survey submissions")
struct SurveySubmissionTests {

    @Test("reads every submission that carries an answer, complete or not")
    func decodesSubmissions() throws {
        let survey = try SurveyFixture.dashboardFeedback()
        let submissions = SurveyResults.decodeSubmissions(
            survey: survey, response: try SurveyFixture.answers()
        )

        #expect(submissions.count == 9)
        let answering = submissions.filter { !$0.answers.isEmpty }
        #expect(answering.count == 4)
        #expect(answering.filter(\.isComplete).count == 2)
    }

    @Test("a rating arrives as a string and is read as a number")
    func ratingIsStringOnTheWire() throws {
        let survey = try SurveyFixture.dashboardFeedback()
        let submissions = SurveyResults.decodeSubmissions(
            survey: survey, response: try SurveyFixture.answers()
        )
        let complete = try #require(submissions.first { $0.isComplete })

        #expect(complete.answers["q-satisfaction"] == .rating(5))
        #expect(complete.answers["q-feedback-topic"] == .choice("Account help"))
    }

    @Test("unwraps raw JSON elements out of a multi-select answer")
    func multiSelectElements() throws {
        let survey = try SurveyFixture.syntheticNPS()
        let response = try SurveyFixture.syntheticAnswers()
        #expect(response.rows.count == 8)
        let submissions = SurveyResults.decodeSubmissions(
            survey: survey, response: response
        )
        let first = try #require(submissions.first)

        #expect(first.answers["q-resources"] == .choices(["Star maps", "Orbit examples"]))
    }

    @Test("unwrapping survives an element that isn't quoted JSON")
    func unwrapFallback() {
        #expect(SurveyAnswer.unwrapRawJSON("\"Docs\"") == "Docs")
        #expect(SurveyAnswer.unwrapRawJSON("\"a \\\"b\\\" c\"") == "a \"b\" c")
        #expect(SurveyAnswer.unwrapRawJSON("Docs") == "Docs")
        #expect(SurveyAnswer.unwrapRawJSON("\"unterminated") == "unterminated")
    }

    @Test("merges events that share a submission id into one submission")
    func mergesSplitSubmission() throws {
        // The per-question `survey sent` fan-out can produce multiple events for
        // one response, so this authored edge case protects the merge contract.
        let survey = Survey.stub(questions: [
            SurveyQuestion(id: "a", type: "open", question: "First"),
            SurveyQuestion(id: "b", type: "rating", question: "Second", scale: 5),
        ])
        let response = QueryResponse.stub(
            columns: ["submission", "timestamp", "event", "q0", "q1"],
            rows: [
                ["sub-1", "2025-12-16T10:00:00Z", "survey sent", NSNull(), "4"],
                ["sub-1", "2025-12-16T09:00:00Z", "survey sent", "hello", NSNull()],
            ]
        )

        let submissions = SurveyResults.decodeSubmissions(survey: survey, response: response)
        #expect(submissions.count == 1)
        #expect(submissions[0].answers.count == 2)
        #expect(submissions[0].answers["a"] == .text("hello"))
        #expect(submissions[0].answers["b"] == .rating(4))
        // The window starts when they began answering, not when they finished.
        #expect(submissions[0].date == PostHogDate.parse("2025-12-16T09:00:00Z"))
    }
}

@Suite("Survey rating scale and NPS")
struct SurveyRatingScaleTests {

    @Test("a declared scale of 10 is the 0-10 NPS domain")
    func tenPointScaleIsZeroBased() throws {
        let scale = try #require(SurveyRatingScale.resolve(declared: 10, observed: []))
        #expect(scale.lowerBound == 0)
        #expect(scale.upperBound == 10)
        #expect(scale.supportsNetPromoter)
    }

    @Test("every other declared scale runs 1...n and is not an NPS domain")
    func smallScalesAreOneBased() throws {
        for points in [3, 5, 7] {
            let scale = try #require(SurveyRatingScale.resolve(declared: points, observed: []))
            #expect(scale.lowerBound == 1)
            #expect(scale.upperBound == points)
            #expect(!scale.supportsNetPromoter)
        }
    }

    @Test("an undeclared scale is inferred from answers but never scored")
    func observedScaleIsNeverScored() throws {
        // Answers that happen to span 0-10 do not make a question an NPS
        // question. Scoring this would be a guess wearing a number's clothes.
        let scale = try #require(SurveyRatingScale.resolve(declared: nil, observed: [0, 7, 10]))
        #expect(scale.lowerBound == 0)
        #expect(scale.upperBound == 10)
        #expect(!scale.supportsNetPromoter)
        #expect(SurveyNetPromoter.make(scale: scale, values: [0, 7, 10]) == nil)
    }

    @Test("no declaration and no answers means no scale at all")
    func noScale() {
        #expect(SurveyRatingScale.resolve(declared: nil, observed: []) == nil)
    }

    @Test("the scale says where it came from")
    func provenance() throws {
        let declared = try #require(SurveyRatingScale.resolve(declared: 5, observed: []))
        #expect(declared.provenance == "1–5 scale, from the survey's question definition")

        let observed = try #require(SurveyRatingScale.resolve(declared: nil, observed: [2, 4]))
        #expect(observed.provenance.contains("the range of answers received"))
    }

    @Test("scores a 0-10 scale by the standard bands and carries the bands with it")
    func netPromoterArithmetic() throws {
        let scale = try #require(SurveyRatingScale.resolve(declared: 10, observed: []))
        let nps = try #require(SurveyNetPromoter.make(scale: scale, values: [10, 9, 8, 7, 6, 0]))

        #expect(nps.promoters == 2)
        #expect(nps.passives == 2)
        #expect(nps.detractors == 2)
        #expect(nps.score == 0)
        #expect(nps.basis.contains("0–10 scale, from the survey's question definition"))
        #expect(nps.basis.contains("Promoters 9–10"))
    }

    @Test("a value outside a declared 0-10 scale refuses to be scored")
    func outOfDomainRefuses() throws {
        let scale = try #require(SurveyRatingScale.resolve(declared: 10, observed: []))
        #expect(SurveyNetPromoter.make(scale: scale, values: [9, 11]) == nil)
    }
}

@Suite("Survey question aggregation")
struct SurveyQuestionAggregationTests {

    private func results() throws -> SurveyResults {
        SurveyResults.build(
            survey: try SurveyFixture.dashboardFeedback(),
            summary: try SurveyFixture.summary(),
            answers: try SurveyFixture.answers()
        )
    }

    @Test("aggregates partial answers, which is most of this survey's data")
    func partialsCount() throws {
        let rating = try results().questions[3]

        // Two completed responses and two partial responses must all contribute.
        #expect(rating.answered == 4)
        guard case .rating(let breakdown) = rating.breakdown else {
            Issue.record("expected a rating breakdown"); return
        }
        #expect(abs(breakdown.mean - 3.25) < 0.0001)
    }

    @Test("draws the rating axis from the declared scale, not from the answers")
    func denseBuckets() throws {
        guard case .rating(let breakdown) = try results().questions[3].breakdown else {
            Issue.record("expected a rating breakdown"); return
        }

        // The survey declares 5 points and only 1, 3, 4, and 5 were chosen. All
        // five bars still exist: a missing bar reads as a shorter scale.
        #expect(breakdown.buckets.map(\.value) == [1, 2, 3, 4, 5])
        #expect(breakdown.buckets.map(\.count) == [1, 0, 1, 1, 1])
        #expect(abs(breakdown.buckets[2].share - 0.25) < 0.0001)
        #expect(breakdown.outOfRange == 0)
    }

    @Test("refuses to score a 5-point rating, and says why")
    func noNPSOnAFivePointScale() throws {
        guard case .rating(let breakdown) = try results().questions[3].breakdown else {
            Issue.record("expected a rating breakdown"); return
        }

        #expect(breakdown.netPromoter == nil)
        let absence = try #require(breakdown.netPromoterAbsence)
        #expect(absence.contains("0–10"))
        #expect(absence.contains("5 points"))
    }

    @Test("keeps declared choices nobody picked in the breakdown")
    func choiceKeepsZeroes() throws {
        guard case .choice(let breakdown) = try results().questions[0].breakdown else {
            Issue.record("expected a choice breakdown"); return
        }

        // "Performance concern" was never chosen and is still here, on zero.
        #expect(breakdown.counts.map(\.label) == ["Navigation issue", "Account help", "Data question", "Performance concern"])
        #expect(breakdown.counts.map(\.count) == [2, 1, 1, 0])
        #expect(breakdown.counts.allSatisfy { $0.isDeclaredChoice })
        #expect(!breakdown.allowsMultiple)
    }

    @Test("free text comes back as a readable list, newest first, flagged when partial")
    func textAnswers() throws {
        guard case .text(let answers) = try results().questions[2].breakdown else {
            Issue.record("expected a text breakdown"); return
        }

        #expect(answers.count == 4)
        #expect(answers.map(\.isPartial) == [true, true, false, false])
        let dates = answers.compactMap(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("a question with no answers is empty, not broken")
    func unansweredQuestion() throws {
        let question = try results().questions[1]
        #expect(question.answered == 1)

        let empty = SurveyResults.aggregate(
            question: SurveyQuestion(id: "z", type: "open", question: "Nobody answered"),
            index: 0,
            submissions: []
        )
        #expect(empty.answered == 0)
        guard case .text(let answers) = empty.breakdown else {
            Issue.record("expected a text breakdown"); return
        }
        #expect(answers.isEmpty)
    }

    @Test("a link question says it collects nothing rather than showing an empty chart")
    func linkQuestion() {
        let result = SurveyResults.aggregate(
            question: SurveyQuestion(id: "l", type: "link", question: "Book a call"),
            index: 0,
            submissions: []
        )
        guard case .notAggregatable(let reason) = result.breakdown else {
            Issue.record("expected notAggregatable"); return
        }
        #expect(reason.contains("link question"))
    }

    @Test("an unknown question type names itself instead of pretending to be text")
    func unknownQuestion() {
        let result = SurveyResults.aggregate(
            question: SurveyQuestion(id: "u", type: "sculpture", question: "Carve something"),
            index: 0,
            submissions: []
        )
        guard case .notAggregatable(let reason) = result.breakdown else {
            Issue.record("expected notAggregatable"); return
        }
        #expect(reason.contains("sculpture"))
    }

    @Test("multi-select shares are of people, and can sum past 100%")
    func multiSelectShares() throws {
        let results = SurveyResults.build(
            survey: try SurveyFixture.syntheticNPS(),
            summary: try SurveyFixture.summary(),
            answers: try SurveyFixture.syntheticAnswers()
        )
        guard case .choice(let breakdown) = results.questions[1].breakdown else {
            Issue.record("expected a choice breakdown"); return
        }

        #expect(breakdown.allowsMultiple)
        #expect(breakdown.answered == 5)
        #expect(breakdown.counts.map(\.label) == ["Star maps", "Orbit examples", "Telescope tips", "Observatory workshops"])
        #expect(breakdown.counts.map(\.count) == [3, 2, 2, 0])
        // 3 + 2 + 2 = 7 selections from 5 people: multi-select sums past the total.
        #expect(breakdown.counts.map(\.count).reduce(0, +) == 7)
    }

    @Test("scores the synthetic 0-10 question and shows its bands")
    func syntheticNPS() throws {
        let results = SurveyResults.build(
            survey: try SurveyFixture.syntheticNPS(),
            summary: try SurveyFixture.summary(),
            answers: try SurveyFixture.syntheticAnswers()
        )
        guard case .rating(let breakdown) = results.questions[0].breakdown else {
            Issue.record("expected a rating breakdown"); return
        }

        #expect(breakdown.buckets.map(\.value) == Array(0...10))
        // 9, 10, 7, 8, 5, 1 — two promoters, two passives, two detractors.
        let nps = try #require(breakdown.netPromoter)
        #expect(nps.promoters == 2)
        #expect(nps.passives == 2)
        #expect(nps.detractors == 2)
        #expect(nps.score == 0)
        #expect(breakdown.netPromoterAbsence == nil)
    }
}

@Suite("Survey results states")
struct SurveyResultsStateTests {

    @Test("a survey with no start date reads as never launched, not as empty")
    func notLaunched() throws {
        let survey = Survey.stub(startDate: nil)
        let state = SurveyResults.state(
            survey: survey,
            summary: QueryResponse.stub(
                columns: ["impressions", "responses", "dismissals", "abandonments", "partials"],
                rows: [[0, 0, 0, 0, 0]]
            ),
            answers: QueryResponse.stub(columns: ["submission", "timestamp", "event"], rows: [])
        )
        #expect(state == .notLaunched)
        #expect(state.summary == nil)
    }

    @Test("a launched survey with no events is waiting, which is not the same thing")
    func noActivity() throws {
        let survey = Survey.stub(startDate: PostHogDate.parse("2025-12-16T00:00:00.000Z"))
        let state = SurveyResults.state(
            survey: survey,
            summary: QueryResponse.stub(
                columns: ["impressions", "responses", "dismissals", "abandonments", "partials"],
                rows: [[0, 0, 0, 0, 0]]
            ),
            answers: QueryResponse.stub(columns: ["submission", "timestamp", "event"], rows: [])
        )
        guard case .noActivity = state else {
            Issue.record("expected noActivity, got \(state)"); return
        }
    }

    @Test("shown and never answered is a finding, not an empty state")
    func shownButUnanswered() throws {
        let survey = Survey.stub(
            startDate: PostHogDate.parse("2025-12-16T00:00:00.000Z"),
            questions: [SurveyQuestion(id: "a", type: "open", question: "Why?")]
        )
        let state = SurveyResults.state(
            survey: survey,
            summary: QueryResponse.stub(
                columns: ["impressions", "responses", "dismissals", "abandonments", "partials"],
                rows: [[9, 0, 4, 0, 0]]
            ),
            answers: QueryResponse.stub(
                columns: ["submission", "timestamp", "event", "q0"],
                rows: [["s1", "2025-12-16T09:00:00Z", "survey dismissed", NSNull()]]
            )
        )
        guard case .shownButUnanswered(let summary) = state else {
            Issue.record("expected shownButUnanswered, got \(state)"); return
        }
        #expect(summary.impressions == 9)
        #expect(summary.responses == 0)
    }

    @Test("a populated fixture reads as measured")
    func measured() throws {
        let state = SurveyResults.state(
            survey: try SurveyFixture.dashboardFeedback(),
            summary: try SurveyFixture.summary(),
            answers: try SurveyFixture.answers()
        )
        guard case .measured(let results) = state else {
            Issue.record("expected measured, got \(state)"); return
        }
        #expect(results.questions.count == 6)
        #expect(!results.isTruncated)
    }

    @Test("a full page of answers is reported as truncated")
    func truncation() throws {
        let survey = Survey.stub(questions: [SurveyQuestion(id: "a", type: "open")])
        let rows = (0..<4).map { i in
            ["s\(i)", "2025-12-16T09:00:00Z", "survey sent", "answer \(i)"] as [Any]
        }
        let results = SurveyResults.build(
            survey: survey,
            summary: try SurveyFixture.summary(),
            answers: QueryResponse.stub(
                columns: ["submission", "timestamp", "event", "q0"], rows: rows
            ),
            rowLimit: 4
        )
        #expect(results.isTruncated)
    }

    // MARK: - Coverage

    /// The state the screen has to be able to describe: a capped read of a
    /// survey whose full size is known from the other query.
    ///
    /// `summarySQL` writes no `LIMIT` and is one aggregate row, so its counters
    /// span every outcome event the survey ever produced, while `answersSQL`
    /// stops at 500. Both figures land on one sheet, and until now only the
    /// truncated one was described.
    @Test("a truncated read names what it covers and what the survey holds")
    func coverageNamesBothFigures() throws {
        let survey = Survey.stub(questions: [SurveyQuestion(id: "a", type: "open")])
        let rows = (0..<4).map { i in
            ["s\(i)", "2025-12-16T09:00:00Z", "survey sent", "answer \(i)"] as [Any]
        }
        let results = SurveyResults.build(
            survey: survey,
            summary: QueryResponse.stub(
                columns: ["impressions", "responses", "dismissals", "abandonments", "partials"],
                rows: [[900, 120, 40, 0, 84]]
            ),
            answers: QueryResponse.stub(
                columns: ["submission", "timestamp", "event", "q0"], rows: rows
            ),
            rowLimit: 4
        )

        #expect(results.coverage.isTruncated)
        #expect(results.coverage.submissionsRead == 4)
        // responses + partials, from the query that had no ceiling to hit.
        #expect(results.coverage.submissionsReported == 204)
        let note = try #require(results.coverage.note)
        #expect(note.contains("204"))
        #expect(note.contains("4 submissions"))
        // The ceiling is named, because "there is more" without a figure leaves
        // the reader unable to judge how much of the survey they are looking at.
        #expect(note.contains("stops at 4 events"))
        #expect(try #require(results.coverage.shortNote).contains("from the 4 most recent submissions"))
    }

    /// A page under its ceiling claims nothing, and says nothing.
    @Test("a short read carries no coverage note")
    func shortReadIsSilent() throws {
        let results = SurveyResults.build(
            survey: try SurveyFixture.dashboardFeedback(),
            summary: try SurveyFixture.summary(),
            answers: try SurveyFixture.answers()
        )
        #expect(!results.coverage.isTruncated)
        #expect(results.coverage.note == nil)
        #expect(results.coverage.shortNote == nil)
    }

    /// The half the row count cannot see.
    ///
    /// Sixteen rows is nowhere near `LIMIT 500`, so the comparison is silent —
    /// but an envelope carrying `hasMore: true` with `limit: 16` is PostHog
    /// saying it capped the query itself, below what was asked for. Reading only
    /// the count would report that survey as complete.
    @Test("a server cap below the query's own limit is still caught")
    func envelopeCapUnderOurLimit() throws {
        let survey = Survey.stub(questions: [SurveyQuestion(id: "a", type: "open")])
        let results = SurveyResults.build(
            survey: survey,
            summary: try SurveyFixture.summary(),
            answers: QueryResponse.stub(
                columns: ["submission", "timestamp", "event", "q0"],
                rows: [["s1", "2025-12-16T09:00:00Z", "survey sent", "hello"]],
                hasMore: true,
                limit: 1
            ),
            rowLimit: 500
        )
        #expect(results.coverage.rowsReturned == 1)
        #expect(results.coverage.rowsReturned < 500)
        #expect(results.coverage.isTruncated)
        // And the ceiling reported is PostHog's, not the one that was asked for
        // — quoting 500 here would describe a cap that never applied.
        #expect(results.coverage.rowCap == 1)
        #expect(try #require(results.coverage.note).contains("stops at 1 events"))
    }

    /// Rows PostHog returned, not answers that survived decoding.
    ///
    /// This protects the row-count contract: a row the decoder cannot read is also
    /// an answer missing from the mean, so the count reaching the ceiling has to
    /// be the wire's count. Here two of four rows carry no submission id and are
    /// dropped, which would put a decoded count at 2 against a ceiling of 4.
    @Test("undecodable rows do not retire the survey's coverage note")
    func rowsReturnedNotSubmissions() throws {
        let survey = Survey.stub(questions: [SurveyQuestion(id: "a", type: "open")])
        let rows: [[Any]] = [
            ["s0", "2025-12-16T09:00:00Z", "survey sent", "answer 0"],
            ["", "2025-12-16T09:00:00Z", "survey sent", "answer 1"],
            ["", "2025-12-16T09:00:00Z", "survey sent", "answer 2"],
            ["s3", "2025-12-16T09:00:00Z", "survey sent", "answer 3"],
        ]
        let results = SurveyResults.build(
            survey: survey,
            summary: try SurveyFixture.summary(),
            answers: QueryResponse.stub(
                columns: ["submission", "timestamp", "event", "q0"], rows: rows
            ),
            rowLimit: 4
        )
        #expect(results.submissions.count == 2)
        #expect(results.coverage.rowsReturned == 4)
        #expect(results.coverage.isTruncated, "a full page; two unreadable rows do not make it short")
    }

    /// A submission that carried nothing is not part of what the breakdowns
    /// were computed from, so it must not inflate the figure that says so.
    @Test("only answer-bearing submissions count as read")
    func emptySubmissionsAreNotCounted() throws {
        let survey = Survey.stub(questions: [SurveyQuestion(id: "a", type: "open")])
        let rows: [[Any]] = [
            ["s0", "2025-12-16T09:00:00Z", "survey sent", "answered"],
            ["s1", "2025-12-16T09:00:00Z", "survey dismissed", NSNull()],
        ]
        let results = SurveyResults.build(
            survey: survey,
            summary: try SurveyFixture.summary(),
            answers: QueryResponse.stub(
                columns: ["submission", "timestamp", "event", "q0"], rows: rows
            ),
            rowLimit: 2
        )
        #expect(results.submissions.count == 2)
        #expect(results.coverage.submissionsRead == 1)
    }
}

// MARK: - Stubs

private extension Survey {
    static func stub(
        startDate: Date? = PostHogDate.parse("2025-12-16T00:00:00.000Z"),
        questions: [SurveyQuestion] = []
    ) -> Survey {
        var payload: [String: Any] = [
            "id": "stub-survey",
            "name": "Stub",
            "type": "popover",
            "archived": false,
            "questions": questions.map { question -> [String: Any] in
                var dict: [String: Any] = [:]
                if let id = question.id { dict["id"] = id }
                if let type = question.type { dict["type"] = type }
                if let text = question.question { dict["question"] = text }
                if let choices = question.choices { dict["choices"] = choices }
                if let scale = question.scale { dict["scale"] = scale }
                return dict
            },
        ]
        if let startDate {
            payload["start_date"] = ISO8601DateFormatter().string(from: startDate)
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(Survey.self, from: data)
    }
}

private extension QueryResponse {
    /// Builds a `/query/` payload from plain values so a shape can be asserted
    /// without inventing a fixture file for it.
    ///
    /// `hasMore` and `limit` are optional and *omitted* when nil rather than
    /// sent as false and null, because their absence is the shape under test for
    /// a query that wrote its own `LIMIT`, reached or not.
    static func stub(
        columns: [String],
        rows: [[Any]],
        hasMore: Bool? = nil,
        limit: Int? = nil
    ) -> QueryResponse {
        var payload: [String: Any] = [
            "columns": columns,
            "results": rows.map { row in
                row.map { $0 }
            },
        ]
        if let hasMore { payload["hasMore"] = hasMore }
        if let limit { payload["limit"] = limit }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! QueryResponse.decode(from: data)
    }
}
