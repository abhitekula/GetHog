import GetHogUI
import SwiftUI

/// One `.task(id:)` token. Re-running the *same* brief needs a *different*
/// value, or SwiftUI treats a retry as the request it is already serving — which
/// is why the attempt counter exists.
private struct SummaryRequest: Equatable {
    let brief: SummaryBrief
    let attempt: Int
}

/// The one place generated prose is allowed to appear in this app.
///
/// **The problem this card solves is not layout.** Everything else on these
/// screens is a figure PostHog returned or a string PostHog stored. This is
/// neither: it is text a language model wrote, and the app's whole posture — it
/// refuses to compute NPS off the wrong scale, it labels schema-derived fixtures
/// as synthetic, it prints an unresolved frame's bundle position with a
/// "Minified" pill so nobody reads it as their own source — depends on a reader
/// never mistaking one for the other. So the card is built to be unmistakable:
///
/// * It is the only surface in the app that carries a `sparkles` glyph.
/// * A "Generated" pill sits in the header, in words, not colour alone.
/// * Two lines of provenance sit under every summary, in every state that has
///   any text in it: what the model was given, and that it was a model.
/// * The prose never sits inside a `StatStrip`, a chart, or a `MetricTile`.
///   Callers place it in a block of its own — see `ErrorIssueDetailView`, where
///   it deliberately sits below the triage controls rather than beside the three
///   impact figures.
/// * Nothing is generated until the reader asks. There is no summary on a screen
///   somebody merely opened, so a summary is always something they can attribute
///   to their own tap.
///
/// **Streaming is visible as streaming.** The partial text carries a "writing…"
/// caption and the action button becomes Stop. A half-written sentence that
/// looked settled would be the worst version of this feature.
struct OnDeviceSummaryCard: View {

    /// Names what is being summarised — "What this issue is", "What people
    /// wrote". Never "Analysis" or "Insights": the heading should promise a
    /// reading of the text above it, not a finding.
    let heading: String
    /// The button. Imperative, and names the object.
    let actionTitle: String
    let brief: SummaryBrief

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var store: OnDeviceSummaryStore
    @State private var request: SummaryRequest?
    @State private var attempt = 0

    /// The store is injectable for one reason: so this card's states can be
    /// *rendered and looked at*.
    ///
    /// `CLAUDE.md` records that a lot of UI here has historically shipped
    /// unseen, and the working technique is an `ImageRenderer` pass over the
    /// real view with real data. There is no way to reach the streaming or
    /// finished states from outside without driving a real generation first,
    /// and no way to drive one into a store this view owns privately. Callers
    /// in the app all use the default.
    init(
        heading: String,
        actionTitle: String,
        brief: SummaryBrief,
        store: OnDeviceSummaryStore = OnDeviceSummaryStore()
    ) {
        self.heading = heading
        self.actionTitle = actionTitle
        self.brief = brief
        _store = State(initialValue: store)
    }

    /// Read in `body` rather than cached on appear, so turning Apple
    /// Intelligence on in Settings updates the screen behind it —
    /// `SystemLanguageModel` is `Observable`. See `OnDeviceModel.readiness`.
    private var readiness: OnDeviceModelReadiness { OnDeviceModel.readiness() }

