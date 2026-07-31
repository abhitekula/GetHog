import Foundation

// Survey results, read from the events table.
//
// There is no survey-results API. A survey's answers are ordinary events —
// `survey shown`, `survey sent`, `survey dismissed`, and on newer SDKs
// `survey abandoned` — carrying the answers in their properties, so everything
// here is HogQL over `events` and arithmetic in Swift.
//
// Two things in this file exist only to stop a plausible-looking wrong number
// from being drawn, and both were checked against project [REMOVED PRIVATE DATA] on 2026-07-30:
//
// 1. **Submissions, not events.** PostHog can split one person's answers across
//    several events that share a `$survey_submission_id` — a `survey sent` per
//    answered question, `$survey_completed` false until the last. Counting rows
//    would then count one person several times. Every count here is over
//    distinct submission ids. In that project's data the fan-out does not occur
//    (four submission ids across four events, one apiece, and `$survey_completed`
//    is never false), so the dedupe is currently a no-op there — but it is the
//    difference between a right and a wrong number the day it isn't.
//
// 2. **Answers arrive on dismissals too.** Three of that project's four
//    submissions came in on `survey dismissed` with `$survey_partially_completed:
//    true`, carrying a rating and two answers each. Aggregating only `survey
//    sent` would have shown that rating question as a single answer of 5 —
//    a mean of 5.0 — where the four real answers are 5, 2, 2, 2 and mean 2.75.
//    So question breakdowns read every submission that carries an answer, and
//    the summary reports completed and partial separately rather than blending
//    them into one "responses" figure.

// MARK: - Rating scale

/// The domain of a rating question, and where that domain came from.
///
/// NPS and CSAT are survey *templates* PostHog builds out of an ordinary rating
/// question; there is no `nps` question type and nothing on the event says
/// "this is an NPS response". The only thing that can justify the 9–10 promoter
/// rule is the question's declared scale, so the scale carries its own
/// provenance and refuses to be guessed at.
public struct SurveyRatingScale: Sendable, Hashable {
    public let lowerBound: Int
    public let upperBound: Int
    public let source: Source

    public enum Source: Sendable, Hashable {
        /// Read from the question's `scale` field in the survey definition.
        case declared(Int)
        /// The question declared no scale. These bounds are the smallest and
        /// largest answer that actually arrived, which is enough to draw an
        /// axis and not enough to bucket an NPS score.
        case observed
    }

    public var values: [Int] { Array(lowerBound...upperBound) }

    /// Resolves the domain, or `nil` when the question declares no scale and
    /// nobody has answered — in which case there is no axis to draw and saying
    /// so is the honest outcome.
    ///
    /// PostHog renders `scale: 10` as 0–10, the NPS convention, and every other
    /// scale as 1…n. An unrecognised scale is still honoured as 1…n rather than
    /// discarded, so a scale PostHog adds later draws correctly even though it
    /// will not be scored.
    public static func resolve(declared: Int?, observed: [Int]) -> SurveyRatingScale? {
        if let declared, declared > 0 {
            return declared == 10
                ? SurveyRatingScale(lowerBound: 0, upperBound: 10, source: .declared(10))
                : SurveyRatingScale(lowerBound: 1, upperBound: declared, source: .declared(declared))
        }
        guard let low = observed.min(), let high = observed.max() else { return nil }
        return SurveyRatingScale(lowerBound: low, upperBound: max(low, high), source: .observed)
    }

    /// True only for a 0–10 scale the survey definition actually declared.
    ///
    /// Deliberately not satisfied by answers that merely *span* 0–10: responses
    /// happening to land on 0 and 10 does not make a question an NPS question,
    /// and an unlabelled number bucketed on that assumption is worse than no
    /// number.
    public var supportsNetPromoter: Bool {
        guard case .declared = source else { return false }
        return lowerBound == 0 && upperBound == 10
    }

    /// A sentence a reader can check the arithmetic against.
    public var provenance: String {
        switch source {
        case .declared:
            "\(lowerBound)–\(upperBound) scale, from the survey's question definition"
        case .observed:
            "\(lowerBound)–\(upperBound), the range of answers received — the question declares no scale"
        }
    }
}

