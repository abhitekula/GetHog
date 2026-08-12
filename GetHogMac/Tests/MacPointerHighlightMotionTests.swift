import Testing

@testable import GetHog

@MainActor
@Suite("Mac pointer highlight motion")
struct MacPointerHighlightMotionTests {
    @Test("Reduce Motion removes the pointer highlight transition")
    func reduceMotionDisablesTransition() {
        #expect(PointerHighlightMotion.transitionDuration(reduceMotion: true) == nil)
    }

    @Test("Standard motion retains the brief pointer highlight transition")
    func standardMotionKeepsBriefTransition() {
        #expect(PointerHighlightMotion.transitionDuration(reduceMotion: false) == 0.12)
    }
}
