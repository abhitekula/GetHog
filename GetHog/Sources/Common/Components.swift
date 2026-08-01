import GetHogKit
import SwiftUI

/// Honest freshness stamp.
///
/// The app is cache-first because rate limits are organisation-wide, so every
/// data surface states when its data was actually computed. Silent stale data is
/// the worst failure mode an analytics app can have.
struct FreshnessLabel: View {
    let date: Date?
    var isCached: Bool = true

    var body: some View {
        Group {
            if let date {
                Text("Updated \(date, format: .relative(presentation: .named))")
            } else {
                Text("Not yet loaded")
            }
        }
        .font(.caption2)
        // Measured at 1.69:1 on `.tertiary` against a light card, against an AA
        // floor of 4.5:1 — the least readable text in the app, on every screen in
        // it, in the one component whose whole job is to stop stale data being
        // silent. `Ink.secondary` rather than `Ink.tertiary` because this is the
        // smallest type the app sets and small type needs the *most* contrast:
        // 7.98:1 on a card, 6.95:1 on the page.
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityLabel(
            date.map { "Data updated \($0.formatted(.relative(presentation: .named)))" }
                ?? "Data not yet loaded"
        )
    }
}

/// Shown when an insight type isn't drawn on mobile yet.
///
/// A deliberate, tappable card beats a broken chart, and it makes the roadmap
/// self-evident inside the app.
struct UnsupportedInsightCard: View {
    let kind: String
    var webURL: URL?

    private var friendlyName: String {
        kind.replacingOccurrences(of: "Query", with: "")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(Theme.Ink.tertiary)
            Text("\(friendlyName) insights aren't drawn on mobile yet")
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        .font(.footnote.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// Shown in place of a feature the current API key can't reach.
///
/// Telling somebody to go and edit a credential is the strongest instruction
/// this app gives, and it was being given on no evidence. Reported from a real
/// session: same key, same build, one launch apart — the Sessions tab listed
/// sessions normally, then was replaced by "Your PostHog API key is missing a
/// scope." The key was fine; a transient probe failure had been read as a
/// refusal. `CapabilityReport.isAvailable` is what stops a failed probe
/// reaching this view at all, and the `scope == nil` branch below is the
/// backstop: with no scope to name, the app has no denial behind it either, and
/// it says the weaker thing it can actually stand behind.
struct LockedCapabilityView: View {
    let capability: Capability
    /// The scope PostHog named, or the documented ones for this feature. `nil`
    /// means no refusal was recorded — never "a refusal without a name".
    let scope: String?
    var onRecheck: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("\(capability.title) is locked", systemImage: "lock")
        } description: {
            VStack(spacing: 8) {
                if let scope {
                    Text("Your PostHog API key is missing a scope.")
                    Text(scope)
                        .font(.footnote.monospaced())
                        // A scope string, not prose. Without this a token
                        // acquires a real hyphen where the typesetter decides to
                        // break it — measured at AX5, `UnhandledRejection` set as
                        // `Unhandled-` / `Rejection` — and a reader copying the
                        // scope out cannot tell that hyphen from a real one.
                        // `zxx` is the ISO code for "no linguistic content".
                        .typesettingLanguage(Locale.Language(identifier: "zxx"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                    Text("Add it to your key in PostHog, then re-check.")
                        .font(.footnote)
                } else {
                    Text("This API key couldn't open \(capability.title.lowercased()).")
                    Text("Re-check to see whether that has changed.")
                        .font(.footnote)
                }
            }
        } actions: {
            if let onRecheck {
                Button("Re-check permissions", action: onRecheck)
                    .buttonStyle(.borderedProminent)
                    // See `Theme.inkOnAccent`: a prominent button's default
                    // white label is 2.09:1 on the dark accent. **Not
                    // photographed on this view** — demo mode's key holds every
                    // capability, so the locked state never renders. The
                    // construction is the one measured on Renders and SQL.
                    .foregroundStyle(Theme.inkOnAccent)
            }
        }
        // The app's ground, for the reason `EmptyStateView` gives: this is the
        // other view that replaces a whole screen — or a whole split-view detail
        // column, which has no chrome to inherit a ground from.
        .appGround()
    }
}

/// Shown when one *section* of a screen has nothing in it.
///
/// `EmptyStateView` wraps `ContentUnavailableView`, which centres a large glyph
/// over two lines of prose and takes every point of height it is offered. That
/// is the right answer when a whole screen is empty and the wrong one for a
/// section of a scrolling report: measured on iPad, the Web screen stacked three
/// of them — "Nothing notable", "No pages", "Couldn't load vitals" — and they
/// filled most of the canvas; on iPhone they pushed the breakdown tables below
/// the fold. This states the same honest thing in roughly a line, so the
/// sections that *do* have data stay on screen.
///
/// So: `EmptyStateView` when the screen is empty, this when a section is.
struct SectionEmptyState: View {
    /// Shorter than the full state's wording, never vaguer — the compactness is
    /// in the layout, not in what the app is willing to say.
    let text: String
    var systemImage: String = "tray"
    /// The verbatim fault behind a failure, when there is one. Disclosed rather
    /// than dropped: see `FailureDetail`.
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // One line for as long as a line holds it. A sentence and a button
            // cannot share a phone's width at accessibility sizes, and squeezing
            // the button to a stub is worse than spending a second row on it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    line
                    Spacer(minLength: Theme.Space.s)
                    actionButton
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    line
                    actionButton
                }
            }

            if let detail {
                FailureDetail(text: detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.s)
    }

    private var line: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)
                // Wraps rather than truncates: the wording names a precondition,
                // and half of a precondition is not one.
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .font(.subheadline)
                // Recedes behind the sentence without dropping out of sight:
                // `.tertiary` put this glyph at 1.73:1, under even the 3:1 that
                // WCAG asks of a non-text graphic.
                .foregroundStyle(Theme.Ink.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderless)
        }
    }
}

