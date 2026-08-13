import Testing

@testable import GetHog
@testable import GetHogUI

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

@Suite("Time-series scrub motion")
struct TimeSeriesScrubMotionTests {
    @Test("Reduce Motion removes the scrub readout scale transition")
    func reduceMotionDisablesScaleTransition() {
        #expect(!TimeSeriesScrubMotion.usesScaleTransition(reduceMotion: true))
    }

    @Test("Standard motion retains the scrub readout scale transition")
    func standardMotionKeepsScaleTransition() {
        #expect(TimeSeriesScrubMotion.usesScaleTransition(reduceMotion: false))
    }
}
