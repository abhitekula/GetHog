import Testing

@testable import GetHog

/// The rule that turns three monotonic counters into one thing to say.
///
/// The counters exist to drive haptics, where each is its own trigger and no
/// arbitration is needed. Reading them as a single outcome is new, and the
/// arbitration is the whole risk: a change carrying two edges must resolve to
/// the one a reader cannot afford to miss, and a change carrying none must
/// resolve to nothing rather than to a stale repeat.
@Suite("Flag write feedback")
struct FlagWriteFeedbackTests {

    private let start = FlagWriteCounts(success: 3, failure: 2, filed: 1)

    @Test("A success bump reads as success")
    func successBump() {
        var next = start
        next.success += 1
        #expect(FlagWriteSignal.signal(from: start, to: next) == .success)
    }

    @Test("A failure bump reads as failure")
    func failureBump() {
        var next = start
        next.failure += 1
        #expect(FlagWriteSignal.signal(from: start, to: next) == .failure)
    }

    @Test("A filed bump reads as filed, not as either of the other two")
    func filedBump() {
        var next = start
        next.filed += 1
        #expect(FlagWriteSignal.signal(from: start, to: next) == .filed)
    }

    @Test("Counters that did not move say nothing")
    func noBump() {
        #expect(FlagWriteSignal.signal(from: start, to: start) == nil)
    }

    /// The arbitration rule, stated as a test so it cannot drift: whatever else
    /// a change carries, "your flag is not live" wins.
    @Test("Failure outranks a success or a filing landing in the same change")
    func failureOutranks() {
        var withSuccess = start
        withSuccess.failure += 1
        withSuccess.success += 1
        #expect(FlagWriteSignal.signal(from: start, to: withSuccess) == .failure)

        var withFiled = start
        withFiled.failure += 1
        withFiled.filed += 1
        #expect(FlagWriteSignal.signal(from: start, to: withFiled) == .failure)
    }

    @Test("A filing outranks a success landing in the same change")
    func filedOutranksSuccess() {
        var next = start
        next.filed += 1
        next.success += 1
        #expect(FlagWriteSignal.signal(from: start, to: next) == .filed)
    }

    /// Every case has to be sayable — an outcome with no words is an outcome
    /// the Mac shows as an empty capsule.
    @Test("Every signal carries a title and a symbol")
    func everySignalIsSayable() {
        for signal in FlagWriteSignal.allCases {
            #expect(!signal.title.isEmpty)
            #expect(!signal.systemImage.isEmpty)
        }
    }
}
