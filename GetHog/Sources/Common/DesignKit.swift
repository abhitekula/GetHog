import GetHogUI
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
        #if os(tvOS)
        // `scrollContentBackground` is unavailable on tvOS, so the ground has to
        // be laid without first asking the list to stop painting its own. The
        // soft edge *is* available here (unlike visionOS) and is worth having:
        // a TV list scrolls under a translucent bar exactly as an iOS one does.
        return background(Theme.pageBackground)
            .scrollEdgeEffectStyle(.soft, for: .all)
        #else
        let ground = scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
        #if os(visionOS)
        // `scrollEdgeEffectStyle` is unavailable on visionOS, and there is
        // nothing to ask for: the soft edge exists because iOS 26's glass bars
        // are translucent and a hard cut shows through them. A visionOS window
        // is its own glass substrate and draws its own edge treatment.
        return ground
        #else
        return ground.scrollEdgeEffectStyle(.soft, for: .all)
        #endif
        #endif
    }

    /// The app's ground behind something that fills a screen without scrolling.
    ///
    /// `pageSurface()` is the scrolling counterpart and cannot stand in here: its
    /// first job is to stop a `List` painting over the ground, and a state view
    /// has no scroll view to quieten. What it needs instead is to *claim* the
    /// space — `ContentUnavailableView` centres itself in whatever it is offered,
    /// so a `.background` alone paints only as far as the layout happened to
    /// stretch.
    ///
    /// This is the piece that was missing when twelve roots sampled `#FFFFFF` in
    /// light and `#000000` in dark: every one of them applied `pageSurface()` to
    /// its `list` branch only, so the branch that renders when the list is empty
    /// — which is the branch a real project shows most often — fell through to
    /// the system background. See `EmptyStateView`.
    func appGround() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
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
        #if os(visionOS)
        // `glassEffect` is unavailable on visionOS, where glass is not a
        // material a view opts into — the window is already one, and the system
        // draws its own behind controls. What has to survive the substitution is
        // the *rule* this wrapper exists for: tint means selected and nothing
        // else is decorated. So an active surface carries the tint and an
        // inactive one takes the platform's own material.
        background(
            active ? AnyShapeStyle(Theme.glassActiveTint) : AnyShapeStyle(.regularMaterial),
            in: shape
        )
        #else
        glassEffect(
            active ? .regular.tint(Theme.glassActiveTint) : .regular,
            in: shape
        )
        #endif
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
///
/// The display mode is left to the system, which is a correction. Forcing
/// `.inline` in regular width deleted the title on iPad rather than shrinking
/// it: the floating tab bar sits in the centre of the top bar, an inline title
/// has no other slot, and the subtitle hangs off the title and went with it. On
/// ~18 stack-less roots that left the switcher glyph and then the data —
/// nothing naming the screen, nothing naming the project, on a screen whose
/// numbers mean nothing without both. Two measurements fix the cause: Settings,
/// the one root in the same `NavigationStack` container that never applies this
/// modifier, kept its large title on the same iPad; and the split-view roots,
/// whose title renders in the sidebar column where the centre is free, kept
/// title *and* subtitle while inline. The tab bar was never the fallback the
/// comment here assumed it was — it pages, and on Clickmap it was showing
/// `Dashboards · Events · Sessions · Flags` while Clickmap was on screen.
///
/// It also lays the app's ground under the whole screen, and that is load-bearing
/// rather than belt-and-braces. `pageSurface()` is applied to a *branch* — the
/// one holding the `List` — so a root that renders an empty state, a locked
/// capability or a load failure instead was on the system background: measured at
/// `#FFFFFF` in light and `#000000` in dark on twelve of thirty-five roots, in
/// both appearances and on both devices. Fixing those twelve call sites would
/// have left the hole open for the thirteenth, because the thing a screen author
/// forgets is a modifier on a branch they did not write yet.
///
/// Here it cannot be forgotten: this modifier is applied once, to the whole body,
/// by every root that names its project — which is every root, since a screen
/// that does not say which project's numbers it is showing is a correctness bug
/// in this app. The ground therefore arrives before the branching does, and a new
/// branch inherits it. `pageSurface()` still paints the same colour under a list
/// and still has to, because a `List` draws over anything behind it.
private struct ScreenChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        #if os(visionOS)
        // `navigationSubtitle` is unavailable on visionOS, and simply dropping
        // it would delete the only permanently visible statement of *whose
        // numbers these are*. The project switcher stays a compact glyph here,
        // so the address moves into the adjacent toolbar item.
        content
            .background(Theme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                        // Spoken by the switcher's own accessibility label
                        // already; a second reading of the project name on
                        // every screen is noise.
                        .accessibilityHidden(true)
                }
            }
        #elseif os(tvOS)
        // The television switcher carries the address inside its own large,
        // focusable label. A second leading toolbar item put the address above
        // an icon-only circle instead of beside it, producing two disconnected
        // pieces of one control.
        content
            .background(Theme.pageBackground)
        #elseif os(iOS)
        content
            .background(Theme.pageBackground)
            // A navigation subtitle is deliberately compact, but at AX5 that
            // compactness becomes truncation: the organization survives while
            // the project — the part that scopes every number — disappears.
            // Keep the native subtitle at ordinary sizes and spend one content
            // row only where a compact-width user has explicitly asked for the
            // larger reading measure.
            .navigationSubtitle(usesAccessibilityIdentityStamp ? "" : subtitle)
            .safeAreaInset(edge: .top, spacing: 0) {
                if usesAccessibilityIdentityStamp {
                    accessibilityIdentityStamp
                }
            }
        #else
        content
            .background(Theme.pageBackground)
            .navigationSubtitle(subtitle)
        #endif
    }

    #if os(iOS)
    private var usesAccessibilityIdentityStamp: Bool {
        horizontalSizeClass == .compact && dynamicTypeSize.isAccessibilitySize
    }

    /// A correctness-critical address gets a reading measure of its own at
    /// accessibility sizes instead of being compressed into navigation chrome.
    /// The names remain separate accessibility elements because each half can
    /// change independently when the user switches organization or project.
    private var accessibilityIdentityStamp: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.isMultiOrganization,
               let organization = model.selectedOrganization?.name,
               !organization.isEmpty {
                Text(organization)
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let project = model.selectedProject?.name, !project.isEmpty {
                Text(project)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.pageBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
    }
    #endif

    /// The project, and the organization too once there is more than one.
    ///
    /// This subtitle is the only permanently visible statement of *whose numbers
    /// these are* — the toolbar switcher is a glyph precisely because repeating
    /// the name there cost a whole row of chrome on every pushed screen. Two
    /// organizations can hold projects with the same name (a "Default project"
    /// each, which is what PostHog creates), so for a multi-organization user the
    /// project name on its own does not identify anything, and this app treats
    /// showing the wrong project's numbers as a correctness bug rather than a
    /// cosmetic one.
    ///
    /// Still just the project name for the single-organization user, which is
    /// most of them: there the organization is a constant, and a constant
    /// occupies the line without narrowing anything.
    ///
    /// The separator is a middle dot with hair spaces, the same one the
    /// annotations list uses to join origin and scope, so the two names read as
    /// one address rather than as a sentence.
    private var subtitle: String {
        let project = model.selectedProject?.name ?? ""
        guard model.isMultiOrganization,
              let organization = model.selectedOrganization?.name,
              !project.isEmpty
        else { return project }
        return "\(organization) · \(project)"
    }
}

