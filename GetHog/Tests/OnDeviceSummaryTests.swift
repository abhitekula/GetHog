import Foundation
import FoundationModels
import GetHogKit
import Testing

@testable import GetHog

// What can and cannot be tested here, stated once.
//
// `SystemLanguageModel` has no initialiser that yields a chosen availability and
// no way to script a generation, so nothing below can fake the model. Two
// consequences shape this file:
//
//   * The *mapping* layers are pure functions taking Apple's own enums, and they
//     are pinned exhaustively — `OnDeviceModelReadiness.reading(_:supportsLocale:)`
//     and `OnDeviceSummaryStore.failure(for:)`.
//   * The one suite that runs a real generation, `LiveOnDeviceModel`, is gated on
//     the device actually having Apple Intelligence. On a machine without it the
//     suite is **skipped, not passed** — which is the honest outcome, and visible
//     as such in the test log rather than hidden inside a green assertion.

// MARK: - Readiness

@Suite("On-device model readiness")
struct OnDeviceModelReadinessTests {

    @Test("names each unavailable reason as its own answer")
    func namesEveryUnavailableReason() {
        #expect(
            OnDeviceModelReadiness.reading(.unavailable(.deviceNotEligible), supportsLocale: true)
                == .deviceNotEligible
        )
        #expect(
            OnDeviceModelReadiness.reading(
                .unavailable(.appleIntelligenceNotEnabled), supportsLocale: true
            ) == .notEnabled
        )
        #expect(
            OnDeviceModelReadiness.reading(.unavailable(.modelNotReady), supportsLocale: true)
                == .modelNotReady
        )
    }

    @Test("available plus a supported locale is the only ready state")
    func readyNeedsBoth() {
        #expect(OnDeviceModelReadiness.reading(.available, supportsLocale: true) == .ready)
        #expect(
            OnDeviceModelReadiness.reading(.available, supportsLocale: false) == .languageUnsupported
        )
    }

    /// An ineligible device reports no supported languages at all, so the order
    /// of the two checks is load-bearing: reporting that as a *language* problem
    /// would send a reader to a setting that cannot help them.
    @Test("an ineligible device is never reported as a language problem")
    func ineligibleBeatsLocale() {
        #expect(
            OnDeviceModelReadiness.reading(.unavailable(.deviceNotEligible), supportsLocale: false)
                == .deviceNotEligible
        )
    }

    @Test("every unavailable state has something to say, and ready says nothing")
    func everyStateExplainsItself() {
        for state: OnDeviceModelReadiness in [
            .deviceNotEligible, .notEnabled, .modelNotReady, .languageUnsupported, .unrecognised,
        ] {
            #expect(!state.explanation.isEmpty, "\(state) has no copy")
            #expect(!state.isReady)
        }
        #expect(OnDeviceModelReadiness.ready.explanation.isEmpty)
        #expect(OnDeviceModelReadiness.ready.isReady)
    }

    /// The one reason a reader can act on is the only one that mentions an
    /// action. Pinned because the temptation on the other two is to add "try
    /// again later" to copy describing hardware that will never support it.
    @Test("only the turned-off reason offers a way out")
    func onlyTheActionableOneNamesAnAction() {
        #expect(OnDeviceModelReadiness.notEnabled.explanation.contains("Settings"))
        #expect(!OnDeviceModelReadiness.deviceNotEligible.explanation.contains("Settings"))
    }
}

// MARK: - Failure mapping

@Suite("Generation failures")
struct GenerationFailureTests {

    private func context() -> LanguageModelSession.GenerationError.Context {
        .init(debugDescription: "test")
    }

    /// A guardrail refusal will not un-refuse itself, and offering "Try again"
    /// for one would be offering a button that cannot work — the same rule
    /// `ErrorIssueDetailView` follows by only listing the three statuses PostHog
    /// accepts on a write.
    @Test("a refusal is not retryable and says the model declined")
    func refusalIsTerminal() {
        let failure = OnDeviceSummaryStore.failure(
            for: LanguageModelSession.GenerationError.guardrailViolation(context())
        )
        #expect(!failure.canRetry)
        #expect(failure.text.contains("declined"))
    }