/// The verbatim fault, kept out of the reader's way but never dropped.
///
/// Measured on the Web screen: a `DecodingError` description — four lines naming
/// a coding key — was rendered as the user-facing message for "Couldn't load
/// vitals". Nobody can act on that, but somebody has to be able to read it. The
/// sentence above states what failed; this keeps what actually broke, for the
/// person who can use it, and makes it selectable so it can be pasted into a
/// report.
struct FailureDetail: View {
    let text: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.Ink.secondary)
                // This is a machine fault quoted verbatim so it can be pasted
                // into a report, which is exactly the string a typesetter's
                // hyphen would corrupt. `zxx` is the ISO code for "no linguistic
                // content", so nothing here is broken with a mark it does not
                // contain.
                .typesettingLanguage(Locale.Language(identifier: "zxx"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Space.xs)
        } label: {
            Text("Details")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .tint(Theme.accent)
        .accessibilityHint("Shows the technical detail of the failure")
    }
}

/// A failed load, split into what the screen says and what it keeps.
///
/// Measured twice, on two screens, with the same shape of fault: Web Analytics
/// put a raw `DecodingError` description under "Couldn't load vitals", and
/// Groups showed "Unexpected response from PostHog: DecodingError.typeMismatch:
/// expected value of type Array<Any>" as its entire explanation. A reader can do
/// nothing with a Swift type name, and the app cannot honestly claim to know
/// *why* PostHog's payload differed. So the summary names what failed and stops
/// there, and the underlying text travels alongside it rather than being thrown
/// away.
struct LoadFailure: Equatable {
    let summary: String
    /// The verbatim fault, when the underlying error carried one worth keeping.
    var detail: String?

