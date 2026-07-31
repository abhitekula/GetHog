import SwiftUI

/// Width caps, and the label/value row that applies them.
///
/// This file exists because of a measurable failure, and it is the same shape of
/// failure `DesignKit.swift` was written for: a screen author reaching for the
/// obvious arrangement got one that is right on a phone and absurd on an iPad.
///
/// Photographed on `iPad Pro 11-inch (M5)` in portrait, where the window is
/// 834pt wide and a full-bleed row is ~770pt of it:
///
/// | screen | pair | gap between label and value |
/// |---|---|---|
/// | `settings` | Email → `analyst@example.com` | ~600pt |
/// | `taxonomy-event-detail` | Name → `$pageview` | ~600pt |
/// | `support-ticket-detail` | Status → `Open` | ~640pt |
/// | `error-issue-detail` | Function → `[REMOVED PRIVATE DATA]` | ~560pt |
///
/// Nothing there is a rendering bug. `LabeledContent` in a `Form`, and the
/// hand-rolled `HStack { label; Spacer(); value }` that four screens wrote
/// instead, both do exactly what they are told — put the label on one edge and
/// the value on the other. On a 393pt phone that is the Settings app. On a 834pt
/// iPad column it is two facts a hand's width apart, and in landscape (1210pt)
/// it is two facts that cannot both be looked at.
///
/// The fix is a *measure*, not a per-screen patch: a pair stops widening past
/// the point where the eye can still travel it, and the leftover width is simply
/// left empty. That is what the system's own settings look like on iPad — a
/// column of rows in the sidebar's measure with the detail beside it — and it is
/// what this file makes available to every screen at once.
extension Theme {

    /// Widths past which a layout stops being readable and starts being a
    /// journey. All three are *caps*: below them nothing changes, so the phone
    /// layouts these numbers were derived against are untouched.
    enum Measure {

        /// A label and its value.
        ///
        /// 460pt, which is a little wider than the ~360pt a `Form` row gets on
        /// an iPhone 17 and much narrower than the ~770pt it gets on an iPad in
        /// portrait. Chosen so the pair reads as the same component on both
        /// devices rather than as two different designs.
        static let pair: CGFloat = 460

        /// One control in a filter bar.
        ///
        /// 420pt, matching the cap `DashboardDetailView` already applies to its
        /// own range picker for the same reason, written there as: "a segmented
        /// control spanning a 13-inch iPad puts five words a hand's width apart
        /// and reads as a toolbar, not a choice."
        static let control: CGFloat = 420

        /// A dense pane of rows that each carry a leading identifier and a
        /// trailing measurement — the replay console and network waterfall.
        ///
        /// Wider than `pair` because these rows are not pairs: a request row is
        /// a path, a status, a duration and a timing bar, and the bar is a
        /// timeline that wants room. 640pt keeps the path and its status inside
        /// one glance while leaving the waterfall more span than the ~360pt it
        /// has always had on a phone.
        static let pane: CGFloat = 640

        /// Below this, a `DataRow` stacks instead of competing for width.
        ///
        /// 280pt. Measured off the sweep rather than picked: the `DataRow`s in
        /// an iPad split-view sidebar in portrait get ~253pt (People, Flags,
        /// Cohorts — the sidebar takes its declared *minimum* there), and the
        /// same rows on an iPhone 17 get ~350pt. 280 sits between them, and
        /// stays *under* the ~288pt a 320pt-wide phone gives a row — the
        /// threshold has to be below that number, not above it, or the smallest
        /// phone in the lineup would start stacking rows that fit today. The
        /// margin is 8pt, so treat this as a floor with very little room: a
        /// future row that adds leading padding on a 320pt phone crosses it.
        static let stackedRow: CGFloat = 280
    }
}

// MARK: - Label and value

/// A label/value row that stops at a readable measure.
///
/// Applied through `LabeledContentStyle` rather than offered as a new view, for
/// one reason that decided it: the style travels through the environment, so a
/// screen adopts it once and every `LabeledContent` beneath it — including the
/// ones inside components the screen does not own, such as `PropertyRow` — is
/// reflowed without that component being edited at all.
///
/// Two behaviours of the built-in style are deliberately reproduced rather than
/// dropped, because call sites already depend on both:
///
/// - **It stacks at accessibility sizes.** `SettingsRoot` documents that its
///   account rows do this and carries a `zxx` typesetting language *because*
///   they do. A custom style that kept the pair horizontal at AX5 would have
///   quietly falsified that comment.
/// - **It is one accessibility element.** `LabeledContent` combines label and
///   value into a single VoiceOver stop; a style that laid out an `HStack` and
///   said nothing would have doubled every stop on Settings, Support, Taxonomy,
///   Tracing and People.
struct MeasuredPairStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        @Environment(\.dynamicTypeSize) private var typeSize

        let configuration: LabeledContentStyleConfiguration

        var body: some View {
            pair
                // Two frames, and both are load-bearing. The inner one caps the
                // measure; the outer one claims the rest of the row so the
                // capped pair sits at the leading margin rather than being
                // centred in whatever the row was offered — a centred pair on an
                // iPad would leave the labels no longer lining up with the
                // section header above them.
                .frame(maxWidth: Theme.Measure.pair)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }

        @ViewBuilder
        private var pair: some View {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    configuration.label
                    value
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    configuration.label
                    Spacer(minLength: Theme.Space.m)
                    value.multilineTextAlignment(.trailing)
                }
            }
        }

        /// On `Theme.Ink`, not on SwiftUI's `.secondary`.
        ///
        /// The built-in style greys the value to separate it from the label, and
        /// dropping that would have flattened the hierarchy on every row this
        /// touches. `.secondary` is the wrong token for it here for the reason
        /// `Theme.Ink` records at length — it is an alpha composite that
        /// measures 3.44:1 on a white card against a 4.5:1 floor. A value that
        /// sets its own style, such as the `StatusPill` in a span's Status row,
        /// keeps it: an explicit style on a child wins over an inherited one.
        private var value: some View {
            configuration.content.foregroundStyle(Theme.Ink.secondary)
        }
    }
}

extension View {
    /// Reflows every `LabeledContent` beneath this view to a readable measure.
    ///
    /// Applied once per screen, at the top of the `List`, `Form` or scaffold.
    func measuredPairs() -> some View {
        labeledContentStyle(MeasuredPairStyle())
    }

    /// Caps a block that is not a `LabeledContent` to a named measure, and keeps
    /// it at the leading margin.
    ///
    /// For the panes that are rows of their own shape — the replay console and
    /// network waterfall — where converting to `LabeledContent` would lose the
    /// timing bar the row is really about.
    func readableMeasure(_ width: CGFloat) -> some View {
        frame(maxWidth: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