    @Test("a busy device is retryable and is not called a rate limit")
    func busyDeviceIsRetryable() {
        let failure = OnDeviceSummaryStore.failure(
            for: LanguageModelSession.GenerationError.rateLimited(context())
        )
        #expect(failure.canRetry)
        // "Rate limited" means the organisation-wide PostHog budget everywhere
        // else in this app. Reusing the phrase here would tell a reader their
        // production pipeline was being throttled by a summary that never left
        // the device.
        #expect(!failure.text.lowercased().contains("rate limit"))
    }

    @Test("assets still downloading is retryable, a context overflow is not")
    func retryabilityFollowsTheCause() {
        #expect(
            OnDeviceSummaryStore.failure(
                for: LanguageModelSession.GenerationError.assetsUnavailable(context())
            ).canRetry
        )
        #expect(
            !OnDeviceSummaryStore.failure(
                for: LanguageModelSession.GenerationError.exceededContextWindowSize(context())
            ).canRetry
        )
    }

    @Test("an error that isn't a generation error still produces something to read")
    func foreignErrorsStillRead() {
        struct Odd: Error {}
        let failure = OnDeviceSummaryStore.failure(for: Odd())
        #expect(!failure.text.isEmpty)
        #expect(failure.canRetry)
    }
}

// MARK: - The issue brief

@Suite("Error issue brief")
struct IssueSummaryBriefTests {

    private func issue() -> ErrorIssue {
        ErrorIssue(
            id: "018f3300-0000-7000-8000-000000000901",
            name: "SyntheticStateError",
            issueDescription: "Example state entry is missing",
            library: "example-sdk",
            function: "applyExampleUpdate"
        )
    }

    private func frame(
        name: String,
        file: String,
        line: Int,
        inApp: Bool = true,
        resolved: Bool = true
    ) -> StackFrame {
        StackFrame(
            rawID: "\(name)-\(line)",
            isResolved: resolved,
            resolvedName: resolved ? name : nil,
            mangledName: name,
            source: file,
            line: line,
            column: 10,
            isInApp: inApp
        )
    }

    private func occurrence(frames: [StackFrame], value: String = "Example state entry is missing")
        -> ExceptionOccurrence
    {
        ExceptionOccurrence(
            id: "018f3300-0000-7000-8000-000000000912",
            timestamp: Date(timeIntervalSince1970: 1_784_000_000),
            level: "error",
            chain: ExceptionChain(exceptions: [
                ExceptionEntry(
                    type: "SyntheticStateError",
                    value: value,
                    mechanism: ExceptionMechanism(type: "onerror", handled: false),
                    stack: StackTrace(kind: .resolved, frames: frames)
                )
            ])
        )
    }

    /// The prompt is the whole feature's input, so what is in it is pinned.
    @Test("carries the class, the message and the frames")
    func carriesTheException() {
        let brief = IssueSummaryBrief.make(
            issue: issue(),
            occurrence: occurrence(frames: [frame(name: "applyExampleUpdate", file: "state_store.ts", line: 17)])
        )
        #expect(brief.prompt.contains("SyntheticStateError"))
        #expect(brief.prompt.contains("Example state entry is missing"))
        #expect(brief.prompt.contains("applyExampleUpdate"))
        #expect(brief.prompt.contains("state_store.ts:17:10"))
        #expect(brief.prompt.contains("Nothing caught this"))
    }