extension View {
    /// Shows the current project under the title, on the app's ground.
    /// Pair with `ProjectSwitcher`.
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
    var brandGlyph: BrandObjectGlyph? = nil
    var tint: Color = Theme.accent
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let brandGlyph {
                BrandObjectGlyphView(glyph: brandGlyph, size: size * 0.62, tint: tint)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
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
    /// Read because the row changes shape rather than shrinking at accessibility
    /// sizes; see `layout`.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The row's own width, because the same reshape is owed to a narrow column
    /// as to a large type size; see `isStacked`.
    @State private var width: CGFloat = .greatestFiniteMagnitude

    let glyph: String
    var brandGlyph: BrandObjectGlyph? = nil
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String?
    /// Third line, for provenance or freshness — kept to a caption so it recedes
    /// behind the title by size. It recedes by colour too, but on a measured
    /// token rather than the system ramp, and it took two passes to get there:
    /// `.tertiary` measured 1.84:1 against a light card, and the `.secondary`
    /// that replaced it sampled #7F7F7F on #FFFFFF — 4.00:1 across ~1230 pixels
    /// at the plateau colour, so not an antialiasing artefact — against a 4.5:1
    /// AA floor. "Updated last month", "3 users · 5 sessions · 13 occurrences"
    /// and "7h ago · expires in 3mo" are the row's only dates and counts, so
    /// they were the least readable text in the app and among the most worth
    /// reading. See `supportingText`.
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
    /// How many lines the footnote may take. One by default, as before.
    ///
    /// A knob for the same reason as the subtitle's, and for a sharper case:
    /// the footnote is where the *varying* part of a row often sits, so one line
    /// clips exactly what tells two rows apart. Every People row read
    /// `2 distinct IDs · First seen Jul 2…` — same prefix, and the day of the
    /// month, the only difference between them, is what went.
    var footnoteLineLimit: Int = 1
    /// One line with middle truncation, for titles that are emails or other
    /// atomic identifiers. Wrapping broke them mid-token — measured in the sweep as
    /// `lambatailorlove@g` / `mail.com` on People and an orphan `m` on the
    /// iPad Sessions sidebar — and a token split across lines reads as two
    /// tokens. Middle truncation keeps the start of the local part and the
    /// whole domain, which are the parts that identify someone. Accessibility
    /// sizes still wrap: at that scale a single truncated line holds almost
    /// nothing.
    var titleTruncatesMiddle = false
    var accessory: RowAccessory = .chevron

    var body: some View {
        layout
            // Nothing a row renders is prose: titles are exception types, event
            // names and addresses, subtitles are keys and paths, footnotes are
            // counts and dates. Typesetting them as prose inserted soft hyphens
            // that render as real ones and change what the string says —
            // sample.user@example.org`, sample.user@example.org`,
            // `$autocap-ture` — and a reader cannot tell an invented hyphen from
            // one that was always there. `zxx` is the ISO code for "no
            // linguistic content", so no hyphenation dictionary applies and a
            // line breaks only where the string already allows it.
            .typesettingLanguage(Locale.Language(identifier: "zxx"))
            .padding(.vertical, Theme.Space.xs)
            .contentShape(.rect)
            // Measured rather than inferred. There is no trait that separates
            // the two regular-width columns this row lives in — an iPad
            // split-view sidebar and the detail beside it are both `.regular`,
            // and the sidebar is a third of the width. The row's own geometry is
            // the only thing that knows.
            //
            // Stable, not a feedback loop: the stacked layout claims the width
            // it was offered rather than asking for a different one, so reading
            // the width cannot change it.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            #if os(tvOS)
            // tvOS changes a focused control's effective appearance to light.
            // The row card itself remains on the dark television surface, so
            // allowing semantic text colours to follow that transient value
            // turns every label near-black without repainting the card. Keep
            // DataRow's authored dark-card palette stable through focus.
            .environment(\.colorScheme, .dark)
            #endif
    }

    /// Whether the row gives up on fitting its parts side by side.
    ///
    /// Two independent ways a row runs out of room, and the answer to both is
    /// the same reshape.
    ///
    /// Type size was the one already handled. Width is the one the iPad sweep
    /// found: in portrait a split-view sidebar takes its declared *minimum*
    /// width, which left `DataRow` ~253pt to hold a 32pt glyph, a ~95pt status
    /// pill and the string that identifies the row. The string lost. Measured on
    /// `build/Screenshots/iPad Pro 11-inch (M5)/light/`:
    ///
    /// | screen | sidebar row | same string in the detail column |
    /// |---|---|---|
    /// | `flags` | `dashboard-b…` | `dashboard-badge` |
    /// | `people` | `nina.drill.072` / `9@example…` | sample.user@example.org` |
    /// | `cohorts-list` | `People who ar…` | `People who are internal team members…` |
    ///
    /// The sidebar is where a row is *chosen*, so it is the one column where the
    /// identifier has to survive — and it was the only column where it did not.
    /// Stacked, the accessory takes its own line and the text gets the row.
    private var isStacked: Bool {
        typeSize.isAccessibilitySize || width < Theme.Measure.stackedRow
    }

    /// Text beside the glyph normally, stacked beneath it when the row is short
    /// of room — at accessibility sizes, or in a narrow column.
    ///
    /// The glyph and the accessory are fixed furniture: they hold their width
    /// whatever the type size, so what they leave over is all the text ever gets.
    /// At `accessibility-extra-extra-large` on iPhone that was a few characters —
    /// an Errors row read `Refer-/ence…`, `In-/stan…`, `4 users…` beside a pill
    /// spelling `Ac-/tive`, which is a row carrying no information but its
    /// colour. Stacked, every line gets the whole row to break in.
    @ViewBuilder
    private var layout: some View {
        if isStacked {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    RowGlyph(systemName: glyph, brandGlyph: brandGlyph, tint: tint)
                    titleText
                }

                supportingText
                stackedAccessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: Theme.Space.m) {
                RowGlyph(systemName: glyph, brandGlyph: brandGlyph, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    supportingText
                }

                Spacer(minLength: Theme.Space.s)

                accessoryView
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(Theme.Typography.title)
            .foregroundStyle(.primary)
            // Uncapped at accessibility sizes: two lines of type that large is
            // half a word, and the cap exists to keep rows an even height, which
            // is a scanning concern that no longer applies at those sizes.
            .lineLimit(typeSize.isAccessibilitySize ? nil : (titleTruncatesMiddle ? 1 : 2))
            .truncationMode(
                titleTruncatesMiddle && !typeSize.isAccessibilitySize ? .middle : .tail
            )
    }

    /// On `Theme.Ink`, not on SwiftUI's `.secondary`.
    ///
    /// Both lines rendered #7F7F7F on #FFFFFF in light mode — 4.00:1, under the
    /// 4.5:1 AA floor, sampled over ~1230 pixels at the plateau colour so it is
    /// the composited result and not an edge artefact. Dark mode passed at
    /// 5.15:1, which is why the failure survived a pass that moved ~20 other
    /// surfaces onto these tokens: nothing looked wrong in the appearance the
    /// screenshots were taken in. `DataRow` is every list screen in the app, so
    /// this was the single most-rendered piece of failing text there is.
    ///
    /// The two-step ramp is kept — subtitle above footnote — because the
    /// hierarchy is the reason these lines are quiet in the first place; what
    /// changes is that the bottom step is now legible rather than merely faint.
    @ViewBuilder
    private var supportingText: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(isSubtitleMonospaced ? Theme.Typography.body.monospaced() : Theme.Typography.body)
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : subtitleLineLimit)
        }

        if let footnote, !footnote.isEmpty {
            Text(footnote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : footnoteLineLimit)
        }
    }

    /// The chevron is the one accessory the stacked row drops.
    ///
    /// It is decorative — the whole row is the tap target and VoiceOver is told
    /// to ignore it — so on its own line beneath the text it would be a large
    /// grey arrow pointing at nothing, costing a line to say what the row's
    /// tappability already says. A metric or a pill is content and keeps its
    /// line: the pill's word is the only non-colour encoding its state has.
    @ViewBuilder
    private var stackedAccessory: some View {
        if case .chevron = accessory {
            EmptyView()
        } else {
            accessoryView
        }
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
                // Same 4.00:1 measurement as `supportingText`, and the same fix.
                // Semibold body is still below the 18.66pt the large-text
                // exemption starts at, so the 4.5:1 floor applies here too — and
                // this is the number the column exists to be scanned for.
                .foregroundStyle(Theme.Ink.secondary)
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
    /// Overview summaries can opt into a reading-order stack at accessibility
    /// sizes. The default remains a horizontal strip for dense data surfaces
    /// where scrolling is the established interaction.
    var stacksAtAccessibilitySizes: Bool = false
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if stacksAtAccessibilitySizes && dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                content
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        } else {
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
}

