import GetHogUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum Platform {
    /// Whether this device can show more than one window at a time.
    ///
    /// False on iPhone, so tear-off affordances are hidden rather than offered
    /// and then quietly doing nothing.
    static var supportsMultipleWindows: Bool {
        #if os(iOS) || os(tvOS)
        // `supportsMultipleScenes` is real on tvOS and answers false there, so
        // asking it turns the `#else`'s flat `true` from a lie into a measured
        // fact — which is what keeps the dashboard tear-off entry honest on a
        // platform with exactly one screen.
        UIApplication.shared.supportsMultipleScenes
        #else
        true
        #endif
    }
}

/// Interaction and presentation dimensions that differ by input model.
///
/// A Mac pointer does not need a fingertip-sized target, while every touch
/// platform keeps the 44pt floor. List-card separation lives here for the same
/// reason: `listRowSpacing` is unavailable on macOS, so the clipped background
/// itself has to provide the desktop rhythm without changing iPhone or iPad.
enum PlatformPresentationMetrics {
    static let minimumInteractiveLength = PlatformControlMetrics.minimumInteractiveLength

    #if os(macOS)
    static let listCardVerticalInset: CGFloat = 3
    #else
    static let listCardVerticalInset: CGFloat = 1
    #endif
}

/// The clipped card shape used by list-row backgrounds.
///
/// The DEBUG Mac overlay exposes the colored shape's frame to XCUITest. It is
/// deliberately inside the vertical padding: the marker therefore shrinks with
/// the card, while the `List` row and its actionable `NavigationLink` keep their
/// unchanged frames. Release builds and non-Mac platforms add no accessibility
/// element.
private struct ListCardBackground: View {
    let route: String
    let id: String

    var body: some View {
        Theme.cardBackground
            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay {
                #if DEBUG && os(macOS)
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("List card background")
                    .accessibilityIdentifier("gethog.list-card-background.\(route).\(id)")
                #endif
            }
            .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
    }
}

/// A hardware-keyboard shortcut with no on-screen control of its own.
struct KeyboardAction: Identifiable {
    let id = UUID()
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    let title: String
    let action: () -> Void
}

/// Motion policy for the shared Mac pointer highlight.
///
/// The outline itself remains useful feedback with Reduce Motion enabled; only
/// its transition disappears, so hover state updates immediately rather than
/// fading in or out.
enum PointerHighlightMotion {
    static func transitionDuration(reduceMotion: Bool) -> Double? {
        reduceMotion ? nil : 0.12
    }
}

private struct PointerHighlightModifier: ViewModifier {
    let cornerRadius: CGFloat

    #if os(macOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .contentShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isHovered ? Theme.accent.opacity(0.55) : Color.clear,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .animation(pointerHighlightAnimation, value: isHovered)
            .onHover { isHovered = $0 }
        #elseif os(iOS) || os(visionOS)
        content
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius))
            .hoverEffect(.highlight)
        #else
        content
        #endif
    }

    #if os(macOS)
    private var pointerHighlightAnimation: Animation? {
        guard let duration = PointerHighlightMotion.transitionDuration(
            reduceMotion: reduceMotion
        ) else {
            return nil
        }
        return .easeOut(duration: duration)
    }
    #endif
}

extension View {
    /// Applies the shared clipped row background and, in DEBUG Mac builds,
    /// exposes the actual colored frame for rendered geometry tests.
    func listCardBackground(route: String, id: String) -> some View {
        listRowBackground(ListCardBackground(route: route, id: id))
    }

    /// Attaches keyboard shortcuts that aren't already carried by a visible button.
    ///
    /// SwiftUI only routes `.keyboardShortcut` from a `Button` that is genuinely
    /// in the hierarchy, so these are real buttons held at zero opacity rather
    /// than `.hidden()` — a hidden view leaves the layout and stops responding.
    /// They sit in `.background` so they can never displace content, and they are
    /// dropped from the accessibility tree, because a VoiceOver user swiping
    /// through a screen should not run into invisible controls.
    func keyboardActions(_ actions: [KeyboardAction]) -> some View {
        #if os(tvOS)
        // `keyboardShortcut` is unavailable on tvOS — the remote is the input
        // device and there is no modifier to press. The call sites keep their
        // `KeyboardAction` lists (the type itself compiles fine, and every
        // action here is also reachable from a visible control), and this
        // becomes the identity it already effectively is on a touch device.
        return self
        #else
        return background {
            ZStack {
                ForEach(actions) { shortcut in
                    Button(shortcut.title, action: shortcut.action)
                        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
    }

    /// Pointer highlight for iPad, Stage Manager, Vision Pro and Mac.
    ///
    /// A no-op on touch-only devices, so this needs no size-class branching.
    /// The shape is set with `contentShape(.hoverEffect:)` rather than by
    /// clipping, so the highlight follows the card's corner radius instead of
    /// the square bounding box the pointer would otherwise light up.
    ///
    /// visionOS takes the UIKit branch deliberately, not incidentally: the
    /// hover effect *is* the gaze feedback primitive there, so a card that
    /// opts out of it is a card the eye cannot tell it has landed on.
    func pointerHighlight(cornerRadius: CGFloat = 14) -> some View {
        modifier(PointerHighlightModifier(cornerRadius: cornerRadius))
    }

    /// Raises a control to its platform's minimum interactive floor.
    ///
    /// Only the box changes — no font, tint, padding or background is touched —
    /// so a control keeps the visual weight it was designed with and gains the
    /// area a fingertip needs.
    ///
    /// Where it goes matters, and the two cases differ. A bordered control
    /// (`.toggleStyle(.button)`, `.buttonStyle(.bordered)`) draws its background
    /// into whatever size it is offered, so applying this to the control itself
    /// grows the real, visible target. A borderless `Menu` or `Button` draws no
    /// background: its tap region and its accessibility frame are its label's
    /// bounds and nothing else, so this has to go *inside* the label closure.
    /// Applied the other way round it centres the control in a roomier box and
    /// moves nothing an audit can see.
    func minimumHitTarget() -> some View {
        frame(
            minWidth: PlatformPresentationMetrics.minimumInteractiveLength,
            minHeight: PlatformPresentationMetrics.minimumInteractiveLength
        )
            .contentShape(.rect)
    }
}

// MARK: - Hoisted detail chrome

/// The chrome around a detail a screen opens without pushing it itself.
///
/// iOS presents the four `presentsDetailAsSheet` details as sheets, which
/// arrive with no navigation chrome of their own, so the container supplies a
/// stack for the title and the Done button. macOS and visionOS push the same
/// detail inline (`MacRootView` and `VisionRootView` both bind
/// `navigationDestination(item:)` to `OpenDetails`), where the hosting stack
/// already has the bar — a second stack would nest, and Done would duplicate
/// Back.
///
/// **This is a fact about those shells, not about every non-iOS
/// presentation.** A Mac or Vision caller that genuinely sheets one of these
/// four gets a view with no title and no way out, and must supply both itself
/// — `SurveySearchSheet` is the one such caller and `sheetChrome` there is
/// what it does about it. Any new one has the same obligation.
struct DetailSheetContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(iOS)
        NavigationStack { content }
        #else
        content
        #endif
    }
}