    /// Builds the pair from a thrown error.
    ///
    /// `subject` names what was being loaded — "vitals", "group types" — and is
    /// used only when the payload could not be read, which is the one case where
    /// the error's own description is unfit to show.
    init(_ error: any Error, loading subject: String) {
        if let posthog = error as? PostHogError {
            // Two independent questions. This used to ask only one — "is there a
            // technical detail?" — and use it for both, which worked only while
            // `.decoding` was the single case carrying a detail. A query timeout
            // carries both a detail and a perfectly good sentence, and under the
            // old reading its message would have been replaced by the decoding
            // one: "PostHog's events response wasn't in a shape this app could
            // read", about a response that never arrived.
            summary = posthog.hasReadableDescription
                ? posthog.localizedDescription
                : Self.unreadableResponse(subject)
            detail = posthog.technicalDetail
            return
        }
        // Belt and braces: a `DecodingError` thrown outside the client would
        // otherwise reach the screen through `localizedDescription`, which is
        // the same unactionable dump by another route.
        if let decoding = error as? DecodingError {
            summary = Self.unreadableResponse(subject)
            detail = String(describing: decoding)
            return
        }
        summary = error.localizedDescription
        detail = nil
    }

    private static func unreadableResponse(_ subject: String) -> String {
        "PostHog's \(subject) response wasn't in a shape this app could read."
    }

    init(summary: String, detail: String? = nil) {
        self.summary = summary
        self.detail = detail
    }
}

/// The whole-screen version of a failed load.
///
/// `EmptyStateView` alone cannot carry a `LoadFailure`: it has one `message`
/// slot, and putting the detail in it is exactly the defect this pair exists to
/// stop. The disclosure sits *under* the state instead, so the sentence is what
/// the screen says and the dump is one tap away for whoever can use it.
struct LoadFailureState: View {
    let title: String
    let failure: LoadFailure
    var systemImage: String = "exclamationmark.triangle"
    var retryTitle: String = "Try again"
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(
                title: title,
                systemImage: systemImage,
                message: failure.summary,
                actionTitle: retry == nil ? nil : retryTitle,
                action: retry
            )
            if let detail = failure.detail {
                FailureDetail(text: detail)
                    .padding(.horizontal, Theme.Space.l)
            }
        }
        // The inner `EmptyStateView` grounds itself, but the verbatim fault
        // beneath it is outside that view's bounds — so the whole stack claims
        // the ground rather than leaving a strip of system background under the
        // one piece of text somebody reading a failure came for.
        .appGround()
    }
}

/// A rounded card that hosts a dashboard tile or detail block.
///
/// Three things stack to make it read as a surface rather than a rectangle: a
/// fill, a hairline, and two shallow shadows. The hairline is load-bearing —
/// the grouped card colour is pure white in light mode, so on any screen not
/// using the grouped background the fill alone makes the card vanish — but on
/// its own it left everything looking like a wireframe. The shadows give the
/// edge somewhere to sit.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    var elevation: Theme.Elevation = .card
    /// Draws a coloured spine down the leading edge.
    ///
    /// Lifted from PostHog's insight cards, and it earns its place: a wall of
    /// identical white rectangles gives the eye nothing to navigate by, and the
    /// stripe lets a tile be recognised by colour and position before a single
    /// word is read. It is chrome keyed to the *kind* of insight, never to a
    /// series — borrowing the data palette here would imply a relationship to
    /// the values that does not exist.
    var accent: Color?
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The spine is painted into the card's background and clipped by
                // the card's own shape, so it can only ever exist where the card
                // does.
                //
                // It used to be an overlay clipping *itself* to a rounded rect of
                // `Theme.Radius.medium`. That looks right and is not: the clip
                // resolves in the spine's own 4pt-wide box, where SwiftUI clamps
                // a 16pt radius to half the smaller dimension — 2pt. So the spine
                // was a 4pt pill with 2pt corners held against a card curving
                // away at 16pt, and near the top and bottom edges it went on
                // painting at x ∈ [0, 4] after the card had already curved
                // inward. The result was a square nub of colour poking out past
                // each leading corner, on every accented card in the app.
                shape
                    .fill(Theme.cardBackground)
                    .overlay(alignment: .leading) {
                        if let accent {
                            accent
                                .frame(width: 4)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .compositingGroup()
            .shadow(
                color: elevation.ambient.color,
                radius: elevation.ambient.radius,
                y: elevation.ambient.y
            )
            .shadow(
                color: elevation.key.color,
                radius: elevation.key.radius,
                y: elevation.key.y
            )
    }
}

