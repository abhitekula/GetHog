import Foundation
import FoundationModels
import Observation

/// Everything one summary is made of: what the model is told to do, what it is
/// given, and — the part that is not decoration — the sentence naming exactly
/// what it was given.
///
/// `scope` travels *inside* the brief rather than beside it at the call site so
/// that the two cannot drift. A card that says "read from the exception and its
/// top frames" while the prompt actually carried no frames would be the same
/// class of defect as a chart whose axis label does not describe its axis, and
/// this app treats that as a bug rather than as copy.
struct SummaryBrief: Equatable, Sendable {
    /// The session's standing instructions. Constant per feature, so the model
    /// is never asked to infer its job from the data.
    let instructions: String
    /// The data, already bounded and flattened to text by the caller.
    let prompt: String
    /// Hard ceiling on the answer. A phone screen cannot use more, and an
    /// unbounded generation is the easiest way to strand a screen.
    let maximumResponseTokens: Int
    /// One sentence, shown under the summary, naming what went into `prompt`.
    let scope: String
}

/// A summary that could not be produced, in the reader's terms.
struct SummaryFailure: Equatable, Sendable {
    let text: String
    /// False for the failures that would fail again in exactly the same way.
    /// Offering "Try again" for a guardrail refusal would be offering a button
    /// that cannot work — the same reason `ErrorIssueDetailView` only offers the
    /// three statuses PostHog accepts on a write.
    let canRetry: Bool
}

/// Runs one on-device summarisation and holds what it has produced so far.
///
/// **Nothing here touches the network.** `LanguageModelSession` hands the prompt
/// to the operating system's on-device inference service; no request leaves the
/// device, and — as far as this app is concerned — no PostHog rate-limit budget
/// is spent. That is the whole reason this feature exists in a client that has
/// ruled out other ideas for wanting a server: the organisation-wide limits
/// described in `CLAUDE.md` are untouched by it. The data does cross a process
/// boundary (into that system service, over XPC) and it is worth being exact
/// about that rather than claiming it never leaves the app.
///
/// **Streaming, and why it is not optional.** First-token latency for this model
/// is seconds, not milliseconds, and a phone screen with a spinner on it for
/// that long reads as a hang. The store publishes the cumulative snapshot on
/// every tick, so the card fills in as the sentence is written.
///
/// **Cancellation.** `run(_:)` is meant to be called from `.task(id:)`, so
/// SwiftUI cancels it when the view goes away and when the request token
/// changes. Cancellation lands as `CancellationError` out of the stream and
/// leaves the store `.idle` — deliberately *not* holding the partial text. A
/// half-written summary kept on screen after the reader backed out would be the
/// one thing this feature must never produce: generated prose that looks
/// finished and is not.
@MainActor
@Observable
final class OnDeviceSummaryStore {

    enum Phase: Equatable {
        case idle
        /// The cumulative text so far. Not a finished summary; the card says so.
        case streaming(String)
        case finished(String)
        case failed(SummaryFailure)
    }

    private(set) var phase: Phase = .idle

    /// Seconds without a new snapshot before the screen stops waiting.
    ///
    /// Generous on purpose: the first snapshot arrives only after the model has
    /// been loaded, which on a cold start is the slowest part of the whole
    /// operation. This is a guard against a stalled service, not a latency
    /// budget.
    static let stallLimit: TimeInterval = 30

    private var lastProgress = Date.distantPast
    /// The in-flight generation, held only so the watchdog can end it.
    private var streamingTask: Task<Void, any Error>?
    /// Set by the watchdog before it cancels, so `run` can tell a timeout from
    /// the reader leaving the screen.
    private var stalled = false

    var isBusy: Bool {
        if case .streaming = phase { return true }
        return false
    }

    /// The text a reader can act on, or `nil` while there is none.
    var settledText: String? {
        if case .finished(let text) = phase { return text }
        return nil
    }

    func reset() { phase = .idle }

    /// Generates one summary, streaming it into `phase`.
    ///
    /// **Why this is two unstructured tasks and not a task group.** A task group
    /// is the obvious shape — two children sharing one cancellation scope — and
    /// it does not compile here. `group.addTask { @MainActor in … }` capturing a
    /// `@MainActor`, non-`Sendable` store is rejected by Swift 6.0 with
    /// *"pattern that the region-based isolation checker does not understand how
    /// to check. Please file a bug"* (measured against Xcode 26.6, build 17F113,
    /// on both closures, whether `self` was captured strongly or weakly). So the
    /// two run as `Task`s, which inherit this actor's isolation, and
    /// `withTaskCancellationHandler` forwards the caller's cancellation into the
    /// streaming one — the part a task group would have given for free.
    ///
    /// The watchdog cancels the stream rather than reporting separately, so
    /// there is exactly one way this ends early. `stalled` is what tells a
    /// timeout apart from the reader backing out of the screen; both arrive here
    /// as `CancellationError` and they are not the same event.
    func run(_ brief: SummaryBrief) async {
        phase = .streaming("")
        lastProgress = Date()
        stalled = false

        let streaming = Task { try await self.consume(brief) }
        streamingTask = streaming
        let watchdog = Task { await self.watchForStall() }
        defer {
            watchdog.cancel()
            streamingTask = nil
        }

        do {
            try await withTaskCancellationHandler {
                try await streaming.value
            } onCancel: {
                streaming.cancel()
            }
        } catch is CancellationError {
            phase = stalled
                ? .failed(
                    SummaryFailure(
                        text: "The on-device model stopped responding, so the summary was abandoned. Nothing was sent anywhere and nothing on this screen has changed.",
                        canRetry: true
                    )
                )
                : .idle
        } catch {
            phase = .failed(Self.failure(for: error))
        }
    }