// MARK: - Empty and locked states

/// The app's empty state.
///
/// Uses `ContentUnavailableView` wherever its native layout is stable, and a
/// semantics-equivalent wide composition for ordinary iPad text, so the glyph,
/// tone and action placement are decided once. Most of these screens are
/// legitimately empty against a real project, so an empty state here is a
/// normal outcome and should look deliberate rather than broken.
///
/// Which is why it carries `appGround()` itself rather than trusting its host.
/// `ScreenChrome` covers every root, but this view is also the *detail column* of
/// the three split-view screens, and a detail column has no chrome of its own:
/// on iPad the "Pick an insight" placeholder sampled `#F7F7F7` — half the screen,
/// a cool grey, beside a cream sidebar. Two grounds of the same colour cost
/// nothing; a state view that only looks right in one of its two homes costs the
/// larger half of an iPad.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var illustration: BrandIllustration? = nil
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
            readableWideContent
                .appGround()
        } else {
            systemContent
                .appGround()
        }
        #else
        systemContent
            .appGround()
        #endif
    }

    /// `ContentUnavailableView` remains the native compact-width, accessibility
    /// type, and non-iOS presentation. At AX sizes it owns the scrolling that
    /// keeps the action reachable. Constraining either it or its description to
    /// a finite width on iPad causes the accessibility tree to stop responding
    /// while SwiftUI resolves the empty-state layout, so the wide presentation
    /// below owns only the ordinary-type adaptation explicitly.
    private var systemContent: some View {
        ContentUnavailableView {
            Label {
                // The headline states the only thing on the screen. It has to be
                // allowed to take the lines it needs, and the caps that would
                // stop it are not this view's to see: `ContentUnavailableView`
                // draws its own title style, and the sweep reported an `inbox`
                // headline set as `Nothing to tr…` on one line at AX5. **Not
                // reproduced here** — in demo mode the Inbox reaches its error
                // branch instead (there is no `/tasks/` fixture), and rendered
                // on its own at AX5 in a 393pt window this title wraps to two
                // lines correctly. So this is a guard, not an observed cure: it
                // says explicitly what was being relied on implicitly, and an
                // inner `lineLimit` outranks anything the style sets outside it.
                Text(title)
                    .lineLimit(nil)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                if let illustration {
                    BrandIllustrationView(
                        illustration: illustration,
                        size: dynamicTypeSize.isAccessibilitySize ? 112 : 152
                    )
                } else {
                    Image(systemName: systemImage)
                }
            }
        } description: {
            if let message {
                Text(message)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    // `.glassProminent` is unavailable on visionOS;
                    // `.borderedProminent` is what that platform gives a
                    // primary action, and it keeps the filled weight this
                    // button needs. Same substitution `GetHogUI` already makes
                    // for `.glass`.
                    #if os(visionOS)
                    .buttonStyle(.borderedProminent)
                    #else
                    .buttonStyle(.glassProminent)
                    #endif
                    // See `Theme.inkOnAccent`. The shared empty state, so this
                    // is the widest single site — and it *is* photographed:
                    // Inbox reaches this branch in demo mode (no `/tasks/`
                    // fixture), and its "Try again" measured **2.09:1** in dark
                    // before and **8.82:1** after, with light unmoved at 6.08:1.
                    .foregroundStyle(Theme.inkOnAccent)
            }
        }
    }

    #if os(iOS)
    /// The regular-width equivalent of `ContentUnavailableView`.
    ///
    /// It preserves the native content order and accessible elements, but the
    /// prose lives in a layout we own and can therefore stop at a readable
    /// measure without putting a finite frame inside `ContentUnavailableView`.
    private var readableWideContent: some View {
        VStack(spacing: Theme.Space.l) {
            if let illustration {
                BrandIllustrationView(
                    illustration: illustration,
                    size: dynamicTypeSize.isAccessibilitySize ? 112 : 152
                )
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(Theme.Ink.secondary)
                    .accessibilityHidden(true)
            }

            VStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if let message {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(Theme.inkOnAccent)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.xl)
        .frame(maxWidth: Theme.Measure.prose)
    }
    #endif
}