    /// The reason this test exists is the reason the counts are absent from the
    /// brief at all: a model handed a figure restates it, and a restated figure
    /// inside generated prose is indistinguishable from one PostHog returned.
    /// `ErrorIssue`'s three aggregate counts are the numbers at the top of the
    /// same screen, and none of them may reach the model.
    @Test("hands the model no figures to restate")
    func carriesNoCounts() {
        let brief = IssueSummaryBrief.make(
            issue: issue(),
            occurrence: occurrence(frames: [frame(name: "applyExampleUpdate", file: "state_store.ts", line: 17)])
        )
        for word in ["occurrence", "session", "user", "affected"] {
            #expect(
                !brief.prompt.lowercased().contains(word),
                "the prompt mentions \(word), which invites a fabricated figure"
            )
        }
        #expect(brief.instructions.contains("Never invent"))
    }

    /// A minified frame's position is in the shipped bundle. The UI says so with
    /// a pill; the *prompt* has to say so in words, or the model writes a
    /// sentence pointing the reader at a line of their source that does not
    /// exist.
    @Test("tells the model which frames are minified")
    func labelsMinifiedFramesForTheModel() {
        let brief = IssueSummaryBrief.make(
            issue: issue(),
            occurrence: occurrence(frames: [
                frame(name: "M", file: "synthetic_chunk.js", line: 1, resolved: false)
            ])
        )
        #expect(brief.prompt.contains("minified"))
        #expect(brief.prompt.contains("not in the original source"))
    }

    @Test("prefers in-app frames and caps how many go in")
    func boundsTheStack() {
        let inApp = (1...20).map { frame(name: "mine\($0)", file: "app.ts", line: $0) }
        let library = (1...20).map {
            frame(name: "vendor\($0)", file: "vendor.js", line: $0, inApp: false)
        }
        let brief = IssueSummaryBrief.make(
            issue: issue(),
            occurrence: occurrence(frames: inApp + library)
        )
        #expect(!brief.prompt.contains("vendor1 "))
        #expect(brief.prompt.contains("mine1 "))
        #expect(!brief.prompt.contains("mine\(IssueSummaryBrief.frameLimit + 1) "))
        // …and the reader is told the model saw fewer frames than they can.
        #expect(brief.scope.contains("\(IssueSummaryBrief.frameLimit) of 40"))
    }

    /// The fallback `ExceptionEntryView.visibleFrames` makes for the same
    /// reason: a stack where every frame is third-party is still the only stack
    /// there is, and showing the model none of it would be worse than showing it
    /// somebody else's code.
    @Test("falls back to the whole stack when nothing is marked in-app")
    func allLibraryStackStillGoesIn() {
        let brief = IssueSummaryBrief.make(
            issue: issue(),
            occurrence: occurrence(frames: [
                frame(name: "vendorOnly", file: "vendor.js", line: 4, inApp: false)
            ])
        )
        #expect(brief.prompt.contains("vendorOnly"))
        #expect(brief.prompt.contains("library code"))
    }

    @Test("a long message is cut on a word boundary, not mid-word")
    func boundsTheMessage() {
        let long = String(repeating: "diagnostic detail ", count: 200)
        let brief = IssueSummaryBrief.make(issue: issue(), occurrence: occurrence(frames: [], value: long))
        #expect(brief.prompt.count < long.count)
        #expect(brief.prompt.contains("…"))
        #expect(!brief.prompt.contains("diagnosti…"))
    }

    /// Three different absences, and the scope line has to tell them apart —
    /// the same discipline `ErrorIssueDetailView.unavailableStack` applies to a
    /// failed query, an empty one and an unreachable project.
    @Test("the scope line says what the model was actually shown")
    func scopeTracksTheInput() {
        let none = IssueSummaryBrief.make(issue: issue(), occurrence: nil)
        #expect(none.scope.contains("no stack trace"))

        let empty = IssueSummaryBrief.make(issue: issue(), occurrence: occurrence(frames: []))
        #expect(empty.scope.contains("no stack frames"))

        let whole = IssueSummaryBrief.make(
            issue: issue(),
            occurrence: occurrence(frames: [frame(name: "one", file: "a.ts", line: 1)])
        )
        #expect(whole.scope.contains("all 1 stack frame"))
        #expect(!whole.scope.contains("frames."))
    }

    @Test("the answer is bounded")
    func boundsTheAnswer() {
        let brief = IssueSummaryBrief.make(issue: issue(), occurrence: nil)
        #expect(brief.maximumResponseTokens > 0)
        #expect(brief.maximumResponseTokens <= 400)
    }
}

// MARK: - The survey brief

@Suite("Survey answer brief")
struct AnswerSummaryBriefTests {

    @Test("a handful of answers is not a batch worth summarising")
    func thresholdMatchesTheScreen() {
        #expect(AnswerSummaryBrief.minimumAnswers == 4)
        // Which is `SurveyTextAnswersView.inlineLimit + 1`: the "All N answers"
        // screen only exists past the inline limit, so the summary and the
        // screen that hosts it appear together.
        #expect(AnswerSummaryBrief.minimumAnswers == SurveyTextAnswersView.inlineLimit + 1)
    }

    @Test("carries the question and every answer it was given")
    func carriesTheAnswers() {
        let brief = AnswerSummaryBrief.make(
            question: "What would you change?",
            texts: ["Slow on mobile", "Pricing page is confusing", "Love the charts", "More filters"]
        )
        #expect(brief.prompt.contains("What would you change?"))
        #expect(brief.prompt.contains("Pricing page is confusing"))
        #expect(brief.scope.contains("all 4"))
    }