/// A Net Promoter Score, and the bucketing it was produced by.
///
/// Only ever built from a declared 0–10 scale. `basis` travels with the number
/// so the score is never shown as a bare figure whose bucketing a reader has to
/// take on trust.
public struct SurveyNetPromoter: Sendable, Hashable {
    public let promoters: Int
    public let passives: Int
    public let detractors: Int
    public let basis: String

    public var total: Int { promoters + passives + detractors }

    /// Percentage promoters minus percentage detractors, −100…100.
    public var score: Int {
        guard total > 0 else { return 0 }
        let value = (Double(promoters) - Double(detractors)) / Double(total) * 100
        return Int(value.rounded())
    }

    static func make(scale: SurveyRatingScale, values: [Int]) -> SurveyNetPromoter? {
        guard scale.supportsNetPromoter, !values.isEmpty else { return nil }
        guard values.allSatisfy({ $0 >= 0 && $0 <= 10 }) else { return nil }
        return SurveyNetPromoter(
            promoters: values.count { $0 >= 9 },
            passives: values.count { $0 == 7 || $0 == 8 },
            detractors: values.count { $0 <= 6 },
            basis: "\(scale.provenance). Promoters 9–10, passives 7–8, detractors 0–6."
        )
    }
}

// MARK: - Answers

/// One person's answer to one question.
public enum SurveyAnswer: Sendable, Hashable {
    case text(String)
    case rating(Int)
    case choice(String)
    case choices([String])

    /// What a free-text list and an export should show.
    public var displayText: String {
        switch self {
        case .text(let s), .choice(let s): s
        case .rating(let value): String(value)
        case .choices(let items): items.joined(separator: ", ")
        }
    }
}

/// One respondent's pass through a survey, keyed by the id PostHog bills on.
public struct SurveySubmission: Sendable, Hashable, Identifiable {
    public let id: String
    public let date: Date?
    public let isComplete: Bool
    public let answers: [String: SurveyAnswer]

    public init(id: String, date: Date?, isComplete: Bool, answers: [String: SurveyAnswer]) {
        self.id = id
        self.date = date
        self.isComplete = isComplete
        self.answers = answers
    }
}

// MARK: - Summary

/// The funnel a survey actually has: shown, answered, dismissed.
public struct SurveyResultsSummary: Sendable, Hashable {
    public let impressions: Int
    /// Distinct submissions that reached `survey sent`.
    public let responses: Int
    /// Distinct submissions that carried answers but ended in a dismissal or an
    /// abandonment. Counted apart from `responses` because they are not the same
    /// event — but their answers do feed the question breakdowns.
    public let partials: Int
    public let dismissals: Int
    public let abandonments: Int
    public let firstSeen: Date?
    public let lastSeen: Date?

    public init(
        impressions: Int,
        responses: Int,
        partials: Int,
        dismissals: Int,
        abandonments: Int,
        firstSeen: Date? = nil,
        lastSeen: Date? = nil
    ) {
        self.impressions = impressions
        self.responses = responses
        self.partials = partials
        self.dismissals = dismissals
        self.abandonments = abandonments
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    /// Completed responses as a share of impressions, or `nil` when nothing was
    /// ever shown — a rate with a zero denominator is not 0%, it is unknown.
    public var responseRate: Double? {
        impressions > 0 ? Double(responses) / Double(impressions) : nil
    }

    public var dismissalRate: Double? {
        impressions > 0 ? Double(dismissals) / Double(impressions) : nil
    }

    /// Submissions carrying at least one answer, complete or not. The count the
    /// question breakdowns below are drawn from.
    public var answeringSubmissions: Int { responses + partials }

    public var isEmpty: Bool {
        impressions == 0 && responses == 0 && dismissals == 0 && abandonments == 0
    }

    public init(row: QueryRow) {
        impressions = row.int("impressions") ?? 0
        responses = row.int("responses") ?? 0
        partials = row.int("partials") ?? 0
        dismissals = row.int("dismissals") ?? 0
        abandonments = row.int("abandonments") ?? 0
        firstSeen = row.date("first_seen")
        lastSeen = row.date("last_seen")
    }

    public static func decode(from response: QueryResponse) -> SurveyResultsSummary {
        guard let row = response.rows.first else {
            return SurveyResultsSummary(
                impressions: 0, responses: 0, partials: 0, dismissals: 0, abandonments: 0
            )
        }
        return SurveyResultsSummary(row: row)
    }
}

// MARK: - Per-question breakdowns

public struct SurveyRatingBucket: Sendable, Hashable, Identifiable {
    public let value: Int
    public let count: Int
    public let share: Double
    public var id: Int { value }
}

public struct SurveyRatingBreakdown: Sendable, Hashable {
    public let scale: SurveyRatingScale
    public let buckets: [SurveyRatingBucket]
    public let mean: Double
    public let answered: Int
    /// Answers outside the declared scale. Non-zero means the definition and
    /// the data disagree, which is why no score is derived when it happens.
    public let outOfRange: Int
    public let netPromoter: SurveyNetPromoter?