// MARK: - Filter bar

/// Warm-glass container for the controls above a data surface.
///
/// Filters belong in one row above the content, in a surface that reads as
/// chrome rather than as another card — otherwise a segmented control sitting
/// loose on the ground looks like a tile that failed to load.
///
/// **One row, until a row is the wrong shape.** The controls in this bar are
/// text — a menu label, a toggle's word, a segment's title — and they are the
/// only elastic things in it, so a row divides one phone width between two or
/// three of them and each gets a column narrower than its own label. Measured at
/// AX5 on an iPhone 17 Pro (393pt), all three on screens this bar serves:
///
/// | screen    | at AX5, side by side                                          |
/// | --------- | ------------------------------------------------------------- |
/// | Insights  | `All kinds` set over three lines with the chevron stranded mid-line, beside a `Favorites` toggle wrapped one or two characters per line into a ~700pt-tall capsule — the bar alone filled 40% of the window |
/// | Logs      | the severity toggle's word pushed out of the bar entirely, leaving a bare `!` glyph ~5px from the trailing edge |
/// | Ingestion | a segmented `48h / 7d / 30d` that did not scale at all while every neighbour did |
///
/// So past the accessibility threshold the bar stacks, which is the same reflow
/// `FunnelStepRow` and `InsightLegend` make and for the same reason: on a narrow
/// column a shared row leaves each control a couple of characters, and every
/// control here gets the whole width to break in instead.
///
/// A caller that wants its first control to push the rest to the trailing edge
/// should say so with `.frame(maxWidth: .infinity, alignment: .leading)` on that
/// control rather than with a `Spacer` between them — a `Spacer` means something
/// different in each of these two layouts, and this one has both.
struct GlassFilterBar<Content: View>: View {
    /// Read because the bar changes shape rather than shrinking; see `layout`.
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder var content: Content

