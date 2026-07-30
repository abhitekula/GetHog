import SwiftUI

/// The shared screen vocabulary.
///
/// This file exists because of a measurable failure: `Theme` was reached by 13
/// of 44 app files, and the other 31 rendered default `List` chrome on system
/// grey. That was not neglect. There was a `Card` and a `CardHeader` — tile
/// components — but never a shared *row*, *page surface* or *empty state*, so a
/// screen author writing a list had nothing to reach for and wrote
/// `List { ForEach { ... } }`. Twenty screens did exactly that.
///
/// Styling those screens one by one would have left the same hole open for the
/// next one. These are the pieces that close it.

// MARK: - Page surface

extension View {

    /// Puts a screen on the app's ground instead of the system's.
    ///
    /// `List` and `Form` paint their own background above anything behind them,
    /// which is why setting `.background` alone leaves a screen stubbornly grey.
    /// Hiding the scroll content background first is the part that actually
    /// does the work.
    ///
    /// The soft edge effect is iOS 26's replacement for content vanishing under
    /// a hard bar boundary: rows dissolve into the toolbar rather than being
    /// sliced by it, which matters more here than usual because the glass bars
    /// are translucent and a hard cut shows through them.
    func pageSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .scrollEdgeEffectStyle(.soft, for: .all)
    }

    /// Liquid Glass in the app's shape language.
    ///
    /// Wrapped rather than called directly so one rule is applied everywhere:
    /// **glass is tinted only to mean "selected"**, never to decorate. Apple's
    /// guidance reserves tint for semantic weight, and a uniformly warm-tinted
    /// navigation layer is the decorative case it warns against.
    ///
    /// The name is kept from when this did tint everything, because it is the
    /// call site vocabulary across ~30 screens; what changed is the rule.
    func warmGlass(active: Bool = false, in shape: some Shape = .capsule) -> some View {
        glassEffect(
            active ? .regular.tint(Theme.glassActiveTint) : .regular,
            in: shape
        )
    }
}

/// Screen chrome shared by every root: the title, the current project, and the
/// switcher.
///
/// Exists because the obvious arrangement was wrong in two different ways. The
/// project name lived in a wide toolbar pill, which on iPhone was too wide to
/// share the bar with a back button and so took an entire row to itself —
/// three rows of chrome before any data. And on iPad the large title collided
/// with the floating tab bar, which already names the section, drawing the two
/// on top of each other.
///
/// The project is a `navigationSubtitle` instead: it stays permanently visible,
/// which the plan requires — showing the wrong project's numbers is a
/// correctness bug, not a cosmetic one — while costing no vertical space at
/// all. The switcher shrinks to a glyph beside it.
private struct ScreenChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .navigationSubtitle(model.selectedProject?.name ?? "")
            // Inline in regular width: the floating tab bar already carries the
            // section name, so a large title beneath it is both a duplicate and
            // an overlap.
            .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .automatic)
    }
}

extension View {
    /// Shows the current project under the title. Pair with `ProjectSwitcher`.
    func projectSubtitle() -> some View {
        modifier(ScreenChrome())
    }
}

/// A scrolling screen on the app ground, with consistent insets.
///
/// For screens that own a `ScrollView`. Screens built on `List` use
/// `.pageSurface()` instead — wrapping a `List` in this would nest two scroll
/// views and break both.
struct PageScaffold<Content: View>: View {
    var spacing: CGFloat = Theme.Space.l
    var horizontalPadding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageSurface()
    }
}

// MARK: - Row glyph

/// The tinted, rounded glyph tile that leads a row.
///
/// Carries the row's *kind*, which is what lets a list be scanned by shape and
/// colour before a word is read — the single biggest difference between these
/// lists and the plain ones they replace.
///
/// The tint is always a chrome colour, never one from `SeriesPalette`. Borrowing
/// a series hue here would imply a relationship between a row and a data series
/// that does not exist, and would break the rule that colour identifies data.
struct RowGlyph: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: .rect(cornerRadius: size * 0.29, style: .continuous))
            // Decorative: the row's own label already says what this is, and a
            // VoiceOver user does not benefit from hearing the icon named too.
            .accessibilityHidden(true)
    }
}

