import GetHogKit
import SwiftUI

/// A whole exception chain, rendered.
///
/// Three decisions shape this file, and all three come from what the payload
/// actually contains rather than from what a stack trace is supposed to look
/// like.
///
/// **1. Collapsed to in-app frames.** A phone can show only a few frames without
/// scrolling, and the editable frames are usually most useful. Framework frames
/// remain one tap away, and the visible count makes the choice explicit.
///
/// **2. The top frame is the headline.** It gets its own block above the list,
/// because on a narrow screen the difference between "the first row" and "the
/// thing that threw" is not visible, and it is the only row most triage needs.
///
/// **3. Unresolved frames say so.** A minified frame can still carry a filename
/// and line number from the shipped bundle rather than source. Each such frame
/// is labelled, tinted differently, and can state the service reason verbatim.
struct StackTraceView: View {
    let occurrence: ExceptionOccurrence

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(Array(occurrence.chain.orderedForDisplay.enumerated()), id: \.element.id) {
                index, entry in
                ExceptionEntryView(
                    entry: entry,
                    position: position(at: index),
                    isChained: occurrence.chain.isChained
                )
            }
        }
    }

    private func position(at index: Int) -> ExceptionEntryView.Position {
        guard occurrence.chain.isChained else { return .only }
        return index == 0 ? .thrown : .cause
    }
}

/// One exception in the chain: its class, its message, and its frames.
struct ExceptionEntryView: View {
    enum Position {
        /// The only exception there is.
        case only
        /// The exception that reached the handler.
        case thrown
        /// Something further down the chain that caused it.
        case cause
    }

    let entry: ExceptionEntry
    let position: Position
    let isChained: Bool

    /// Framework frames are hidden until asked for, per exception rather than
    /// per screen: in a chain, the entry worth expanding is rarely the same one
    /// twice.
    @State private var showsAllFrames = false
    @State private var showsFailures = false

    private var frames: [StackFrame] { entry.frames }
    private var inApp: [StackFrame] { frames.filter(\.isInApp) }

    /// What the collapsed view shows.
    ///
    /// Falls back to the whole stack when nothing is marked in-app — a trace
    /// where every frame is third-party is still the only trace there is, and
    /// collapsing it to nothing would incorrectly report no frames.
    private var visibleFrames: [StackFrame] {
        if showsAllFrames || inApp.isEmpty { return frames }
        return inApp
    }