    /// Why there is no NPS score, in a form a reader can act on — or `nil` when
    /// there is one.
    public var netPromoterAbsence: String? {
        guard netPromoter == nil else { return nil }
        if outOfRange > 0 {
            return "Not scored: \(outOfRange) answer\(outOfRange == 1 ? "" : "s") fall outside the \(scale.lowerBound)–\(scale.upperBound) scale this question declares."
        }
        switch scale.source {
        case .declared(let n):
            return "Not scored: NPS is defined on a 0–10 scale and this question declares \(n) points."
        case .observed:
            return "Not scored: the question declares no rating scale, so promoter and detractor bands can't be established."
        }
    }
}

public struct SurveyChoiceCount: Sendable, Hashable, Identifiable {
    public let label: String
    public let count: Int
    public let share: Double
    /// False for an answer typed into an open-ended "other" box, which is not
    /// one of the survey's declared choices.
    public let isDeclaredChoice: Bool
    public var id: String { label }
}

public struct SurveyChoiceBreakdown: Sendable, Hashable {
    public let counts: [SurveyChoiceCount]
    public let answered: Int
    /// Multi-select answers sum past the number of respondents, so a share here
    /// is a share of people, not of a whole that adds to 100%.
    public let allowsMultiple: Bool
}

public struct SurveyTextAnswer: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let date: Date?
    public let isPartial: Bool

    /// Public for the same reason `ErrorIssue`'s is: the app target is a
    /// different module, so without it nothing outside this package can build
    /// one — not even a test. The type and every property were already public,
    /// which made the synthesised memberwise initialiser's internal default a
    /// silent hole rather than a decision.
    ///
    /// `isPartial` has no default. A partial answer comes from a `survey
    /// dismissed` event carrying `$survey_partially_completed`, and this
    /// project has already measured what conflating the two costs: one rating
    /// question's mean reads 5.00 counting completions alone against 2.75
    /// counting every answer-bearing submission. A caller that has not decided
    /// which it holds should not be handed a default that decides for it.
    public init(id: String, text: String, date: Date?, isPartial: Bool) {
        self.id = id
        self.text = text
        self.date = date
        self.isPartial = isPartial
    }
}

/// What one question's answers add up to.
public struct SurveyQuestionResults: Sendable, Hashable, Identifiable {
    public let index: Int
    public let question: SurveyQuestion
    public let answered: Int
    public let breakdown: Breakdown

    public var id: Int { index }

    public var title: String {
        question.question ?? "Question \(index + 1)"
    }

    public enum Breakdown: Sendable, Hashable {
        case rating(SurveyRatingBreakdown)
        case choice(SurveyChoiceBreakdown)
        case text([SurveyTextAnswer])
        /// The question type collects nothing this build can total up. The
        /// string says which, so "we can't chart this" never gets mistaken for
        /// "nobody answered".
        case notAggregatable(String)
    }
}

// MARK: - Results