    var body: some View {
        if readiness.isReady {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    header
                    content
                }
            }
            // Cancels on dismissal and on retry, both for free: SwiftUI cancels
            // a `.task(id:)` when the view leaves and when the id changes, and
            // `OnDeviceSummaryStore.run` turns that cancellation into `.idle`
            // rather than into a stranded spinner.
            .task(id: request) {
                guard let request else { return }
                await store.run(request.brief)
            }
        } else {
            unavailableNote
        }
    }

    // MARK: - Header

    /// The heading and the pill that says the text under them was written by a
    /// model — which is the single most important thing on this card, and the
    /// thing that broke first at accessibility sizes.
    ///
    /// Measured at AX5 in a 320pt column: `StatusPill` carries `.fixedSize()`
    /// and refuses to compress — deliberately, because a status word truncated
    /// to `Gener…` is the same defect spelled differently — so it took the whole
    /// row and squeezed `SectionLabel` to about one character wide. The heading
    /// rendered as a vertical column of single letters, one per line, roughly
    /// twenty lines tall. It is not the pill's fault and not the label's; two
    /// incompressible things do not fit on one narrow row, so past the
    /// accessibility threshold they stop sharing one.
    ///
    /// `dynamicTypeSize.isAccessibilitySize` rather than `ViewThatFits`: the
    /// horizontal candidate here contains a `Spacer`, which always reports that
    /// it fits, so `ViewThatFits` would never fall through to the stacked form.
    /// This is the same reflow, on the same trigger, that `SurveyDistributionRow`
    /// makes for the same measured reason.
    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    SectionLabel(text: heading, systemImage: "sparkles")
                    StatusPill(text: "Generated", tint: Theme.accentWarm)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    SectionLabel(text: heading, systemImage: "sparkles")
                    Spacer(minLength: 8)
                    StatusPill(text: "Generated", tint: Theme.accentWarm)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(heading). Generated text.")
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            idle
        case .streaming(let partial):
            streaming(partial)
        case .finished(let text):
            finished(text)
        case .failed(let failure):
            failed(failure)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("GetHog can write a short summary of this on the device itself. Nothing is sent anywhere, and no PostHog data is fetched.")
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(actionTitle) { start() }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .tint(Theme.accent)
        }
    }

    @ViewBuilder
    private func streaming(_ partial: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text(partial.isEmpty ? "Starting the on-device model…" : "Writing…")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            if !partial.isEmpty {
                prose(partial)
                    // Deliberately *not* published to VoiceOver while it grows:
                    // the text is replaced wholesale several times a second, and
                    // an element whose label changes that fast is announced over
                    // itself until it is unusable. The finished text below is
                    // fully readable; this is a progress indicator that happens
                    // to be made of words.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Writing a summary on this device.")
            }

            // Stopping clears the request token, which cancels the `.task` and
            // drops the partial text. Keeping a stopped half-sentence would be
            // presenting an unfinished generation as a summary.
            Button("Stop") { request = nil }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)

            provenance
        }
    }

    private func finished(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            prose(text)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Summary generated on this device. \(text)")

            // The 44pt floor goes *inside* the label, not on the button. A
            // borderless button's tap region is its label's bounds, so the
            // modifier on the outside would only recentre the text and leave the
            // target the height of one line of `.footnote` — the measured trap
            // `CLAUDE.md` records for `Menu`, and it applies to `.plain` for the
            // same reason.
            Button { start() } label: {
                Text("Write it again")
                    .font(.footnote.weight(.medium))
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)

            provenance
        }
    }

    private func failed(_ failure: SummaryFailure) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.Status.warningInk)
                    .accessibilityHidden(true)
                Text(failure.text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if failure.canRetry {
                Button("Try again") { start() }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            // The summary is the content of this card, so it wraps in full for
            // the same reason a survey answer does: a truncated summary is one
            // you have to guess the end of.
            //
            // Hyphenation is left on, unlike `SectionLabel` and `StatusPill`,
            // which suppress it with `zxx`. Those carry tokens; this carries
            // prose that happens to mention identifiers. At large type sizes a
            // narrow column may break `applyExampleUpdate` across lines, but the alternative
            // is an identifier wider than the column with nothing to break it,
            // and a name running off the edge is worse than a name with a
            // hyphen in it.
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two sentences that must never be separated from the prose.
    ///
    /// The first is the brief's own `scope`, so a reader can check the summary
    /// against what the model was actually shown — including when that is less
    /// than what is on screen. The second says it is a model. Both are present
    /// while streaming as well as after, because the streaming state is the one
    /// most likely to be screenshotted mid-sentence.
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(brief.scope)
            Text("Written on this device by Apple's language model. It's a reading aid, not a figure PostHog returned, and it can be wrong or leave things out.")
        }
        .font(.caption2)
        .foregroundStyle(Theme.Ink.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// Said, not hidden.
    ///
    /// Apple Intelligence depends on the device, the region and a setting the
    /// user has to have turned on, so on a large share of installs this feature
    /// simply cannot run. Drawing nothing there would leave those readers with a
    /// screen that is quietly missing something other people's screenshots have;
    /// a dead button would be worse. One caption line, naming the reason, is the
    /// smallest honest thing — and for the "turned off" case it is actionable.
    private var unavailableNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .accessibilityHidden(true)
            Text(readiness.explanation)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.Ink.tertiary)
        // The same inset `Card` gives its own content, so the note lines up with
        // the *text* of the cards around it rather than with their edges. It
        // matters most on the survey answers list, where this sits in a list row
        // whose insets are zeroed for the card's benefit and an unpadded caption
        // would start hard against the row's leading edge.
        //
        // **Not seen on screen.** This whole branch is unreachable on a machine
        // with Apple Intelligence enabled, and `SystemLanguageModel` offers no
        // way to force an availability, so the layout is reasoned from `Card`'s
        // own padding rather than measured.
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("On-device summary unavailable. \(readiness.explanation)")
    }

    private func start() {
        attempt += 1
        request = SummaryRequest(brief: brief, attempt: attempt)
    }
}
