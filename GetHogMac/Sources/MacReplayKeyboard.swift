import AppKit
import SwiftUI

/// Keyboard transport for the Mac replay player (spec §3): space play/pause,
/// ←/→ seek, ⇧←/⇧→ larger jumps, `[` / `]` speed steps.
///
/// The mapping is a pure function so it can be tested without a web view or a
/// focus system: key plus playback state in, transport command out. The view
/// modifier below is the only part that touches SwiftUI, and it forwards every
/// command through the same `ReplayPlayerController` calls the on-screen
/// transport bar makes — the keyboard is a second set of fingers on the same
/// transport, never a second transport.
enum MacReplayKeyboard {
    enum Key: Equatable {
        case space
        case leftArrow
        case rightArrow
        case openBracket
        case closeBracket
    }

    enum Command: Equatable {
        case togglePlayPause
        case seek(to: TimeInterval)
        case setSpeed(Double)
    }

    /// Matches the transport bar's ±10-second skip buttons, so an arrow key
    /// and the glyph beside the play button always agree about a "step".
    static let seekStep: TimeInterval = 10
    /// Three steps at once — big enough to cross an idle stretch, small
    /// enough not to overshoot a short recording entirely.
    static let largeSeekStep: TimeInterval = 30
    /// The same ladder `PlayerTransportBar` offers in its speed menu.
    static let speeds: [Double] = [1, 2, 4]

    /// `nil` means the key is a no-op in this state (the ladder's ends), and
    /// a no-op should not cost a JavaScript round trip.
    static func command(
        for key: Key,
        shift: Bool,
        currentTime: TimeInterval,
        upperBound: TimeInterval,
        speed: Double
    ) -> Command? {
        let step = shift ? largeSeekStep : seekStep
        switch key {
        case .space:
            return .togglePlayPause
        case .leftArrow:
            return .seek(to: max(0, currentTime - step))
        case .rightArrow:
            return .seek(to: min(upperBound, currentTime + step))
        case .openBracket:
            return speeds.last(where: { $0 < speed }).map(Command.setSpeed)
        case .closeBracket:
            return speeds.first(where: { $0 > speed }).map(Command.setSpeed)
        }
    }

    /// Whether focus is sitting in something a person types into.
    ///
    /// Every key here is unmodified, which is the strongest claim a shortcut
    /// can make, and this window also carries the sessions search field — the
    /// Mac resolves `.navigationBarDrawer` to `.automatic`, which is the
    /// toolbar. A query typed while a replay is ready must reach the field,
    /// not the transport.
    ///
    /// Measured rather than assumed (`NSApp.sendEvent` against a hosted
    /// window): SwiftUI already declines to offer an unmodified key equivalent
    /// while a text responder has focus — space, `]`, ← and ⇧← all typed or
    /// moved the caret and fired nothing, in a `TextField` *and* in a toolbar
    /// search field, while the same keys fired every shortcut with focus on
    /// the window. This guard is the second line: if that behavior ever
    /// changes, one dropped keystroke is a far smaller wrong than a search
    /// query that plays, seeks and changes speed.
    ///
    /// `NSText` is the test — the field editor behind both a SwiftUI
    /// `TextField` (`_SystemTextFieldFieldEditor`) and an `NSSearchField`
    /// (`NSTextView`) — deliberately *not* `NSTextInputClient`: `WKWebView`
    /// conforms to that protocol, so the stage taking focus would have
    /// switched the transport off.
    @MainActor
    static func isTextInputFocused(in window: NSWindow?) -> Bool {
        switch window?.firstResponder {
        case let text as NSText: text.isEditable
        case let field as NSTextField: field.isEditable
        default: false
        }
    }
}

/// Registers the transport keys as window-level key equivalents while the
/// player container is on screen.
///
/// Hidden buttons rather than `onKeyPress`: `onKeyPress` fires only with
/// focus inside the subtree, and the one click that would grant the stage
/// focus is the click that expands it. A key equivalent needs no focus, which
/// is how every Mac video player treats its transport keys. The buttons are
/// zero-size, invisible, and out of the accessibility tree, and they disable
/// with the same `isReady` gate as the on-screen transport — before the
/// player is ready the keys keep their ordinary meanings (space still
/// scrolls the page). Typing keeps them too: see
/// `MacReplayKeyboard.isTextInputFocused(in:)` for what SwiftUI does about a
/// focused text field, what was measured, and the guard that backs it up.
private struct MacReplayKeyboardTransport: ViewModifier {
    let controller: ReplayPlayerController
    let duration: TimeInterval

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                shortcut(.space, key: .space)
                shortcut(.leftArrow, key: .leftArrow)
                shortcut(.leftArrow, key: .leftArrow, shift: true)
                shortcut(.rightArrow, key: .rightArrow)
                shortcut(.rightArrow, key: .rightArrow, shift: true)
                shortcut(KeyEquivalent("["), key: .openBracket)
                shortcut(KeyEquivalent("]"), key: .closeBracket)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(!controller.isReady)
        }
    }

    private func shortcut(
        _ equivalent: KeyEquivalent,
        key: MacReplayKeyboard.Key,
        shift: Bool = false
    ) -> some View {
        Button("") { perform(key, shift: shift) }
            .keyboardShortcut(equivalent, modifiers: shift ? [.shift] : [])
            .buttonStyle(.plain)
    }

    private func perform(_ key: MacReplayKeyboard.Key, shift: Bool) {
        guard !MacReplayKeyboard.isTextInputFocused(in: NSApp.keyWindow) else { return }
        guard let command = MacReplayKeyboard.command(
            for: key,
            shift: shift,
            currentTime: controller.currentTime,
            upperBound: ReplayTransportInteraction.sliderUpperBound(duration: duration),
            speed: controller.speed
        ) else { return }
        switch command {
        case .togglePlayPause:
            controller.togglePlayPause()
        case .seek(let target):
            // Default resume semantics, exactly like the ±10 s buttons:
            // a seek keeps playing if it was playing.
            controller.seek(to: target)
        case .setSpeed(let value):
            controller.setSpeed(value)
        }
    }
}

extension View {
    /// The Mac replay transport keys, active while this container is on
    /// screen and the player is ready.
    func macReplayKeyboardTransport(
        controller: ReplayPlayerController,
        duration: TimeInterval
    ) -> some View {
        modifier(MacReplayKeyboardTransport(controller: controller, duration: duration))
    }
}
