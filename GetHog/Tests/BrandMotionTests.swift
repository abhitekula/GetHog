import Testing
@testable import GetHog

@Suite("Brand motion")
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
}