    private var hiddenCount: Int { frames.count - visibleFrames.count }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                if frames.isEmpty {
                    noFramesNote
                } else {
                    minifiedNote
                    frameList
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isChained {
                // The chain is the structure, so it is stated in words rather
                // than implied by indentation — which a narrow screen eats and
                // VoiceOver never sees at all.
                Label(
                    position == .thrown ? "Thrown" : causeTitle,
                    systemImage: position == .thrown ? "exclamationmark.triangle" : "arrow.turn.down.right"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.Ink.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.type)
                    .font(.headline.monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let handled = entry.mechanism?.handled {
                    StatusPill(
                        text: handled ? "Handled" : "Unhandled",
                        tint: handled ? .secondary : Theme.Status.critical
                    )
                }
            }

            if let value = entry.value, !value.isEmpty {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if entry.mechanism?.synthetic == true {
                // A synthetic stack was manufactured by the SDK at the capture
                // site. Its frames are real code, but they are not where the
                // problem is — worth saying before someone reads them as such.
                Text("The SDK generated this stack at the capture point; it isn't a stack the runtime unwound.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenHeader)
    }

    private var causeTitle: String {
        // `mechanism.source` is the attribute the cause hung off — `__cause__`
        // for `raise … from`, `cause` for JS. Naming it tells a reader which
        // language construct made the link.
        if let source = entry.mechanism?.source, !source.isEmpty {
            return "Caused by (\(source))"
        }
        return "Caused by"
    }

    private var spokenHeader: String {
        var parts: [String] = []
        if isChained { parts.append(position == .thrown ? "Thrown exception" : causeTitle) }
        parts.append(entry.type)
        if let value = entry.value, !value.isEmpty { parts.append(value) }
        if let handled = entry.mechanism?.handled {
            parts.append(handled ? "Handled" : "Unhandled")
        }
        return parts.joinedAsSentences()
    }

    // MARK: - Frames

    /// The trace, top frame first.
    ///
    /// The top frame is emphasized in its row rather than duplicated in a
    /// separate block.
    private var frameList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: framesTitle, systemImage: "list.number")
                Spacer(minLength: 8)
                if !inApp.isEmpty, inApp.count < frames.count {
                    Button(showsAllFrames ? "In-app only" : "Show all \(frames.count)") {
                        withAnimation(.snappy) { showsAllFrames.toggle() }
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }

            ForEach(visibleFrames) { frame in
                let isTop = frame.id == frames.first?.id
                VStack(alignment: .leading, spacing: 2) {
                    // Only worth captioning when there is something for the top
                    // frame to be top *of*. On a one-frame stack the caption sat
                    // between "1 frame" and the frame, labelling the obvious.
                    if isTop, visibleFrames.count > 1 {
                        Text("TOP FRAME")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.Ink.secondary)
                            .accessibilityHidden(true)
                    }
                    StackFrameRow(frame: frame, isTop: isTop)
                }
            }

            if hiddenCount > 0 {
                Text("\(hiddenCount) framework frame\(hiddenCount == 1 ? "" : "s") hidden.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
    }

    private var framesTitle: String {
        let shown = visibleFrames.count
        if shown == frames.count {
            return "\(frames.count) frame\(frames.count == 1 ? "" : "s")"
        }
        return "\(shown) of \(frames.count) frames"
    }

    // MARK: - Minified frames

    private var minified: [StackFrame] { frames.filter(\.isMinified) }

    /// The distinct reasons symbolication failed.
    ///
    /// Deduplicated because a reason can repeat across many frames. The
    /// disclosure label is plural-aware so the list stays concise and clear.
    private var resolveFailures: [String] {
        var seen = Set<String>()
        return minified.compactMap { frame -> String? in
            guard let reason = frame.resolveFailure, !reason.isEmpty else { return nil }
            return seen.insert(reason).inserted ? reason : nil
        }
    }

    /// Said once, above the trace, rather than on each row.
    ///
    /// It has to be said *somewhere*: an unresolved frame can resemble a source
    /// position. Each row still carries its own "Minified" pill, so the note says
    /// why and the rows say which.
    @ViewBuilder
    private var minifiedNote: some View {
        if !minified.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(minifiedSummary)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.Status.warningInk)

                if !resolveFailures.isEmpty {
                    DisclosureGroup(isExpanded: $showsFailures) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(resolveFailures.enumerated()), id: \.offset) { _, reason in
                                Text(reason)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.Ink.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text(
                            resolveFailures.count == 1
                                ? "Why PostHog couldn't resolve it"
                                : "Why PostHog couldn't resolve them (\(resolveFailures.count) reasons)"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    }
                    .tint(Theme.accent)
                }
            }
        }
    }

    private var minifiedSummary: String {
        let count = minified.count
        let scope = count == frames.count
            ? "Every frame is"
            : "\(count) of \(frames.count) frames are"
        return "\(scope) minified: the positions below are in the shipped bundle, not in your source."
    }

    private var noFramesNote: some View {
        Text("This exception arrived without a stack trace. Some SDKs capture the message only.")
            .font(.footnote)
            .foregroundStyle(Theme.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One frame: name, position, and what kind of frame it is.
///
/// Monospaced throughout, because every string in it is an identifier and
/// proportional type makes `l`, `1` and `I` the same glyph.
///
/// Deliberately two lines and no prose. An earlier version explained the
/// minified coordinate space on the row. The explanation belongs once above the
/// list; the row keeps the pill identifying which frames it applies to.
struct StackFrameRow: View {
    let frame: StackFrame
    var isTop = false

    private var tint: Color {
        if frame.isMinified { return Theme.accentWarm }
        return frame.isInApp ? Theme.accent : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isTop ? "arrowtriangle.right.fill" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                Text(frame.functionName)
                    .font(.footnote.monospaced().weight(isTop ? .semibold : .regular))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                // Never colour alone: the word carries the fact, for the same
                // reason the issue rows carry a status word next to the glyph.
                if frame.isMinified {
                    StatusPill(text: "Minified", tint: Theme.accentWarm)
                } else if !frame.isInApp {
                    StatusPill(text: "Library", tint: .secondary)
                }
            }

            if let location = frame.locationDescription {
                Text(location)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.Ink.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenFrame)
    }

    /// Speech gets the caveat on every frame it applies to.
    ///
    /// The visual design says it once above the list because a sighted reader
    /// takes the whole card in at a glance. VoiceOver arrives one row at a time,
    /// so the qualifier stays in each applicable accessibility label.
    private var spokenFrame: String {
        var parts: [String] = []
        if isTop { parts.append("Top frame") }
        parts.append(frame.functionName)
        if let location = frame.locationDescription { parts.append(location) }
        if frame.isMinified {
            parts.append("minified, a position in the shipped bundle rather than your source")
        } else if !frame.isInApp {
            parts.append("library frame")
        }
        return parts.joinedAsSentences()
    }
}

/// Breadcrumbs, when the SDK sent any.
///
/// Built to the documented shape and shown only when the data is present; an
/// always-empty "Steps" card would be worse than no card.
struct ExceptionStepsView: View {
    let steps: [ExceptionStep]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(text: "Steps before the error", systemImage: "shoeprints.fill")

                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(step.message ?? "(no message)")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if let timestamp = step.timestamp {
                                Text(timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.Ink.tertiary)
                            }
                        }
                        ForEach(step.customProperties, id: \.key) { property in
                            if let value = property.value.stringValue {
                                Text("\(property.key): \(value)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.Ink.tertiary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
