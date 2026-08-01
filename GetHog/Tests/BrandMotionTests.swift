import SwiftUI
import Testing
@testable import GetHog

@Suite("Brand motion")
@MainActor
struct BrandMotionTests {
    @Test("Reduced motion always uses the settled illustration values")
    func reducedMotionSettlesImmediately() {
        let values = BrandMotionValues.illustration(reduceMotion: true, appeared: false)

        #expect(values.opacity == 1)
        #expect(values.y == 0)
        #expect(values.scale == 1)
    }

    @Test("Standard motion moves from a subtle entrance to settled values")
    func standardMotionHasBoundedEntrance() {
        let initial = BrandMotionValues.illustration(reduceMotion: false, appeared: false)
        let final = BrandMotionValues.illustration(reduceMotion: false, appeared: true)

        #expect(initial.opacity == 0)
        #expect(initial.y == 8)
        #expect(initial.scale == 0.98)
        #expect(final.opacity == 1)
        #expect(final.y == 0)
        #expect(final.scale == 1)
    }

    @Test("Reduced motion never exposes a confirmation transition")
    func reducedConfirmationSettles() {
        #expect(BrandMotionValues.confirmation(reduceMotion: true, active: true) == .settled)
        #expect(BrandMotionValues.confirmation(reduceMotion: true, active: false) == .settled)
    }

    @Test("Standard confirmation changes only opacity, offset, and scale")
    func standardConfirmationIsBounded() {
        let active = BrandMotionValues.confirmation(reduceMotion: false, active: true)
        #expect(active.opacity == 1)
        #expect(active.y == -2)
        #expect(active.scale == 1.04)
        #expect(BrandMotionValues.confirmation(reduceMotion: false, active: false) == .settled)
    }

    @Test("Confirmation triggers activate only when Reduce Motion is disabled")
    func triggerRespectsReduceMotion() {
        var lifecycle = SignalConfirmationLifecycle()

        #expect(lifecycle.activate(reduceMotion: true) == nil)
        #expect(!lifecycle.active)
        #expect(lifecycle.activate(reduceMotion: false) == 2)
        #expect(lifecycle.active)
    }

    @Test("A replacement trigger invalidates the prior timeout")
    func replacementTriggerInvalidatesPriorTimeout() {
        var lifecycle = SignalConfirmationLifecycle()
        let firstGeneration = lifecycle.activate(reduceMotion: false)
        let secondGeneration = lifecycle.activate(reduceMotion: false)

        #expect(firstGeneration == 1)
        #expect(secondGeneration == 2)
        lifecycle.settle(generation: firstGeneration ?? 0)
        #expect(lifecycle.active)
    }

    @Test("Only the current confirmation timeout can settle the overlay")
    func currentTimeoutSettlesOverlay() {
        var lifecycle = SignalConfirmationLifecycle()
        _ = lifecycle.activate(reduceMotion: false)
        let currentGeneration = lifecycle.activate(reduceMotion: false)

        lifecycle.settle(generation: currentGeneration ?? 0)
        #expect(!lifecycle.active)
    }

    @Test("Enabling Reduce Motion immediately invalidates and settles confirmation")
    func reduceMotionInvalidatesActiveConfirmation() {
        var lifecycle = SignalConfirmationLifecycle()
        let activeGeneration = lifecycle.activate(reduceMotion: false)

        lifecycle.settleImmediately()
        #expect(!lifecycle.active)
        lifecycle.settle(generation: activeGeneration ?? 0)
        #expect(!lifecycle.active)
    }

    @Test("Confirmation modifier renders around real summary content")
    func confirmationModifierRendersContent() {
        let renderer = ImageRenderer(
            content: Text("Summary").signalConfirmation(trigger: 0)
        )

        #expect(renderer.uiImage != nil)
    }
}