    /// The screen this sits on already carries counted figures — impressions,
    /// responses, a distribution per question. A generated "about half mentioned
    /// pricing" beside them would be unattributable. The instructions forbid it
    /// in several spellings on purpose.
    @Test("forbids the model from quantifying anything")
    func forbidsCounting() {
        let brief = AnswerSummaryBrief.make(question: "Why?", texts: ["a", "b", "c", "d"])
        for phrase in ["percentage", "proportion", "majority", "Do not rank"] {
            #expect(brief.instructions.contains(phrase))
        }
    }

    @Test("caps the batch and says so")
    func boundsTheBatch() {
        let many = (1...200).map { "Answer number \($0) about the export flow" }
        let brief = AnswerSummaryBrief.make(question: "Why?", texts: many)
        #expect(brief.prompt.contains("Answer number 1 "))
        #expect(!brief.prompt.contains("Answer number \(AnswerSummaryBrief.answerLimit + 1) "))
        #expect(brief.scope.contains("\(AnswerSummaryBrief.answerLimit) most recent of 200"))
    }

    /// One essay must not spend the whole budget. Both caps are exercised at
    /// once here: the per-answer cut and the total character budget.
    @Test("one long answer cannot crowd out the rest")
    func boundsOneAnswer() {
        let essay = String(repeating: "the export flow is genuinely painful ", count: 300)
        let brief = AnswerSummaryBrief.make(
            question: "Why?",
            texts: [essay, "short one", "another short one", "a third"]
        )
        #expect(brief.prompt.count < AnswerSummaryBrief.characterBudget + 1_000)
        #expect(brief.prompt.contains("another short one"))
    }

    /// A pasted stack trace inside a survey answer is a real thing people do,
    /// and unflattened it spends the budget on blank lines.
    @Test("collapses whitespace inside an answer")
    func flattensAnswers() {
        let brief = AnswerSummaryBrief.make(
            question: "Why?",
            texts: ["line one\n\n\n   line two", "b", "c", "d"]
        )
        #expect(brief.prompt.contains("line one line two"))
    }

    @Test("an empty answer contributes nothing rather than a blank bullet")
    func skipsEmptyAnswers() {
        let brief = AnswerSummaryBrief.make(question: "Why?", texts: ["   ", "real", "b", "c"])
        #expect(!brief.prompt.contains("- \n"))
        #expect(brief.scope.contains("3 most recent of 4"))
    }
}

// MARK: - Text bounding

@Suite("Summary text bounding")
struct SummaryTextTests {

    @Test("cuts on a word boundary when there is a usable one")
    func cutsOnWords() {
        #expect(SummaryText.truncated("alpha beta gamma delta", to: 12) == "alpha beta…")
    }

    /// A single long token has no boundary to cut on, and refusing to cut it
    /// would defeat the budget entirely.
    @Test("cuts mid-token when the only space is too early")
    func cutsHardWhenItMust() {
        let cut = SummaryText.truncated("a bbbbbbbbbbbbbbbbbbbbbbbbbbbb", to: 10)
        #expect(cut.count == 11)  // 10 characters plus the ellipsis
        #expect(cut.hasSuffix("…"))
    }

    @Test("leaves anything inside the budget alone")
    func leavesShortTextAlone() {
        #expect(SummaryText.truncated("short", to: 50) == "short")
        #expect(!SummaryText.truncated("short", to: 50).hasSuffix("…"))
    }

    /// A deterministic example of markdown-shaped model output. `Text` does not
    /// interpret these markers, so the sanitiser must remove them itself.
    @Test("flattens markdown-shaped model output")
    func flattensSyntheticMarkdown() {
        let synthetic = """
            **SyntheticStateError** in the `applyExampleUpdate` function.

            **Cause:** The example state entry is missing.

            **Location:** `state_store.ts:17:10`
            """
        let plain = SummaryText.plainProse(synthetic)
        #expect(!plain.contains("*"))
        #expect(!plain.contains("`"))
        #expect(!plain.contains("\n"))
        #expect(plain.hasPrefix("SyntheticStateError in the applyExampleUpdate function."))
    }

    @Test("drops bullets and headings without dropping their words")
    func dropsStructureNotContent() {
        let plain = SummaryText.plainProse("## Summary\n- first point\n* second point")
        #expect(plain == "Summary first point second point")
    }