    private func consume(_ brief: SummaryBrief) async throws {
        // A session per run. These are cheap, and a fresh one means the model
        // never sees the previous issue's stack or the previous survey's
        // answers — a multi-turn transcript here would be a way for one
        // customer's data to end up in a summary of another's.
        let session = LanguageModelSession(instructions: brief.instructions)

        let stream = session.streamResponse(
            to: brief.prompt,
            options: GenerationOptions(
                // Low, and chosen rather than defaulted. This is a précis of
                // text that is already on the screen; the reader wants the same
                // answer twice, not a differently-worded one, and a warmer
                // sample is exactly where a small model starts inventing file
                // names and causes.
                temperature: 0.2,
                maximumResponseTokens: brief.maximumResponseTokens
            )
        )

        var text = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            // Cleaned per snapshot rather than once at the end: the snapshot is
            // cumulative, so a `**` that survived to the screen would sit there
            // for the rest of the generation. See `SummaryText.plainProse` for
            // what this removes and the measured reason it has to exist at all.
            text = SummaryText.plainProse(snapshot.content)
            lastProgress = Date()
            phase = .streaming(text)
        }
        try Task.checkCancellation()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Not observed — every generation run during this work produced
            // text. Handled anyway because the alternative is a card that draws
            // its heading, its pill and its provenance lines around nothing,
            // which is indistinguishable from a broken screen.
            phase = .failed(
                SummaryFailure(
                    text: "The model finished without writing anything.",
                    canRetry: true
                )
            )
        } else {
            phase = .finished(trimmed)
        }
    }

    private func watchForStall() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                // Cancelled, which is the ordinary way this loop ends — the
                // stream finished first.
                return
            }
            if Date().timeIntervalSince(lastProgress) > Self.stallLimit {
                stalled = true
                streamingTask?.cancel()
                return
            }
        }
    }

    // MARK: - Failures

    /// Turns a `GenerationError` into something worth showing.
    ///
    /// **None of these branches has been observed firing.** They are written
    /// from `LanguageModelSession.GenerationError`'s own case list, and the only
    /// path exercised during this work was the successful one plus a
    /// deliberately cancelled run. Marked here for the same reason the demo
    /// fixtures derived from a schema are marked: a branch nobody has seen is
    /// not a branch anybody should describe as working.
    /// `nonisolated` because it is a pure mapping and nothing about it needs the
    /// main actor — which also makes it reachable from a test that is not
    /// pretending to be a screen.
    nonisolated static func failure(for error: any Error) -> SummaryFailure {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return SummaryFailure(
                text: "The summary couldn't be generated. \(error.localizedDescription)",
                canRetry: true
            )
        }

        switch generation {
        case .guardrailViolation, .refusal:
            // Entirely plausible on this data. Exception messages and survey
            // answers are written by people who were angry at the time, and
            // Apple's safety filter runs over both the input and the output.
            // The reader has to be told that the *model* declined, not that
            // GetHog broke, or they will retry forever.
            return SummaryFailure(
                text: "Apple's on-device model declined to summarise this content. The data itself is unaffected and is shown in full above.",
                canRetry: false
            )
        case .exceededContextWindowSize:
            return SummaryFailure(
                text: "There was too much text for the on-device model to take in at once.",
                canRetry: false
            )
        case .unsupportedLanguageOrLocale:
            return SummaryFailure(
                text: "The on-device model doesn't handle this language yet.",
                canRetry: false
            )
        case .assetsUnavailable:
            return SummaryFailure(
                text: "The on-device model isn't ready — its assets may still be downloading.",
                canRetry: true
            )
        case .rateLimited, .concurrentRequests:
            // Not PostHog's rate limit. Worth saying, because "rate limited" in
            // this app means the organisation-wide budget and this is nothing
            // of the kind.
            return SummaryFailure(
                text: "The device is busy with another Apple Intelligence request. Try again in a moment.",
                canRetry: true
            )
        case .decodingFailure, .unsupportedGuide:
            return SummaryFailure(
                text: "The on-device model returned something GetHog couldn't read.",
                canRetry: true
            )
        @unknown default:
            return SummaryFailure(
                text: "The summary couldn't be generated. \(generation.localizedDescription)",
                canRetry: true
            )
        }
    }
}