/// How much of a survey the breakdowns were actually computed over.
///
/// Every figure on the results screen below the funnel is *derived* — a mean, a
/// share, an NPS score — and a derived figure over a truncated set is wrong
/// rather than merely partial. This project has already paid for that once at
/// the top of this file: counting completions alone read a rating mean of 5.00
/// where the four answer-bearing submissions give 2.75.
///
/// **Why the row count, and why the flag as well.** `answersSQL` writes its own
/// `LIMIT 500`, and the `/query/` envelope says nothing about a limit the caller
/// wrote — measured and recorded on `QueryResponse.isTruncated`: the same query
/// at `LIMIT 200` came back with **neither** `hasMore` nor `limit` while holding
/// 200 rows of 423. So at the ceiling the flag is silent and the row count is
/// the only evidence; if PostHog ever caps *below* 500 the count cannot see it
/// and the flag is the only evidence. Neither subsumes the other, which is the
/// same conclusion `SessionTimelineStore` and `SchemaStore` reached.
///
/// **Why the denominator does not have to be guessed at.** `summarySQL` writes
/// no `LIMIT` at all and is a single aggregate row, so its counters run over
/// every outcome event the survey ever produced — the same trick
/// `PostHogAPI.groupEventBreakdown` plays with `sum(count()) OVER ()`, except
/// here the second query already carried it and nothing had to be added.
/// `responses + partials` is therefore a real project-wide figure sitting beside
/// a capped one, and stating both is what stops the capped one being read as the
/// survey's.
///
/// That pairing is not exact and the note below is worded so it does not pretend
/// to be: `responses` counts every submission that reached `survey sent`,
/// whether or not it carried an answer, so it is an upper bound on the
/// answer-bearing submissions rather than a count of them. The note therefore
/// names it as what it is — responses and partial dismissals recorded — instead
/// of subtracting the two into a "hidden" figure the data does not support.
public struct SurveyAnswerCoverage: Sendable, Hashable {
    /// Rows the answers query returned.
    ///
    /// **`QueryResponse.rows.count`, never the submissions that survived
    /// decoding.** `SessionTimelineStore` documents the measured version of this
    /// trap: one undecodable row in a full page puts the decoded count one under
    /// the ceiling and retires the notice exactly when the data is least
    /// trustworthy. Here it would be worse than a lost notice, because the rows
    /// that fail to decode are also the answers missing from the mean.
    public let rowsReturned: Int

    /// The ceiling those rows met: PostHog's own cap when it applied one,
    /// otherwise the `LIMIT` the query wrote.
    public let rowCap: Int

    /// The envelope's `hasMore`, kept separate from the row comparison because
    /// the two cover disjoint cases — see the type's own note.
    public let envelopeHasMore: Bool

    /// Submissions carrying at least one answer, which is the set every
    /// breakdown on the screen was built from.
    public let submissionsRead: Int

    /// `responses + partials` from the unbounded summary query.
    public let submissionsReported: Int

    public init(
        rowsReturned: Int,
        rowCap: Int,
        envelopeHasMore: Bool,
        submissionsRead: Int,
        submissionsReported: Int
    ) {
        self.rowsReturned = rowsReturned
        self.rowCap = rowCap
        self.envelopeHasMore = envelopeHasMore
        self.submissionsRead = submissionsRead
        self.submissionsReported = submissionsReported
    }

    public var isTruncated: Bool { envelopeHasMore || rowsReturned >= rowCap }

    /// What the breakdowns cover, or `nil` when they cover everything the
    /// answers query could reach.
    ///
    /// `nil` rather than a reassuring sentence, deliberately. The funnel
    /// directly above already states the survey's real size, so a permanent
    /// "these are all of them" line under it would be the third statement of the
    /// same fact on one sheet — and a notice a reader learns to skip is not a
    /// notice. `HeatmapProfile.coverageNote` always says something because the
    /// figure it sits under, a click total, has no honest whole to be read
    /// against; this one does.
    public var note: String? {
        guard isTruncated else { return nil }
        let read = submissionsRead == 1
            ? "1 submission"
            : "\(submissionsRead.formatted()) submissions"
        let tail = """
            The answers query stops at \(rowCap.formatted()) events and reached that ceiling, \
            so the means, shares and any score below describe that recent slice rather than \
            the whole survey.
            """
        guard submissionsReported > submissionsRead else {
            return "These breakdowns cover the \(read) carrying an answer that the query read. \(tail)"
        }
        return """
            These breakdowns cover the most recent \(read) carrying an answer, against \
            \(submissionsReported.formatted()) responses and partial dismissals this survey has \
            recorded. \(tail)
            """
    }