    /// A sanitiser that mangles identifiers would corrupt the one kind of word
    /// this feature most needs to keep intact.
    @Test("leaves snake_case identifiers alone")
    func keepsIdentifiers() {
        let plain = SummaryText.plainProse("The `$exception_list` property and resolve_failure.")
        #expect(plain.contains("$exception_list"))
        #expect(plain.contains("resolve_failure"))
    }

    @Test("is a no-op on prose that was already prose")
    func leavesProseAlone() {
        let prose = "A reference to Instances is missing, so the list never rendered."
        #expect(SummaryText.plainProse(prose) == prose)
    }
}

// MARK: - The live model

/// The only suite here that runs the model, and it runs it for real.
///
/// Gated on `OnDeviceModel.readiness()`, so on hardware or a simulator host
/// without Apple Intelligence these are **skipped** and the log says so. That is
/// deliberate: a summarisation path that has never executed must not be reported
/// as one that works, and a conditionally-green test is exactly how that lie
/// gets told.
@MainActor
@Suite(
    "Live on-device generation",
    .enabled(if: OnDeviceModel.readiness().isReady, "Apple Intelligence is not available here")
)
struct LiveOnDeviceModelTests {

    @Test("streams a summary of a synthetic exception and settles on finished text")
    func summarisesAnException() async {
        let store = OnDeviceSummaryStore()
        let brief = IssueSummaryBrief.make(
            issue: ErrorIssue(
                id: "018f3300-0000-7000-8000-000000000901",
                name: "SyntheticStateError",
                issueDescription: "Example state entry is missing",
                library: "example-sdk"
            ),
            occurrence: ExceptionOccurrence(
                id: "018f3300-0000-7000-8000-000000000912",
                timestamp: Date(timeIntervalSince1970: 1_784_000_000),
                level: "error",
                chain: ExceptionChain(exceptions: [
                    ExceptionEntry(
                        type: "SyntheticStateError",
                        value: "Example state entry is missing",
                        mechanism: ExceptionMechanism(type: "onerror", handled: false),
                        stack: StackTrace(
                            kind: .resolved,
                            frames: [
                                StackFrame(
                                    isResolved: true,
                                    resolvedName: "applyExampleUpdate",
                                    source: "src/state_store.ts",
                                    line: 17,
                                    column: 10,
                                    isInApp: true
                                )
                            ]
                        )
                    )
                ])
            )
        )

        await store.run(brief)

        guard case .finished(let text) = store.phase else {
            Issue.record("expected finished text, got \(store.phase)")
            return
        }
        #expect(!text.isEmpty)
        // Two to four sentences, capped at 220 tokens. This is a sanity bound on
        // the option actually taking effect, not a judgement of the prose.
        #expect(text.count < 2_000)
    }

    @Test("summarises a batch of free-text answers")
    func summarisesAnswers() async {
        // Authored answers only. The fixture is deterministic and contains no
        // customer response data, matching `SurveyResultsScreenTests`.
        let store = OnDeviceSummaryStore()
        let brief = AnswerSummaryBrief.make(
            question: "What would you change about GetHog?",
            texts: [
                "The export flow takes far too many taps.",
                "Exports are buried. I gave up looking twice.",
                "Charts are lovely but I can't get the data out.",
                "Would pay for CSV export from the phone.",
                "Honestly it's great, just slow on older devices.",
            ]
        )

        await store.run(brief)

        guard case .finished(let text) = store.phase else {
            Issue.record("expected finished text, got \(store.phase)")
            return
        }
        #expect(!text.isEmpty)
    }

    /// Cancellation is the requirement a stalled screen depends on, so it is
    /// exercised rather than assumed: the store must end `.idle`, holding no
    /// half-written text that a reader could mistake for a finished summary.
    @Test("a cancelled run keeps no partial text")
    func cancellationClearsThePartial() async {
        let store = OnDeviceSummaryStore()
        let brief = AnswerSummaryBrief.make(
            question: "Why?",
            texts: (1...20).map { "Answer \($0): the export flow needs work." }
        )

        let task = Task { @MainActor in await store.run(brief) }
        // Long enough for the session to have started and short enough that it
        // cannot have finished; the model's first token takes seconds.
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await task.value

        #expect(store.phase == .idle)
    }
}
