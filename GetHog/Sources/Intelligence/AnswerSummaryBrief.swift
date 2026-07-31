import Foundation
import GetHogKit

/// Builds the brief that turns a batch of open-text survey answers into a
/// paragraph about what people said.
///
/// **What this replaces.** `SurveyTextAnswersView` shows three answers and a
/// link; behind the link is every answer, newest first, which on a real survey
/// is a list you read one at a time until you stop. Rating and choice questions
/// get a distribution and a mean because they can be totalled. Open text cannot
/// be, and the honest consequence up to now was that it was simply a list.
/// Themes and tone across a batch are the one thing a small model is reliably
/// good at, and the answers are already in memory — so this costs no query, and
/// the organisation-wide PostHog rate limit is untouched.
///
/// **Counting is forbidden, in the instructions and by construction.** The model
/// is told not to produce numbers, proportions or "most people" claims, and it
/// is given no counts to copy. That is not squeamishness: this screen already
/// carries real figures — impressions, responses, the partial-answer caveat, a
/// distribution per question — and a generated "about half mentioned pricing"
/// sitting near them would be indistinguishable from one PostHog computed. The
/// summary is allowed to say *what* people talked about and *how it sounded*.
/// Anything quantitative stays with the queries that can actually count.
///
/// **The batch is bounded and the bound is reported.** At most 40 answers and
/// about 6,000 characters go in — a whole survey would not fit the context
/// window, and a phone should not spend a minute of inference on one. `scope`
/// says how many of how many were read, and it says so *on top of* the existing
/// truncation caveat: `SurveyResults.isTruncated` already warns that the answer
/// query itself hit its row cap, and these two limits compose.
enum AnswerSummaryBrief {

    /// How many answers the model is shown. Newest first, which is the order
    /// `SurveyResults` sorts them in and the order a reader scrolls them.
    static let answerLimit = 40
    /// Total characters of answer text.
    static let characterBudget = 6_000
    /// One answer's share, so a single essay cannot crowd out thirty replies.
    static let answerLimitPerAnswer = 400

    /// The number of answers below which a summary is not offered.
    ///
    /// Three or fewer is not a batch; it is a paragraph you have already read,
    /// and a summary of it would be longer than the thing summarised. This is
    /// also `SurveyTextAnswersView.inlineLimit`, which is what decides whether
    /// the "All N answers" screen exists at all — so the threshold and the
    /// screen appear together rather than one without the other.
    static let minimumAnswers = 4

    /// The format rule leads, for the reason `IssueSummaryBrief.instructions`
    /// records at length: asked politely in a third paragraph, this model
    /// answers in markdown with bold field labels, and `Text` renders that as
    /// literal asterisks.
    static let instructions = """
        You summarise free-text survey answers for a product team.

        Answer with a single paragraph of three to five complete sentences.

        Plain sentences only. No markdown. No asterisks, no backticks, no \
        headings, no bullet points, no line breaks, no lists.

        Do not announce what you are about to do. Never begin with "Here is a \
        summary" or anything like it.

        Say what people are talking about — the recurring subjects — and how the \
        answers sound overall: enthusiastic, mixed, frustrated, resigned. Praise \
        and complaint often land on different subjects in the same batch, so do \
        not attach a complaint to a subject people were positive about. If \
        opinion is split, say what the split is about. If a small number of \
        answers say something unusual and specific, it is worth one clause.

        Never give a number, a count, a percentage, a proportion or a fraction. \
        Do not write "most", "half", "a majority", "9 out of 10" or anything \
        that quantifies. Do not rank. You have not been told how many people \
        said anything, and you must not imply that you have.

        Quote at most a few words at a time, and only to name a subject. Do not \
        reproduce a whole answer. Do not repeat names, email addresses, URLs or \
        any other identifying detail that appears in an answer.

        Base every word on the answers given. If they are too varied or too \
        thin to characterise, say that in one sentence.
        """

    /// Whether the screen should offer a summary at all.
    static func isWorthwhile(_ answers: [SurveyTextAnswer]) -> Bool {
        answers.count >= minimumAnswers
    }

    static func make(question: String, answers: [SurveyTextAnswer]) -> SummaryBrief {
        make(question: question, texts: answers.map(\.text))
    }

    /// The whole of the work, over the only field of an answer this reads.
    ///
    /// A seam, and not one chosen for elegance: `GetHogKit.SurveyTextAnswer`
    /// declares four `public let`s and no `public init`, so its memberwise
    /// initialiser is internal to the package and **nothing in the app target
    /// can construct one** — including a test. Every other behaviour on this
    /// screen is reachable from a scripted `QueryResponse`, but the prompt
    /// bounding here is worth pinning directly rather than through two decoders.
    /// If `SurveyTextAnswer` ever gains a public init the way `ErrorIssue` has
    /// one for exactly this reason, this overload can go.
    static func make(question: String, texts: [String]) -> SummaryBrief {
        var used = 0
        var lines: [String] = []

        for answer in texts.prefix(answerLimit) {
            let text = SummaryText.truncated(
                SummaryText.flattened(answer),
                to: answerLimitPerAnswer
            )
            guard !text.isEmpty else { continue }
            guard used + text.count <= characterBudget else { break }
            used += text.count
            // Numbered so the model can tell one answer from the next without
            // being told how many there are — the index is a separator, and the
            // instructions forbid counting with it.
            lines.append("- \(text)")
        }

        return SummaryBrief(
            instructions: instructions,
            prompt: """
                The survey question was: \(SummaryText.truncated(SummaryText.flattened(question), to: 300))

                The answers people typed:
                \(lines.joined(separator: "\n"))
                """,
            // Three to five sentences. 260 tokens is comfortably more than that
            // without letting a runaway generation take the screen.
            maximumResponseTokens: 260,
            scope: scope(read: lines.count, available: texts.count)
        )
    }

    private static func scope(read: Int, available: Int) -> String {
        if read >= available {
            return "Read from all \(available.formatted()) of this question's open-text answers."
        }
        return "Read from the \(read.formatted()) most recent of \(available.formatted()) open-text answers — the rest were left out to fit the model."
    }
}