    /// The same fact in a fragment, for a line that sits beside one figure
    /// rather than above all of them.
    /// Reads as the tail of "N answers, …", which is why it begins with "from"
    /// and carries no leading capital — rendered, "12 answers in the 12 most
    /// recent submissions read" parsed as one run-on figure, and the comma plus
    /// "from" is what separates the count from its sample.
    public var shortNote: String? {
        guard isTruncated else { return nil }
        return submissionsRead == 1
            ? "from the 1 most recent submission read"
            : "from the \(submissionsRead.formatted()) most recent submissions read"
    }
}

public struct SurveyResults: Sendable, Hashable {
    public let summary: SurveyResultsSummary
    public let questions: [SurveyQuestionResults]
    public let submissions: [SurveySubmission]
    /// What the breakdowns were computed over, and what the survey actually
    /// holds. See `SurveyAnswerCoverage`.
    public let coverage: SurveyAnswerCoverage

    /// True when the answer query hit its row cap, so the breakdowns describe a
    /// recent slice rather than the whole survey.
    public var isTruncated: Bool { coverage.isTruncated }

    public init(
        summary: SurveyResultsSummary,
        questions: [SurveyQuestionResults],
        submissions: [SurveySubmission],
        coverage: SurveyAnswerCoverage
    ) {
        self.summary = summary
        self.questions = questions
        self.submissions = submissions
        self.coverage = coverage
    }
}

/// The four states a survey's results screen can legitimately be in.
///
/// These are different facts, not shades of empty: a survey that never launched
/// cannot have data, a launched survey with no events yet might get some, and a
/// survey that has been shown seventeen times and answered none is a finding.
public enum SurveyResultsState: Sendable, Hashable {
    /// No start date. Nothing has been shown and no query will change that.
    case notLaunched
    /// Launched, but the events table has nothing under this survey's id.
    case noActivity(SurveyResultsSummary)
    /// Shown to people, and not one of them answered anything.
    case shownButUnanswered(SurveyResultsSummary)
    case measured(SurveyResults)

    public var summary: SurveyResultsSummary? {
        switch self {
        case .notLaunched: nil
        case .noActivity(let s), .shownButUnanswered(let s): s
        case .measured(let r): r.summary
        }
    }
}

// MARK: - Building

public extension SurveyResults {
    /// Folds the two query responses into one reading of the survey.
    ///
    /// `answers` rows are one event apiece; several may share a submission id,
    /// so they are merged before anything is counted. A later event's answer to
    /// the same question wins, which matches PostHog's own last-write-wins
    /// reading of a resumed submission.
    static func build(
        survey: Survey,
        summary summaryResponse: QueryResponse,
        answers answersResponse: QueryResponse,
        rowLimit: Int = SurveyResultsQuery.responseLimit
    ) -> SurveyResults {
        let summary = SurveyResultsSummary.decode(from: summaryResponse)
        let submissions = decodeSubmissions(survey: survey, response: answersResponse)
        let questions = survey.questions.enumerated().map { index, question in
            aggregate(question: question, index: index, submissions: submissions)
        }
        return SurveyResults(
            summary: summary,
            questions: questions,
            submissions: submissions,
            coverage: SurveyAnswerCoverage(
                rowsReturned: answersResponse.rows.count,
                // PostHog's own cap when it applied one, ours otherwise. The
                // envelope carries `limit` only for a cap PostHog imposed, so
                // this is `rowLimit` for every ordinary run of this query and
                // becomes the smaller server figure on the day PostHog decides
                // to cap below it. **Not observed here** — no run of this query
                // has been seen coming back with a `limit` field, because it has
                // always written its own.
                rowCap: answersResponse.appliedLimit ?? rowLimit,
                // This used to be `rows.count >= rowLimit` alone. The count is
                // still the load-bearing half — see `SurveyAnswerCoverage` — but
                // on its own it cannot see a cap applied below the one asked
                // for, and the flag is free.
                envelopeHasMore: answersResponse.isTruncated,
                // Submissions that carry an answer, not every submission the
                // query returned: a `survey dismissed` with nothing filled in
                // reaches this list and contributes to no breakdown, so counting
                // it here would overstate what the means were computed from.
                submissionsRead: submissions.count { !$0.answers.isEmpty },
                submissionsReported: summary.answeringSubmissions
            )
        )
    }

