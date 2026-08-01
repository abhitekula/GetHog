import Foundation
import GetHogKit

/// Builds the brief that turns one error issue into a paragraph.
///
/// **Why this is the highest-value thing to summarise in this app.** Triage is
/// the workflow people actually do from a phone, and the thing that makes it
/// slow on a phone is not the writes — those are two taps — it is working out
/// what the issue *is* from a class name, a message that may be a sentence of
/// framework prose, and a long stack from somebody else's bundle. All of
/// that is already on the screen, so the summary costs no request at all: the
/// organisation-wide PostHog rate limit that shapes every other feature here is
/// untouched by it.
///
/// **What is deliberately not in the prompt: numbers.**
/// `ErrorIssue` carries occurrence, session and user counts, and they are the
/// three figures at the top of the screen. None of them is given to the model.
/// A small model handed an aggregate figure may restate it, round it, or
/// attach it to the wrong noun, and a restated figure inside generated prose is
/// exactly the thing this app must never produce — a number that looks like it
/// came from PostHog and did not. The instructions forbid inventing figures as
/// well, but the surer defence is having none to copy.
///
/// **What is bounded, and why.** The context window is finite and the phone has
/// to stay responsive, so the chain is capped at three entries, each message at
/// 400 characters and each entry at eight frames — in-app frames first, because
/// those are the ones a reader can act on and the same ones `StackTraceView`
/// shows by default. The `scope` sentence reports what survived those caps, so
/// the reader is told when the model saw less than they can see.
enum IssueSummaryBrief {

    /// How many exceptions in a chain the model is shown.
    static let entryLimit = 3
    /// How many frames per exception.
    static let frameLimit = 8
    /// How much of one exception message.
    static let messageLimit = 400

    /// The format rule comes first and is spelled out in several ways because a
    /// language model may otherwise return markdown headings and field labels.
    /// Rendered through `Text`, those markers become literal punctuation and a
    /// labelled readout that could be mistaken for structured API output.
    /// Leading with the constraint and naming the forbidden characters keeps
    /// the format explicit.
    /// `SummaryText.plainProse` cleans up what still gets through, because an
    /// instruction is a request and a sanitiser is not.
    static let instructions = """
        You explain software errors to an engineer who is triaging them on a phone.

        Answer with a single paragraph of two to four complete sentences.

        Plain sentences only. No markdown. No asterisks, no backticks, no hash \
        marks, no bullet points, no line breaks, and no field labels such as \
        "Cause:" or "Location:". Write the way you would speak the answer aloud.

        Do not announce what you are about to do. Never begin with "Here is a \
        summary" or anything like it — the first word of your answer is the \
        first word of the summary.

        Say what the error is, in ordinary words, and where in the program it \
        came from. If the details point at a likely cause, say so in one clause \
        and make it clear it is a guess.

        Use only the details you are given. Never invent a file name, a function \
        name, a line number, a count, a percentage or a date. Do not state any \
        number that is not in the input. Do not claim to know how many people or \
        how often it happened — you have not been told.

        If the details are too thin to say anything useful, say that in one \
        sentence instead of guessing.
        """

    /// The brief for one issue, with whatever occurrence has been loaded.
    ///
    /// `occurrence` is optional because the frames are a second request that may
    /// still be in flight, may have failed, or may legitimately have found
    /// nothing — PostHog keeps issues longer than the events behind them. All
    /// three end in the same place here: a summary built from the issue row
    /// alone, saying so.
    static func make(issue: ErrorIssue, occurrence: ExceptionOccurrence?) -> SummaryBrief {
        var lines: [String] = []
        var framesShown = 0
        var framesAvailable = 0

        lines.append("Error class: \(issue.name)")
        if let description = issue.issueDescription.map(SummaryText.trimmed), !description.isEmpty {
            lines.append("Message: \(SummaryText.truncated(description, to: messageLimit))")
        }
        if let library = issue.library.map(SummaryText.trimmed), !library.isEmpty {
            lines.append("Reported by SDK: \(library)")
        }
        if let function = issue.function.map(SummaryText.trimmed), !function.isEmpty {
            lines.append("Reported in function: \(function)")
        }

        if let occurrence {
            if let level = occurrence.level.map(SummaryText.trimmed), !level.isEmpty {
                lines.append("Severity as recorded: \(level)")
            }

            let entries = Array(occurrence.chain.orderedForDisplay.prefix(entryLimit))
            for (index, entry) in entries.enumerated() {
                lines.append("")
                lines.append(index == 0 ? "Exception thrown:" : "Caused by:")
                lines.append("  Type: \(entry.type)")
                if let value = entry.value.map(SummaryText.trimmed), !value.isEmpty {
                    lines.append("  Message: \(SummaryText.truncated(value, to: messageLimit))")
                }
                if let handled = entry.mechanism?.handled {
                    lines.append(
                        handled
                            ? "  The program caught this itself."
                            : "  Nothing caught this; it reached the top of the stack."
                    )
                }
                if entry.mechanism?.synthetic == true {
                    lines.append("  The SDK manufactured this stack at the capture point; it is not a stack the runtime unwound.")
                }

                let selected = frames(of: entry)
                framesAvailable += entry.frames.count
                framesShown += selected.count
                if selected.isEmpty {
                    lines.append("  No stack frames were captured.")
                } else {
                    lines.append("  Stack, innermost first:")
                    for frame in selected {
                        lines.append("    \(describe(frame))")
                    }
                }
            }
        }

        return SummaryBrief(
            instructions: instructions,
            // No imperative preamble: the instructions already say what the
            // job is, so the prompt only has to say what the thing is.
            prompt: """
                The error:

                \(lines.joined(separator: "\n"))
                """,
            // Two to four sentences. 220 tokens is roughly twice that, which
            // leaves headroom for a verbose run without letting a runaway one
            // fill the screen.
            maximumResponseTokens: 220,
            scope: scope(
                hasOccurrence: occurrence != nil,
                framesShown: framesShown,
                framesAvailable: framesAvailable
            )
        )
    }