    var body: some View {
        layout
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .warmGlass(in: .rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            // Capped, because every caller in this app tells its first control
            // to claim the bar — `.frame(maxWidth: .infinity, alignment:
            // .leading)`, which is the documented way to ask for it, and which
            // the paragraph above recommends. On a phone that is right: the
            // control fills a 361pt bar and starts at the same margin as the
            // list below it. On an iPad the same instruction produced a 770pt
            // slab of glass holding one menu — measured on `renders`
            // (`All (5)`, ~85% empty) and `automation` (`Workflows`, the same) —
            // and in landscape a 1178pt one.
            //
            // 420pt is `DashboardDetailView`'s existing number for exactly this,
            // arrived at there for a segmented control and reused here so the
            // bar and the pickers inside it stop at the same place. Below it
            // nothing changes, so no phone layout moves.
            .frame(maxWidth: Theme.Measure.control)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l)
    }

    @ViewBuilder
    private var layout: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                content
            }
            // Without this the stacked bar hugs its widest control and the glass
            // becomes a pill floating in the middle of the screen — the same
            // collapse `RendersRoot` already had to correct on its single menu.
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: Theme.Space.m) {
                content
            }
        }
    }
}

extension View {
    /// Contrast-safe foreground for an accent-filled television control.
    ///
    /// tvOS toolbar and bordered controls paint the app tint through their
    /// focus surface. A glyph or label that inherits the same tint disappears
    /// into that fill; touch and pointer platforms do not use this treatment,
    /// so the modifier is deliberately an identity everywhere else.
    @ViewBuilder
    func televisionAccentControlInk() -> some View {
        #if os(tvOS)
        foregroundStyle(Theme.televisionControlInk)
        #else
        self
        #endif
    }
}