/// Muted small-caps run-in header, the way PostHog labels its column groups.
///
/// Gives a screen structure without spending a full-weight heading on it, which
/// is what makes a dense list feel organised rather than merely long.
struct SectionLabel: View {
    let text: String
    var systemImage: String?
    var brandEmblem: BrandEmblem? = nil

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let brandEmblem {
                BrandEmblemView(emblem: brandEmblem)
                    .accessibilityHidden(true)
            } else if let systemImage {
                // Same face as the text beside it. A fixed 10pt glyph stayed put
                // while the label grew, so at accessibility sizes every one of
                // the ~30 screens using this header showed a speck next to it.
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(text.uppercased())
                .font(.caption2.weight(.semibold))
                // A section header is one or two words of chrome naming what is
                // under it — never prose, and never something to be broken with
                // a hyphen it does not contain. Measured at AX5 on Taxonomy's
                // stat tile, where a narrow column set `DEFINED` as `DE-` /
                // `FINED`. `zxx` is the ISO code for "no linguistic content", so
                // no hyphenation dictionary applies; the same fix `StatusPill`
                // below already makes, and every one of the ~30 screens using
                // this header gets it from here.
                .typesettingLanguage(Locale.Language(identifier: "zxx"))
                .tracking(0.6)
        }
        // Uppercase caption2 with letter-spacing is the hardest thing to read the
        // app sets, and `.secondary` gave it 3.44:1 on a card against a 4.5:1
        // floor. This header names the section on roughly thirty screens.
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityLabel(text)
    }
}

/// Title row for a card, with the insight's own symbol.
///
/// The dashboard was a wall of identically-weighted rectangles; a symbol and a
/// firmer title give each tile a recognisable silhouette, so the eye can find
/// the funnel without reading every heading. The symbol is tinted from the
/// accent rather than the series palette — the palette belongs to the data, and
/// borrowing it for chrome would imply a relationship that isn't there.
struct CardHeader: View {
    let title: String
    var systemImage: String?
    var subtitle: String?

    /// The glyph's column, which has to grow with the glyph in it.
    ///
    /// It was a bare `18`, and the symbol beside it is set in `.footnote` — which
    /// scales. At AX5 that is roughly a 45pt glyph in an 18pt box, and a `frame`
    /// narrower than its content does not clip, it *centres*: the symbol paints
    /// past both sides of its column and the title, laid out from the column's
    /// trailing edge, is drawn straight over it. Caught on `render-detail`, where
    /// the "Video" header's `V` sat on top of the play glyph. Scaled against the
    /// same text style the symbol uses, so the column tracks it at every size.
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat = 18

    /// Read because the line caps below are lifted past the accessibility sizes.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: glyphWidth)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    // Uncapped at accessibility sizes, the same trade `DataRow`
                    // makes: the caps keep a column of cards an even height,
                    // which is a scanning concern, and two lines of `.subheadline`
                    // at AX5 is three or four words — so the cap that tidies the
                    // page is the thing deleting the card's name from it.
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
            }
            Spacer(minLength: 0)
        }
        // The symbol is chrome — it names nothing the title beside it does not
        // already say — so it must not be a VoiceOver stop. It used to carry
        // `.accessibilityHidden(true)` for that, and inside a dashboard tile
        // **that modifier does nothing at all.**
        //
        // Measured through XCUITest on the demo dashboard's six tiles, counting
        // elements whose label is the literal string `chart.xyaxis.line`:
        //
        // | header shape                                   | symbol stops | title stops |
        // | ---------------------------------------------- | ------------ | ----------- |
        // | `.accessibilityHidden(true)` (what shipped)     |            2 |           1 |
        // | no modifier at all                              |            2 |           1 |
        // | `.accessibilityElement(children: .ignore)`      |            2 |           1 |
        // | `.accessibilityElement(children: .combine)`     |            2 |           2 |
        // | `.accessibilityRepresentation`                  |        **0** |           1 |
        //
        // Hiding and not hiding produce the *same tree* — diffed whole, they
        // match element for element and label for label, with only the pointer
        // addresses different. That is the whole finding: the flag is not being
        // lost somewhere, it is not being consulted at all.
        // A tile's chart publishes an `AXChartDescriptor`, which keeps the
        // button's label subtree a *container* rather than collapsing it to one
        // leaf, and the container enumerates the rendered rows rather than
        // SwiftUI's accessibility nodes — so a child's suppression never
        // reaches it. `.ignore` fails for the same reason, and `.combine` makes
        // it worse by adding a second stop carrying the title.
        //
        // This is the same class as the replay stage's WebKit leak, and it has
        // the same answer: suppressing a subtree you do not own does not work,
        // *replacing* it does. The replacement is deliberately the two lines
        // this view draws and nothing else — the title has to survive, because
        // it is the only thing in the header that says what the card is.
        .accessibilityRepresentation {
            if let subtitle {
                VStack(alignment: .leading) {
                    Text(title)
                    Text(subtitle)
                }
            } else {
                Text(title)
            }
        }
    }
}

