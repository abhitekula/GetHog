import AppKit
import Testing
import WebKit

@testable import GetHog

@Suite("Mac replay keyboard transport")
struct MacReplayKeyboardTests {
    @Test("space maps to play/pause")
    func spaceTogglesPlayback() {
        #expect(
            MacReplayKeyboard.command(
                for: .space, shift: false, currentTime: 12, upperBound: 100, speed: 2
            ) == .togglePlayPause
        )
    }

    @Test("plain arrows step by the transport bar's ten seconds")
    func arrowsStepTenSeconds() {
        #expect(
            MacReplayKeyboard.command(
                for: .rightArrow, shift: false, currentTime: 20, upperBound: 100, speed: 1
            ) == .seek(to: 30)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .leftArrow, shift: false, currentTime: 20, upperBound: 100, speed: 1
            ) == .seek(to: 10)
        )
    }

    @Test("shifted arrows take the larger jump")
    func shiftedArrowsJumpFurther() {
        #expect(
            MacReplayKeyboard.command(
                for: .rightArrow, shift: true, currentTime: 20, upperBound: 100, speed: 1
            ) == .seek(to: 50)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .leftArrow, shift: true, currentTime: 40, upperBound: 100, speed: 1
            ) == .seek(to: 10)
        )
    }

    @Test("seeks clamp to the playable range")
    func seeksClamp() {
        #expect(
            MacReplayKeyboard.command(
                for: .leftArrow, shift: true, currentTime: 5, upperBound: 100, speed: 1
            ) == .seek(to: 0)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .rightArrow, shift: false, currentTime: 95, upperBound: 100, speed: 1
            ) == .seek(to: 100)
        )
    }

    @Test("brackets walk the transport bar's speed ladder")
    func bracketsStepSpeed() {
        #expect(MacReplayKeyboard.speeds == [1, 2, 4])
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 1
            ) == .setSpeed(2)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 2
            ) == .setSpeed(4)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .openBracket, shift: false, currentTime: 0, upperBound: 100, speed: 4
            ) == .setSpeed(2)
        )
    }

    @Test("the ladder's ends are dead keys, not JavaScript round trips")
    func speedEndsAreNoOps() {
        #expect(
            MacReplayKeyboard.command(
                for: .openBracket, shift: false, currentTime: 0, upperBound: 100, speed: 1
            ) == nil
        )
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 4
            ) == nil
        )
    }

    @Test("an off-ladder speed still steps to a real rung")
    func offLadderSpeedRecovers() {
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 3
            ) == .setSpeed(4)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .openBracket, shift: false, currentTime: 0, upperBound: 100, speed: 3
            ) == .setSpeed(2)
        )
    }
}

/// Every transport key is unmodified, and the sessions search field shares the
/// window, so "is somebody typing?" is the question that decides whether the
/// keyboard may act at all.
@MainActor
@Suite("Mac replay keyboard scoping")
struct MacReplayKeyboardScopingTests {
    private func window(focusing responder: NSView?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        if let responder {
            responder.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
            window.contentView?.addSubview(responder)
            window.makeFirstResponder(responder)
        }
        return window
    }

    @Test("a window nobody is typing in leaves the transport its keys")
    func idleWindowKeepsTheKeys() {
        #expect(MacReplayKeyboard.isTextInputFocused(in: nil) == false)
        #expect(MacReplayKeyboard.isTextInputFocused(in: window(focusing: nil)) == false)
        #expect(MacReplayKeyboard.isTextInputFocused(in: window(focusing: NSButton())) == false)
    }

    @Test("a focused text field stands the transport down")
    func focusedTextFieldStandsTheTransportDown() {
        #expect(MacReplayKeyboard.isTextInputFocused(in: window(focusing: NSTextField())))
    }

    @Test("the sessions search field is the collision this guard exists for")
    func focusedSearchFieldStandsTheTransportDown() {
        // `SearchFieldPlacement.navigationBarDrawer` resolves to `.automatic`
        // on the Mac, which is this window's toolbar — the same window the
        // player is in.
        let search = NSSearchField()
        #expect(search is NSTextField)
        #expect(MacReplayKeyboard.isTextInputFocused(in: window(focusing: search)))
    }

    @Test("the field editor a focused text field installs counts as typing")
    func focusedFieldEditorStandsTheTransportDown() {
        // What a focused SwiftUI `TextField` actually leaves as first
        // responder: not the field, but an editable `NSText` standing in for
        // it, in the field's place in the responder chain.
        let editor = NSTextView()
        editor.isEditable = true
        #expect(MacReplayKeyboard.isTextInputFocused(in: window(focusing: editor)))
    }

    @Test("read-only text is not typing")
    func nonEditableTextKeepsTheKeys() {
        let label = NSTextView()
        label.isEditable = false
        #expect(MacReplayKeyboard.isTextInputFocused(in: window(focusing: label)) == false)
    }

    @Test("the replay stage holding focus must not disarm its own transport")
    func focusedWebViewKeepsTheKeys() {
        // `WKWebView` conforms to `NSTextInputClient`, which is why the guard
        // asks about `NSText` instead: a protocol test would switch the
        // transport off exactly when the player has focus.
        let webView = WKWebView()
        #expect(webView is NSTextInputClient)
        #expect(MacReplayKeyboard.isTextInputFocused(in: window(focusing: webView)) == false)
    }
}