/// A segmented picker below the accessibility sizes, a menu at and above them.
///
/// Segmented controls divide their width by their segment count and shrink the
/// labels to fit, so they are the one picker style that gets *less* legible as
/// the type grows — at AX5 Ingestion's `48h / 7d / 30d` was drawn at the same
/// size as at default while everything around it had tripled.
///
/// The adaptation itself is not new: five screens had each grown a private
/// `adaptivelyStyled` doing exactly this, and a sixth — Ingestion — had not, which
/// is the defect. This is that function, named once. `TaxonomyRoot`,
/// `SessionFilterSheet` and `IngestionWarningsRoot` are on it; `PeopleRoot`,
/// `DashboardDetailView` and `LLMAnalyticsRoot` still carry their own copies and
/// should move here when they are next touched.
///
/// A `ViewModifier` rather than a `View` extension taking the size, so the
/// environment is read where the picker is rather than at each call site: a call
/// site that forgot the `@Environment` property would compile and silently pin
/// the style to whatever it passed.
///
/// Two branches rather than a ternary on the style, because
/// `SegmentedPickerStyle` and `MenuPickerStyle` are different concrete types and
/// cannot share an expression — the same shape `InsightsRoot` documents on its
/// label styles.
private struct AdaptivePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

extension View {
    /// See `AdaptivePickerStyle`.
    func adaptivePickerStyle() -> some View { modifier(AdaptivePickerStyle()) }
}
