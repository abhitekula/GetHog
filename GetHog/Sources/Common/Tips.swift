import GetHogKit
import SwiftUI
import TipKit

/// Point-of-use tips.
///
/// The tips are *defined* here but *displayed* next to the control each one
/// describes. Nothing is front-loaded into a launch tutorial: a carousel shown
/// before the user has a reason to care is read once and remembered by nobody,
/// whereas a tip attached to the chart teaches the gesture at the moment the
/// chart is on screen.
///
/// Dismissal state belongs to TipKit rather than to `@AppStorage`. Hand-rolled
/// flags would have to reimplement what TipKit already owns — permanent
/// invalidation on close, display cadence, and rule re-evaluation — and would
/// get the "never show this again" contract subtly wrong.
enum AppTips {

    /// Called once at launch. Kept here so the app entry point carries a single
    /// line and none of the policy.
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// Pushes the current key's capabilities into the tips' rules.
    ///
    /// A tip for a feature the user's API key cannot reach is pure noise, so
    /// availability is a rule rather than a check at the call site — TipKit then
    /// suppresses the tip without the view having to know it exists.
    @MainActor
    static func refresh(from model: AppModel) {
        ChartScrubTip.isAvailable = model.isAvailable(.dashboards)
        FlagWidgetTip.isAvailable = model.isAvailable(.flags)
        // Not a capability: switching is meaningless with one project, and the
        // key's scopes have nothing to do with it.
        ProjectSwitchTip.hasMultipleProjects = model.projects.count > 1
    }
}

// MARK: - Presentation

/// A tip, in the app's palette, on the app's card.
///
/// Use this rather than `TipView` directly. The style is the point — a bare
/// `TipView` is not merely off-palette, it is **below AA**:
///
/// | | body text | on TipKit's surface | ratio |
/// |---|---|---|---|
/// | light | `#7F7F7F` | `#FFFFFF` | **4.00:1** |
/// | dark  | `#8F8F8E` | `#1F1E1C` | 5.15:1 |
/// | light | close glyph `#8A8A8E` | chip `#E2E2E3` | **2.66:1** |
/// | dark  | close glyph `#99999E` | chip `#3D3C3C` | 3.88:1 |
///
/// sampled off `flags.png` on iPhone 17 Pro. TipKit draws its message in the
/// system's `.secondary`, which is `rgba(60,60,67,0.6)` and composites to
/// `#7F7F7F` on white — the same alpha-ink failure `Theme.Ink` was created for,
/// arriving through a framework rather than through a call site. Its close
/// control is a second, separate failure: a glyph is a meaningful graphic and
/// owes WCAG's 3:1, and 2.66:1 is under it.
///
/// **Neither is reachable with a modifier.** `tipBackground` and
/// `tipCornerRadius` are the whole of the surface API and there is no foreground
/// equivalent, and TipKit is demonstrably setting the message's ink itself: the
/// sample above is `secondaryLabel` composited on the card, not anything the
/// call site handed down. (Whether a `.foregroundStyle` on the `TipView` would
/// beat it was **not** tested — this went straight to the lever that cannot
/// miss.) A `TipViewStyle` replaces the body outright, so the ink is set by
/// construction rather than by hoping a modifier lands in the right place.
///
/// It also means this style now owns everything TipKit was drawing, including
/// the dismiss control. `configuration` vends `title`, `message`, `image` and
/// `actions` and *not* a close button, so it is built here — 44pt, and wired to
/// `invalidate(reason: .tipClosed)`, which is the same permanent-dismissal
/// contract `AppTips` chose TipKit for in the first place.
///
/// Wrapped as a `View` rather than left as a loose style, so the two call sites
/// cannot pick up the tip and forget the style.
struct AppTipView: View {
    let tip: any Tip

    init(_ tip: any Tip) { self.tip = tip }

    var body: some View {
        TipView(tip)
            .tipViewStyle(AppTipViewStyle())
    }
}