/// A selectable option row used in onboarding and pickers.
struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                content
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    // The unselected ring is a control indicator, not decoration,
                    // so it owes 3:1; `tertiaryLabel` gave it 1.73:1 on a card.
                    .foregroundStyle(isSelected ? Theme.accent : Theme.Ink.tertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(Theme.cardBackground, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Theme.accent.opacity(0.6) : Theme.hairline,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Signed delta with an arrow, so change is never conveyed by colour alone.
struct DeltaBadge: View {
    let current: Double
    let previous: Double
    /// True for metrics where a rise is bad news — bounce rate, error rate, load
    /// time. Without it the badge tints purely by direction and paints a rising
    /// bounce rate green, which is the opposite of what happened.
    var isIncreaseBad: Bool = false

    private var change: Double? {
        guard previous != 0 else { return nil }
        return (current - previous) / abs(previous)
    }

    var body: some View {
        if let change {
            let rising = change >= 0
            let isGood = rising != isIncreaseBad
            Label {
                Text(change, format: .percent.precision(.fractionLength(0...1)))
            } icon: {
                // The arrow always follows the number, never the verdict: a fall
                // in a bad-when-rising metric is good news but it is still a
                // fall, and flipping the arrow would misstate the direction.
                Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
            }
            .font(.caption.weight(.medium))
            // The badge is a number and an arrow, not a mark: on a card the
            // mark tints measured 3.95:1 (critical) and 4.95:1 (good), and on
            // the page 3.44:1 and 4.31:1, against a 4.5:1 floor.
            .foregroundStyle(isGood ? Theme.Status.goodInk : Theme.Status.criticalInk)
            .accessibilityLabel(
                "\(rising ? "Up" : "Down") "
                    + abs(change).formatted(.percent.precision(.fractionLength(0...1)))
                    + ", \(isGood ? "an improvement" : "worse")"
            )
        }
    }
}

/// A delta that states its own absence rather than rendering nothing.
///
/// `DeltaBadge` returns an empty view when there is no previous value, which is
/// right inline but wrong in a column: eight rows of nothing reads as a broken
/// field rather than as a fact about the data. This says the fact.
struct DeltaOrAbsence: View {
    let current: Double
    let previous: Double?
    /// True for metrics where going up is bad news — bounce rate, error rate,
    /// load time. Without it this tints purely by direction and paints a rising
    /// bounce rate green, contradicting the metric beside it.
    var isIncreaseBad: Bool = false
    /// Explains *why* it is missing, when the caller knows.
    var absenceReason: String = "No prior period"

    var body: some View {
        if let previous, previous != 0 {
            DeltaBadge(current: current, previous: previous, isIncreaseBad: isIncreaseBad)
        } else {
            Label(absenceReason, systemImage: "minus.circle")
                .font(.caption)
                // Same 1.73:1 failure as the rest of `.tertiary`, and this one
                // sits in a column of metric tiles where it is the only thing
                // saying why a delta is missing.
                .foregroundStyle(Theme.Ink.tertiary)
                .accessibilityLabel("No comparable previous period")
        }
    }
}

/// Compact status pill that always carries text, never colour alone.
///
/// The word is the whole point — colour is the second encoding, not the first —
/// so the pill is not allowed to be squeezed until the word stops being one.
/// Measured at AX5 on the Ingestion rows, where the surrounding row left it a
/// narrow strip: a five-letter "Error" was set as `Er-` / `ror`, which is a
/// state control that no longer states anything. Every caller in the app gets
/// the fix from here.
///
/// **The pill holds its width in a row, and gives it up in a column.** `fixedSize`
/// is a demand on the layout, not a local preference: an `HStack` honours it
/// before it gives anything to a flexible sibling, so a pill that will not
/// compress *takes* its ideal width from whatever shares the row. At AX5
/// `2 exceptions` is around 350pt of a 393pt phone, and the session summary's
/// header card — a title, a spacer and this pill — was measured with its
/// `Did not finish` heading squeezed to a column narrower than one character:
/// the text rendered as nothing at all while still claiming a line's height per
/// character, so the card came out ~1450pt tall containing a glyph and a pill in
/// a field of white, and the summary paragraph below it was pushed off-screen.
/// The heading was not truncated, it was *absent*, which reads as missing data
/// rather than as a layout fault.
///
/// So at accessibility sizes the pill wraps instead. That keeps the promise the
/// original made — the word is never cut to `Er…` and never hyphenated into
/// `Er-`/`ror` — while letting a sibling have the width it needs. Below those
/// sizes nothing changes: the pill is a few characters, it fits, and refusing
/// compression is what stops a crowded row shortening it.
struct StatusPill: View {
    let text: String
    let tint: Color

    /// Read because the pill's compressibility changes with it; see the note above.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            // A status word is a token, never prose: `zxx` is the ISO code for
            // "no linguistic content", so no hyphenation dictionary applies and
            // the soft hyphen that split "Error" cannot be inserted.
            .typesettingLanguage(Locale.Language(identifier: "zxx"))
            // Uncapped at accessibility sizes for the same reason `DataRow`'s
            // title is: one line of type that large is a word or two, and the cap
            // exists to keep a pill pill-shaped, which stops being worth a lost
            // word.
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            // Refuses compression outright rather than truncating to `Er…`,
            // which would be the same defect spelled differently — but only
            // where refusing costs a sibling nothing.
            .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: .capsule)
            // The chip is still a wash of the tint — that is what tells the
            // states apart at a glance — but the word is not. Drawn in the tint
            // it measured 3.25:1 for `critical` in light and 4.21:1 in dark,
            // against a 4.5:1 floor. The ink is the same hue at a value that
            // clears 5:1 on the chip, so the pill looks the same and reads.
            .foregroundStyle(Theme.Status.ink(for: tint))
    }
}