    /// Which of the four states this survey is in.
    static func state(
        survey: Survey,
        summary: QueryResponse,
        answers: QueryResponse
    ) -> SurveyResultsState {
        let results = build(survey: survey, summary: summary, answers: answers)
        if results.summary.isEmpty {
            return survey.startDate == nil ? .notLaunched : .noActivity(results.summary)
        }
        if results.submissions.allSatisfy({ $0.answers.isEmpty }) {
            return .shownButUnanswered(results.summary)
        }
        return .measured(results)
    }

    static func decodeSubmissions(survey: Survey, response: QueryResponse) -> [SurveySubmission] {
        var order: [String] = []
        var merged: [String: SurveySubmission] = [:]

        for row in response.rows {
            guard let id = row.string("submission"), !id.isEmpty else { continue }
            let date = row.date("timestamp")
            let isComplete = row.string("event") == "survey sent"

            var answers: [String: SurveyAnswer] = [:]
            for (index, question) in survey.questions.enumerated() {
                guard let value = row.value("q\(index)"),
                      let answer = SurveyAnswer(value: value, kind: question.kind)
                else { continue }
                answers[question.answerKey(index: index)] = answer
            }

            if let existing = merged[id] {
                merged[id] = SurveySubmission(
                    id: id,
                    // Rows arrive newest-first; the earliest timestamp is when
                    // the person started answering.
                    date: [existing.date, date].compactMap { $0 }.min(),
                    isComplete: existing.isComplete || isComplete,
                    answers: existing.answers.merging(answers) { old, _ in old }
                )
            } else {
                order.append(id)
                merged[id] = SurveySubmission(
                    id: id, date: date, isComplete: isComplete, answers: answers
                )
            }
        }
        return order.compactMap { merged[$0] }
    }

    static func aggregate(
        question: SurveyQuestion,
        index: Int,
        submissions: [SurveySubmission]
    ) -> SurveyQuestionResults {
        let key = question.answerKey(index: index)
        let answers = submissions.compactMap { submission -> (SurveySubmission, SurveyAnswer)? in
            submission.answers[key].map { (submission, $0) }
        }

        let breakdown: SurveyQuestionResults.Breakdown
        switch question.kind {
        case .rating:
            breakdown = .rating(ratingBreakdown(question: question, answers: answers.map(\.1)))
        case .singleChoice, .multipleChoice:
            breakdown = .choice(
                choiceBreakdown(question: question, answers: answers.map(\.1), submissions: answers.count)
            )
        case .open:
            breakdown = .text(
                answers.map { submission, answer in
                    SurveyTextAnswer(
                        id: submission.id,
                        text: answer.displayText,
                        date: submission.date,
                        isPartial: !submission.isComplete
                    )
                }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            )
        case .link:
            breakdown = .notAggregatable("A link question records a click, not an answer, so there is nothing to total up here.")
        case .unsupported(let raw):
            breakdown = .notAggregatable("This build doesn't know how to summarise a \"\(raw)\" question. Its answers are on the PostHog web console.")
        }

        return SurveyQuestionResults(
            index: index,
            question: question,
            answered: answers.count,
            breakdown: breakdown
        )
    }

    private static func ratingBreakdown(
        question: SurveyQuestion,
        answers: [SurveyAnswer]
    ) -> SurveyRatingBreakdown {
        let values: [Int] = answers.compactMap {
            if case .rating(let v) = $0 { return v }
            return nil
        }
        guard let scale = SurveyRatingScale.resolve(declared: question.scale, observed: values) else {
            return SurveyRatingBreakdown(
                scale: SurveyRatingScale(lowerBound: 1, upperBound: 1, source: .observed),
                buckets: [],
                mean: 0,
                answered: 0,
                outOfRange: 0,
                netPromoter: nil
            )
        }

        let inRange = values.filter { $0 >= scale.lowerBound && $0 <= scale.upperBound }
        let outOfRange = values.count - inRange.count
        let total = max(inRange.count, 1)
        let tally = Dictionary(grouping: inRange, by: { $0 }).mapValues(\.count)
        let buckets = scale.values.map { value in
            let count = tally[value] ?? 0
            return SurveyRatingBucket(
                value: value,
                count: count,
                share: inRange.isEmpty ? 0 : Double(count) / Double(total)
            )
        }
        let mean = inRange.isEmpty
            ? 0
            : Double(inRange.reduce(0, +)) / Double(inRange.count)

        return SurveyRatingBreakdown(
            scale: scale,
            buckets: buckets,
            mean: mean,
            answered: values.count,
            outOfRange: outOfRange,
            // A definition that disagrees with its own data is not a scale to
            // bucket a score on.
            netPromoter: outOfRange == 0 ? SurveyNetPromoter.make(scale: scale, values: inRange) : nil
        )
    }