/// See `AppTipView`, which is how this is reached.
struct AppTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        TipCard(configuration: configuration)
    }

    /// A real `View`, and that is the point rather than a stylistic preference.
    ///
    /// The first version of this style put `@Environment(\.dynamicTypeSize)` on
    /// `AppTipViewStyle` itself. It compiles, it reads as correct, and it does
    /// **nothing**: a `TipViewStyle` is not a `View`, so SwiftUI never resolves
    /// its dynamic properties and the wrapper stays on its default `.large`
    /// forever. Caught by looking at `ax5/saved-insight-detail.png`, where the
    /// glyph this was supposed to drop was still there. Same class of mistake as
    /// the `.accessibilityHidden(true)` this codebase already has a note about —
    /// a modifier that is silently inert.
    private struct TipCard: View {
        let configuration: Configuration

        /// The leading glyph is dropped past the accessibility threshold. It is
        /// decoration — every tip's meaning is in its title and message, and the
        /// image is already hidden from VoiceOver — and at AX5 it competes for
        /// width with prose that has tripled in size.
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            Card(padding: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        if let image = configuration.image, !typeSize.isAccessibilitySize {
                            image
                                .font(.title2)
                                .foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                        }

                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            if let title = configuration.title {
                                title.font(Theme.Typography.title)
                            }
                            if let message = configuration.message {
                                message
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Ink.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // One stop, not two: a tip is a single thing to read, and
                        // its title on its own says nothing useful. Safe to
                        // combine here — nothing in this subtree is suppressed,
                        // which is the case where `.combine` silently ignores a
                        // child's `accessibilityHidden`.
                        .accessibilityElement(children: .combine)

                        // TipKit's own close control, rebuilt: 2.66:1 in light as
                        // it shipped, and a tap target the framework does not
                        // state. The 44pt frame is inside the label closure
                        // because that is where a `.plain` button's tap region
                        // comes from.
                        //
                        // `configuration.tip` is `any Tip`, and
                        // `invalidate(reason:)` is callable on the existential
                        // because its `InvalidationReason` is a concrete typealias
                        // for `Tips.InvalidationReason` rather than an associated
                        // type.
                        Button {
                            configuration.tip.invalidate(reason: .tipClosed)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.Ink.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss tip")
                    }

                    // None of this app's three tips defines an action today.
                    // Drawn anyway, because a style that silently dropped them
                    // would make the *next* tip's button disappear with nothing
                    // to point at.
                    if !configuration.actions.isEmpty {
                        HStack(spacing: Theme.Space.l) {
                            ForEach(configuration.actions) { action in
                                Button(action: action.handler) {
                                    action.label()
                                        .font(Theme.Typography.body.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.Status.accentInk)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Attach to a chart that supports drag-to-scrub.
struct ChartScrubTip: Tip {
    @Parameter static var isAvailable: Bool = false

    var title: Text { Text("Read exact values") }

    var message: Text? {
        Text("Touch and drag across a chart to scrub through it point by point.")
    }

    var image: Image? { Image(systemName: "hand.draw") }

    var rules: [Rule] {
        #Rule(Self.$isAvailable) { $0 == true }
    }
}

/// Attach to a project-switching control.
struct ProjectSwitchTip: Tip {
    @Parameter static var hasMultipleProjects: Bool = false

    var title: Text { Text("Switch project") }

    var message: Text? {
        Text("Every screen shows one project at a time. Change it here and the whole app follows.")
    }

    var image: Image? { Image(systemName: "rectangle.2.swap") }

    var rules: [Rule] {
        #Rule(Self.$hasMultipleProjects) { $0 == true }
    }
}

/// Attach to the feature flag list.
struct FlagWidgetTip: Tip {
    @Parameter static var isAvailable: Bool = false

    var title: Text { Text("Keep a flag to hand") }

    var message: Text? {
        Text("Add a GetHog widget to your Home Screen, or a control to Control Center, to watch and toggle a flag without opening the app.")
    }

    var image: Image? { Image(systemName: "square.grid.2x2") }

    var rules: [Rule] {
        #Rule(Self.$isAvailable) { $0 == true }
    }
}