extension View {
    /// Applies a redacted skeleton while loading, so layout never jumps.
    @ViewBuilder
    func skeleton(_ isLoading: Bool) -> some View {
        redacted(reason: isLoading ? .placeholder : [])
            .animation(.default, value: isLoading)
    }
}

/// Formats large counts compactly (12.4K) for tiles and rows.
extension Double {
    var compactFormatted: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

extension Array where Element == String {
    /// Joins fragments into one spoken label without doubling the full stop.
    ///
    /// Combined accessibility labels are assembled from fragments and separated
    /// by a full stop because that is what makes VoiceOver pause between them; a
    /// comma runs a row's name, its counts and its status together into one
    /// breath. The catch is that not every fragment is ours to punctuate. An
    /// error issue's description arrives from the API already ending a sentence,
    /// as does `HeatmapProfile.coverageNote`, and a plain
    /// `joined(separator: ". ")` then produced "An unexpected response was
    /// received from the server.. 3 users" — measured on the Errors list, and
    /// spoken as two pauses where the writer intended one.
    ///
    /// A fragment that already ends a sentence gets the space and keeps its own
    /// punctuation; only the ones that don't get a stop added. Empty fragments
    /// drop out rather than contributing a stop with nothing behind it.
    func joinedAsSentences() -> String {
        let terminators: Set<Character> = [".", "!", "?", "…"]
        return lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: "") { label, fragment in
                if label.isEmpty {
                    label = fragment
                } else if let last = label.last, terminators.contains(last) {
                    label += " " + fragment
                } else {
                    label += ". " + fragment
                }
            }
    }
}