    private static func choiceBreakdown(
        question: SurveyQuestion,
        answers: [SurveyAnswer],
        submissions: Int
    ) -> SurveyChoiceBreakdown {
        let declared = question.choices ?? []
        var tally: [String: Int] = [:]
        for answer in answers {
            switch answer {
            case .choice(let label): tally[label, default: 0] += 1
            case .choices(let labels): for label in labels { tally[label, default: 0] += 1 }
            case .text(let label): tally[label, default: 0] += 1
            case .rating(let value): tally[String(value), default: 0] += 1
            }
        }

        // Declared options nobody picked stay in the list at zero: "nobody chose
        // this" is a result, and a silently missing row reads as a shorter
        // survey than the one that ran.
        var labels = declared
        for label in tally.keys.sorted() where !declared.contains(label) {
            labels.append(label)
        }

        let denominator = max(submissions, 1)
        let counts = labels.map { label in
            let count = tally[label] ?? 0
            return SurveyChoiceCount(
                label: label,
                count: count,
                share: submissions == 0 ? 0 : Double(count) / Double(denominator),
                isDeclaredChoice: declared.contains(label)
            )
        }
        .sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }

        return SurveyChoiceBreakdown(
            counts: counts,
            answered: submissions,
            allowsMultiple: question.kind.isMultiSelect
        )
    }
}

extension SurveyQuestion {
    /// The key a question's answers are filed under while aggregating.
    ///
    /// The question's own id when it has one, its position when it doesn't —
    /// surveys created before PostHog minted per-question ids have no other
    /// handle.
    func answerKey(index: Int) -> String {
        id ?? "index:\(index)"
    }
}

extension SurveyAnswer {
    /// Reads one cell of the answers query.
    ///
    /// Everything except a multi-select arrives as a **string**, including
    /// ratings: HogQL's `getSurveyResponse` is a `JSONExtractString`, so a
    /// rating of 5 comes back as `"5"`. Multi-select arrives from
    /// `JSONExtractArrayRaw` as an array of *raw JSON* elements, so `"Docs"` is
    /// the element text, quotes and all, and has to be unwrapped.
    init?(value: JSONValue, kind: SurveyQuestionKind) {
        switch kind {
        case .multipleChoice:
            guard case .array(let items) = value else { return nil }
            let labels = items.compactMap { $0.stringValue.map(SurveyAnswer.unwrapRawJSON) }
                .filter { !$0.isEmpty }
            guard !labels.isEmpty else { return nil }
            self = .choices(labels)

        case .rating:
            guard let text = value.stringValue, !text.isEmpty else { return nil }
            // `Double` first: an SDK sending 4.0 should read as 4, not fail.
            guard let number = Double(text), number.isFinite else { return nil }
            self = .rating(Int(number.rounded()))

        case .singleChoice:
            guard let text = value.stringValue, !text.isEmpty else { return nil }
            self = .choice(text)

        case .open, .link, .unsupported:
            guard let text = value.stringValue, !text.isEmpty else { return nil }
            self = .text(text)
        }
    }

    /// `"\"Docs\""` → `Docs`. Falls back to the text as-is, because an element
    /// that is not valid JSON is still more useful shown than dropped.
    static func unwrapRawJSON(_ raw: String) -> String {
        guard raw.hasPrefix("\"") else { return raw }
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return String(raw.dropFirst().dropLast(raw.hasSuffix("\"") ? 1 : 0))
    }
}