    /// In-app frames first, then the rest, capped — the same preference
    /// `ExceptionEntryView` renders, so the model reads what the reader reads.
    ///
    /// Falls back to the whole stack when nothing is marked in-app, for the
    /// reason `ExceptionEntryView.visibleFrames` gives: a trace where every
    /// frame is third-party is still the only trace there is.
    private static func frames(of entry: ExceptionEntry) -> [StackFrame] {
        let inApp = entry.frames.filter(\.isInApp)
        let ordered = inApp.isEmpty ? entry.frames : inApp
        return Array(ordered.prefix(frameLimit))
    }

    /// One frame as a line the model can read.
    ///
    /// A minified frame is labelled as such in the *text handed to the model*,
    /// not only in the UI. Without it the model would read
    /// `applyUpdate at chunk.js:878:31` as a position in the reader's source and
    /// write a sentence pointing them at a line that does not exist there —
    /// the precise misreading the "Minified" pill exists to prevent on screen.
    private static func describe(_ frame: StackFrame) -> String {
        var text = frame.functionName
        if let location = frame.locationDescription {
            text += " at \(location)"
        }
        if frame.isMinified {
            text += " [minified: this position is in the shipped bundle, not in the original source]"
        } else if !frame.isInApp {
            text += " [library code]"
        }
        return text
    }

    private static func scope(
        hasOccurrence: Bool,
        framesShown: Int,
        framesAvailable: Int
    ) -> String {
        guard hasOccurrence else {
            return "Read from this issue's class, message and reporting SDK only — no stored occurrence was loaded, so the model saw no stack trace."
        }
        if framesShown == 0 {
            return "Read from this issue's exception type and message. The occurrence carried no stack frames."
        }
        if framesShown < framesAvailable {
            return "Read from this issue's exception type, message and \(framesShown) of \(framesAvailable) stack frames."
        }
        return "Read from this issue's exception type, message and all \(framesShown) stack frame\(framesShown == 1 ? "" : "s")."
    }
}

/// Text handling shared by the two briefs.
///
/// An `enum` rather than an `extension String`, because `trimmed` and
/// `truncated(to:)` are names two people would independently add to the app
/// target and a redeclaration is a build break in somebody else's file.
enum SummaryText {

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts to a character budget on a word boundary where there is one.
    ///
    /// The word boundary is not cosmetic: a message cut mid-word reads to a
    /// language model as a *different* word, and this is precisely the text it
    /// is being asked to be accurate about. The half-limit floor stops a string
    /// with one early space from being cut to almost nothing.
    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) > limit / 2 {
            return head[..<space] + "…"
        }
        return head + "…"
    }

    /// Collapses runs of whitespace, so a pasted stack trace inside a survey
    /// answer cannot spend the character budget on blank lines.
    static func flattened(_ text: String) -> String {
        trimmed(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Strips the markdown the model emits anyway.
    ///
    /// **This is not belt and braces; it is the belt.** Both sets of
    /// instructions forbid markdown in their first format paragraph, and both
    /// were written that way *because* the polite version did not hold — see
    /// `IssueSummaryBrief.instructions` for the verbatim output that made the
    /// point. `Text` does not interpret markdown, so anything that gets through
    /// reaches the reader as literal `**` and backticks; and a bolded
    /// `**Cause:**` label would dress a generated guess up as a returned field.
    ///
    /// Deliberately conservative. It removes emphasis and structure markers and
    /// nothing else — no rewrapping, no sentence surgery — so what the reader
    /// sees is still what the model wrote.
    ///
    /// Applied to every streamed snapshot, not just the final text: a partial
    /// snapshot can end mid-marker, and a `**` that appears for one frame and
    /// vanishes is less distracting than one that persists.
    static func plainProse(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map {
            line -> String in
            var stripped = trimmed(String(line))
            // ATX headings, then list markers. Order matters: "## - item" is not
            // something the model has produced, but stripping the heading first
            // means it would still come out as prose if it did.
            while stripped.hasPrefix("#") { stripped.removeFirst() }
            stripped = trimmed(stripped)
            for marker in ["- ", "* ", "+ ", "• "] where stripped.hasPrefix(marker) {
                stripped.removeFirst(marker.count)
                break
            }
            return trimmed(stripped)
        }

        // Joined with a space rather than a newline: the instructions ask for one
        // paragraph, and a model that answered in three should not get a layout
        // that rewards it.
        var joined = lines.filter { !$0.isEmpty }.joined(separator: " ")
        // Paired markers and backticks only. A **lone** asterisk or underscore is
        // left alone on purpose: `$exception_list`, `raw_id`, `in_app` and
        // `__cause__` are all names this feature's own input contains, and a
        // sanitiser that turned `resolve_failure` into `resolvefailure` would
        // corrupt the one kind of word the summary most needs to get right.
        // `__cause__` survives as `cause`, which is the accepted cost of
        // stripping the paired form.
        for marker in ["**", "__", "`"] {
            joined = joined.replacingOccurrences(of: marker, with: "")
        }
        return trimmed(joined)
    }
}