// MARK: - Data row

/// What a row can show on its trailing edge.
///
/// A closed set rather than a generic view, because "anything" is how twenty
/// screens ended up with twenty different row shapes. Each case is a decision
/// about what the row is *for*.
enum RowAccessory {
    /// Navigational. Omit it when the row does not push anything.
    case chevron
    /// A number worth comparing down the column — counts, durations, totals.
    case metric(String)
    /// A state that must be readable as a word, never as a colour alone.
    case pill(String, Color)
    case none
}

/// The standard list row.
///
/// Replaces `title + truncated description + chevron`, which spent roughly
/// 120pt of height on one line of information. The shape here is deliberately
/// data-forward: glyph for kind, title, one line of context, and a trailing
/// value that is worth scanning vertically.
struct DataRow: View {
    let glyph: String
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String?
    /// Third line, for provenance or freshness — kept to a caption so it
    /// recedes behind the title rather than competing with it.
    var footnote: String?
    /// Rendered monospaced. For keys, paths and identifiers, where character
    /// alignment is what makes a column comparable at a glance.
    var isSubtitleMonospaced: Bool = false
    /// How many lines the subtitle may take.
    ///
    /// One by default, because in almost every list here the subtitle is a
    /// supporting identifier and rows of uneven height stop being scannable.
    /// Logs are the exception that made this a knob: there the subtitle *is* the
    /// payload, and clipping a message to one line left long lines — the stack
    /// traces someone opened the screen for — unreadable anywhere in the app.
    var subtitleLineLimit: Int = 1
    var accessory: RowAccessory = .chevron

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            RowGlyph(systemName: glyph, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(isSubtitleMonospaced ? Theme.Typography.body.monospaced() : Theme.Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit)
                }

                if let footnote, !footnote.isEmpty {
                    Text(footnote)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Space.s)

            accessoryView
        }
        .padding(.vertical, Theme.Space.xs)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        case .metric(let value):
            Text(value)
                .font(Theme.Typography.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        case .pill(let text, let tint):
            StatusPill(text: text, tint: tint)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Metrics

/// One number, with its label and optional change.
///
/// The label is deliberately smaller than the value. Emphasising "Sessions"
/// over "12.4K" is the most common way an analytics layout wastes its own
/// hierarchy — the reader already knows they asked for sessions.
struct MetricTile: View {
    let label: String
    let value: String
    var delta: (current: Double, previous: Double?)?
    /// True where a rise is bad news — bounce rate, error rate, load time.
    var isIncreaseBad: Bool = false
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: label)

            Text(value)
                .font(compact ? Theme.Typography.metricSmall : Theme.Typography.metric)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let delta {
                DeltaOrAbsence(
                    current: delta.current,
                    previous: delta.previous,
                    isIncreaseBad: isIncreaseBad
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Two to four metrics across a header.
///
/// Scrolls horizontally rather than compressing, because a metric that has been
/// squeezed until it truncates has stopped being a metric.
struct StatStrip<Content: View>: View {
    var compact: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                content
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Empty and locked states

/// The app's empty state.
///
/// Wraps `ContentUnavailableView` so the glyph, tone and action placement are
/// decided once. Most of these screens are legitimately empty against a real
/// project, so an empty state here is a normal outcome and should look
/// deliberate rather than broken.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

// MARK: - Filter bar

/// Warm-glass container for the controls above a data surface.
///
/// Filters belong in one row above the content, in a surface that reads as
/// chrome rather than as another card — otherwise a segmented control sitting
/// loose on the ground looks like a tile that failed to load.
struct GlassFilterBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            content
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .warmGlass(in: .rect(cornerRadius: Theme.Radius.medium, style: .continuous))
        .padding(.horizontal, Theme.Space.l)
    }
}
