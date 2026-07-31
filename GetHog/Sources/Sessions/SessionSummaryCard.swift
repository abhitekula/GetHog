import GetHogKit
import SwiftUI

// MARK: - Shared vocabulary

/// How an outcome is drawn.
///
/// A word and a glyph, always — the tint is the third signal, never the only
/// one. "Did not finish" rather than "Failed" is deliberate: the model is
/// reporting that a person did not get where they were going, which is a fact
/// about the product, not a verdict on the user or an incident to be alarmed by.
enum SessionOutcomeStyle {
    static func title(_ outcome: SessionOutcome?) -> String {
        outcome?.title ?? "Not judged"
    }

    static func systemImage(_ outcome: SessionOutcome?) -> String {
        switch outcome?.succeeded {
        case true: "checkmark.circle.fill"
        case false: "xmark.circle.fill"
        case nil: "questionmark.circle"
        }
    }

    static func tint(_ outcome: SessionOutcome?) -> Color {
        switch outcome?.succeeded {
        case true: Theme.Status.good
        // Warm, not critical red. Red is kept for exceptions — things that
        // actually broke — so that a screen full of unfinished sessions does not
        // read as a screen full of outages.
        case false: Theme.accentWarm
        // The app's own neutral ink rather than `.secondary`: this tints a pill's
        // word *and* its capsule, and `.secondary` put that pair at 3.2:1.
        case nil: Theme.Ink.secondary
        }
    }
}

/// The frustration score, banded.
///
/// **The range is not documented.** Across the live capture the score took the
/// values 0.0, 0.4, 0.6 and 0.7, and the signal intensities behind it ran 0.3 to
/// 0.9 — a 0…1 reading at one decimal place. `SessionSentiment` clamps to that
/// range for safety, and this states the number as well as the band so a reader
/// is never left interpreting a bar on its own.
enum FrustrationBand {
    static func title(_ score: Double) -> String {
        switch score {
        case ..<0.05: "None reported"
        case ..<0.34: "Low"
        case ..<0.67: "Moderate"
        default: "High"
        }
    }

    static func tint(_ score: Double) -> Color {
        score < 0.34 ? Theme.Status.good : (score < 0.67 ? Theme.accentWarm : Theme.Status.critical)
    }
}

// MARK: - Card

/// The AI summary of one session.
///
/// Used in two places from one definition: attached to the existing session
/// screen, where its chapters seek the replay, and on the standalone summary
/// screen, where they are read rather than played. The difference is entirely in
/// whether `onSeek` is supplied.
struct SessionSummaryCard: View {
    let store: SessionSummaryStore
    /// The instant chapter offsets are measured against — the replay's own first
    /// snapshot when one is loaded, so a seek lands on the right frame. See
    /// `SessionSummaryChapter.startOffset(from:)`.
    var origin: Date?
    var canSeek = false
    var onSeek: ((TimeInterval) -> Void)?
    var onRetry: (() -> Void)?

    @State private var expanded: Set<String> = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header

                switch store.state {
                case .idle, .loading:
                    loading
                case .absent:
                    absent
                case .failed(let message):
                    SectionEmptyState(
                        text: "Couldn't load the summary for this session.",
                        systemImage: "exclamationmark.triangle",
                        detail: message,
                        actionTitle: onRetry == nil ? nil : "Try again",
                        action: onRetry
                    )
                case .loaded(let detail):
                    body(for: detail)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "AI summary", systemImage: "text.append")
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if let model = store.detail?.modelUsed {
                // Provenance. This is a model's reading of the session, not a
                // measurement, and the screen should never let that be forgotten.
                Text(model)
                    .font(.caption2)
                    // Measured 1.72:1 on `.tertiary` against this white card. A
                    // provenance stamp nobody can read is the same as no stamp,
                    // and this is the line that stops a model's reading of the
                    // session being mistaken for a measurement of it.
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("The user completed the checkout flow after two attempts.")
                .font(.subheadline)
            Text("Chapter one of four")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
    }

    /// Not an error, and it must not look like one.
    ///
    /// Summaries are generated elsewhere — this client only reads them — so most
    /// sessions have none, and the API says so with a plain 404. A red card here
    /// would misreport the ordinary case on the majority of session screens.
    private var absent: some View {
        SectionEmptyState(
            text: "No AI summary has been generated for this session.",
            systemImage: "text.badge.xmark"
        )
    }

