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
        #if os(iOS)
        UIApplication.shared.supportsMultipleScenes
        #else
        true
        #endif
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

extension View {
    /// Attaches keyboard shortcuts that aren't already carried by a visible button.
    ///
    /// SwiftUI only routes `.keyboardShortcut` from a `Button` that is genuinely
    /// in the hierarchy, so these are real buttons held at zero opacity rather
    /// than `.hidden()` — a hidden view leaves the layout and stops responding.
    /// They sit in `.background` so they can never displace content, and they are
    /// dropped from the accessibility tree, because a VoiceOver user swiping
    /// through a screen should not run into invisible controls.
    func keyboardActions(_ actions: [KeyboardAction]) -> some View {
        background {
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
    }

    /// Pointer highlight for iPad, Stage Manager and Mac.
    ///
    /// A no-op on touch-only devices, so this needs no size-class branching.
    /// The shape is set with `contentShape(.hoverEffect:)` rather than by
    /// clipping, so the highlight follows the card's corner radius instead of
    /// the square bounding box the pointer would otherwise light up.
    func pointerHighlight(cornerRadius: CGFloat = 14) -> some View {
        #if os(iOS)
        contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius))
            .hoverEffect(.highlight)
        #else
        // AppKit draws its own pointer affordances; the shape is kept so hit
        // testing still follows the card's corner radius.
        contentShape(.rect(cornerRadius: cornerRadius))
        #endif
    }

    /// Raises a control to the 44×44pt floor Apple's `hitRegion` audit checks.
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
        frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }
}