    @ViewBuilder
    private func body(for detail: SessionSummaryDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            outcomeBlock(detail.outcome)

            if let sentiment = detail.sentiment {
                SentimentRow(sentiment: sentiment)
            }

            let chapters = detail.chapters
            if chapters.isEmpty {
                SectionEmptyState(
                    text: "This summary has no chapters.",
                    systemImage: "list.bullet.indent"
                )
            } else {
                Divider()
                chapterList(chapters)
            }
        }
    }

    private func outcomeBlock(_ outcome: SessionOutcome?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: SessionOutcomeStyle.systemImage(outcome))
                    .font(.subheadline)
                    .foregroundStyle(SessionOutcomeStyle.tint(outcome))
                    .accessibilityHidden(true)
                Text(SessionOutcomeStyle.title(outcome))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SessionOutcomeStyle.tint(outcome))
            }
            if let narrative = outcome?.detail, !narrative.isEmpty {
                // The paragraph is the whole point of the feature and gets no
                // line limit: reading it is faster than scrubbing the video it
                // describes, and a truncated one is neither.
                Text(narrative)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func chapterList(_ chapters: [SessionSummaryChapter]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionLabel(text: "Chapters", systemImage: "list.number")
                Spacer()
                if canSeek {
                    Text("Tap a chapter to play it")
                        .font(.caption2)
                        // Measured 1.72:1 on `.tertiary`. This is the only thing
                        // that discloses the rows are tappable at all.
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { position, chapter in
                    SessionChapterRow(
                        number: position + 1,
                        chapter: chapter,
                        offset: chapter.startOffset(from: origin),
                        isLast: position == chapters.count - 1,
                        isExpanded: expanded.contains(chapter.id),
                        canSeek: canSeek,
                        onToggle: { toggle(chapter.id) },
                        onSeek: onSeek
                    )
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

// MARK: - Sentiment

/// How the session felt, in the model's words and its own number.
struct SentimentRow: View {
    let sentiment: SessionSentiment

    /// The meter grows with the text beside it. At accessibility sizes a fixed
    /// 44pt track next to a 40pt numeral reads as a rounding artefact rather
    /// than as a scale.
    @ScaledMetric(relativeTo: .caption) private var meterWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var meterHeight: CGFloat = 4

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // Three things that each refuse to be squeezed: a `StatusPill` is
            // `.fixedSize()` on purpose, the score is a figure, and the meter is
            // a `@ScaledMetric` track — 44pt by default and 145pt at AX5. Side by
            // side at that size they asked for more width than the phone has, and
            // this card sets the width of every other card on the screen.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) { verdict }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: Theme.Space.s) {
                    verdict
                    Spacer(minLength: 0)
                }
            }
            if !sentiment.signals.isEmpty {
                Text(signalSummary)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private var verdict: some View {
        if let outcome = sentiment.outcome {
            StatusPill(
                text: outcome.title,
                tint: outcome.describesStruggle ? Theme.accentWarm : Theme.Status.good
            )
        }
        if let score = sentiment.frustrationScore {
            frustration(score)
        }
    }

    /// The band, the number and a meter — in that order, so the reading survives
    /// without the bar and the bar never has to carry the meaning alone.
    @ViewBuilder
    private func frustration(_ score: Double) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xs) { frustrationParts(score) }
        } else {
            HStack(spacing: Theme.Space.xs) { frustrationParts(score) }
        }
    }

    @ViewBuilder
    private func frustrationParts(_ score: Double) -> some View {
        Group {
            Text("Frustration \(FrustrationBand.title(score).lowercased())")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
            Text(score.formatted(.number.precision(.fractionLength(1))))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(FrustrationBand.tint(score))
            // The fill is clipped by the track, not left to its own capsule.
            // A `Capsule` takes its radius from half the *smaller* side, so a
            // low score makes the fill narrower than it is tall and it rounds
            // tighter than the track it sits in — then paints past the track's
            // leading cap. Rendered at 8× against the clipped version at score
            // 0.05: 1.00pt outside at the default text size and 2.88pt at AX5,
            // where the meter is 145 × 13 rather than 44 × 4.
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: meterWidth, height: meterHeight)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(FrustrationBand.tint(score))
                        .frame(width: meterWidth * score)
                }
                .clipShape(.capsule)
                .accessibilityHidden(true)
        }
    }

    private var signalSummary: String {
        // Counted by kind, so six dead clicks read as one fact rather than six
        // alarms. Ordered by how many, then alphabetically, so the list is stable.
        var tally: [String: Int] = [:]
        for signal in sentiment.signals {
            tally[signal.type.title, default: 0] += 1
        }
        let ordered = tally.sorted { left, right in
            left.value == right.value ? left.key < right.key : left.value > right.value
        }
        return ordered
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
            .joined(separator: " · ")
    }

    private var spoken: String {
        var parts: [String] = []
        if let outcome = sentiment.outcome { parts.append("Sentiment \(outcome.title)") }
        if let score = sentiment.frustrationScore {
            parts.append(
                "frustration \(FrustrationBand.title(score).lowercased()), "
                    + "\(score.formatted(.number.precision(.fractionLength(1)))) out of 1"
            )
        }
        if !sentiment.signals.isEmpty { parts.append(signalSummary) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Chapter row

/// One chapter of the session, and the control that plays it.
///
/// The shape mirrors `TimelineRowView` on purpose: the two sit on the same
/// screen and are read the same way — a time in the gutter, a rail, and a
/// description that expands.
struct SessionChapterRow: View {
    let number: Int
    let chapter: SessionSummaryChapter
    let offset: TimeInterval?
    let isLast: Bool
    let isExpanded: Bool
    let canSeek: Bool
    let onToggle: () -> Void
    var onSeek: ((TimeInterval) -> Void)?

    /// Same reasoning as the timeline's gutter: "+1:23:45" is already the full
    /// width at default type size, so a fixed one truncates the hour off exactly
    /// the sessions long enough to need it.
    @ScaledMetric(relativeTo: .caption2) private var offsetWidth: CGFloat = 54
    /// The chapter number sits in the rail where the timeline puts its dot, and
    /// it holds a numeral — so it has to grow with the type, or "12" clips.
    @ScaledMetric(relativeTo: .caption2) private var railSize: CGFloat = 18

    private var tint: Color { SessionOutcomeStyle.tint(chapter.outcome) }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A gutter, a numbered rail and the chapter — until the gutter costs more
    /// than the chapter is worth.
    ///
    /// The same measurement as `TimelineRowView`, which this row is deliberately
    /// shaped like: `offsetWidth` is 54pt at the default size and **206pt at
    /// AX5**, and with the rail beside it the chapter title was left a column
    /// narrower than its own longest word. The row then reported a width past
    /// the phone, and because every card on the session screen shares one stack,
    /// the whole page went with it — measured at 447pt in a 393pt window, which
    /// is why this was the only screen whose background went white at AX5.
    ///
    /// Stacked, the badge and the time share one short line and the chapter gets
    /// the card's full width. The connecting line goes with the stack: it drew a
    /// rail between rows that are no longer in a column.
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        numberBadge
                        offsetLabel
                    }
                    summary
                    if isExpanded { detail }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : Theme.Space.m)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    offsetLabel
                        .frame(width: offsetWidth, alignment: .trailing)
                        .padding(.top, 3)

                    rail

                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        summary
                        if isExpanded { detail }
                    }
                    .padding(.bottom, isLast ? 0 : Theme.Space.m)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var offsetLabel: some View {
        Group {
            if let offset {
                Text(SessionClock.offset(offset))
            } else {
                // No key action pinned this chapter to a time, so there is
                // nothing honest to put in the gutter and nothing to seek to.
                Text("—")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.Ink.secondary)
    }

    private var numberBadge: some View {
        Text("\(number)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(tint)
            .frame(width: railSize, height: railSize)
            .background(tint.opacity(0.15), in: .circle)
            .accessibilityHidden(true)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            numberBadge
            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: railSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var summary: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The chevron goes, for the reason `RowCard` drops its own when
                // it stacks: it is decorative and hidden from VoiceOver, so on a
                // line of its own it is a large grey arrow pointing at nothing.
                // The seek button is content and keeps its line.
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    titleBlock
                    seekButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    titleBlock

                    Spacer(minLength: Theme.Space.xs)

                    seekButton

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        // A disclosure indicator is a control, not decoration, so
                        // it owes 3:1; `.tertiary` gave it 1.73:1 on this card.
                        .foregroundStyle(Theme.Ink.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
        .accessibilityHint(isExpanded ? "Collapses this chapter" : "Expands this chapter")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chapter.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if let stats { Text(stats).font(.caption).foregroundStyle(Theme.Ink.secondary) }
            if let outcomeWord = chapter.outcome?.title {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: SessionOutcomeStyle.systemImage(chapter.outcome))
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(outcomeWord).font(.caption.weight(.medium))
                }
                .foregroundStyle(tint)
            }
        }
    }

    @ViewBuilder
    private var seekButton: some View {
        if canSeek, let offset, let onSeek {
            Button { onSeek(offset) } label: {
                Image(systemName: "play.circle")
                    .font(.body)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play the replay from \(SessionClock.spoken(offset))")
        }
    }

    /// Duration, share of the session, and whatever the model actually counted.
    ///
    /// `noteworthyCounts` only reports counts that are **present and non-zero**.
    /// A missing `confusion_count` is not a count of nought — nobody measured it
    /// — and printing "0 confusions" would put a number in front of a reader
    /// that the model never produced.
    private var stats: String? {
        var parts: [String] = []
        if let duration = chapter.segment.duration {
            parts.append(SessionClock.clock(duration))
        }
        if let share = chapter.segment.durationPercentage, share > 0 {
            parts.append("\(Int((share * 100).rounded()))% of session")
        }
        parts.append(contentsOf: chapter.noteworthyCounts.map(\.label))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let narrative = chapter.outcome?.detail, !narrative.isEmpty {
                Text(narrative)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(chapter.events) { event in
                KeyMomentRow(event: event)
            }

            ForEach(chapter.signals) { signal in
                SignalRow(signal: signal)
            }

            // Only when the model actually counted and found nothing. A chapter
            // that reported no counts at all gets no sentence here, because
            // "none reported" would be a claim nobody made.
            if chapter.reportedNoDifficulty == true {
                Text("No confusion, abandonment or exceptions reported in this chapter.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.pageBackground, in: .rect(cornerRadius: Theme.Radius.small))
    }

    private var spoken: String {
        var parts = ["Chapter \(number), \(chapter.title)"]
        if let offset { parts.append("starts \(SessionClock.spoken(offset)) into the session") }
        if let word = chapter.outcome?.title { parts.append(word.lowercased()) }
        parts.append(contentsOf: chapter.noteworthyCounts.map(\.label))
        return parts.joined(separator: ", ")
    }
}

// MARK: - Key moments

/// One described moment inside a chapter.
struct KeyMomentRow: View {
    let event: SessionSummaryKeyEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let context { Text(context).font(.caption2).foregroundStyle(Theme.Ink.secondary) }
            if !flags.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(flags, id: \.text) { flag in
                        StatusPill(text: flag.text, tint: flag.tint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Where and when, with the path rather than the whole URL — a column of
    /// paths is what makes one moment comparable to the next.
    private var context: String? {
        var parts: [String] = []
        if let name = event.event { parts.append(name) }
        if let raw = event.currentURL, let url = URL(string: raw) {
            parts.append(url.path.isEmpty ? "/" : url.path)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Stated as facts about what the model saw, not as warnings. A person
    /// hesitating is information about a product; it is not an incident.
    private var flags: [(text: String, tint: Color)] {
        var result: [(String, Color)] = []
        if event.confusion == true { result.append(("Hesitated", Theme.accentWarm)) }
        if event.abandonment == true { result.append(("Gave up here", Theme.accentWarm)) }
        if let exception = event.exception {
            // The one place red is right: something actually threw.
            result.append((exception.title, Theme.Status.critical))
        }
        return result
    }
}

/// One sentiment signal, shown against the chapter it was observed in.
struct SignalRow: View {
    let signal: SessionSentimentSignal

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: signal.type.systemImage)
                .font(.caption2)
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.type.title)
                    .font(.caption.weight(.medium))
                if !signal.detail.isEmpty {
                    Text(signal.detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(signal.type.title). \(signal.detail)")
    }
}
