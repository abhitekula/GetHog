import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch flag toggle flow")
struct WatchFlagToggleFlowTests {

    private let flag = SharedSnapshot.Flag(
        id: 1, key: "example-a", active: true, quickToggleAllowed: false
    )

    @Test("proposing a toggle asks for the opposite of what the flag is")
    func proposeSetsConfirming() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        #expect(flow.step == .confirming(flagID: 1, key: "example-a", desired: false))
    }

    @Test("a second proposal while one is in flight is ignored")
    func proposeWhileBusyIsIgnored() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.propose(flag: SharedSnapshot.Flag(
            id: 2, key: "example-b", active: false, quickToggleAllowed: false
        ))
        #expect(flow.step == .confirming(flagID: 1, key: "example-a", desired: false))
    }

    @Test("cancelling returns to idle")
    func cancelReturnsToIdle() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.cancel()
        #expect(flow.step == .idle)
    }

    @Test("confirming the dialog moves to the device-owner gate, not to the write")
    func confirmMovesToAuthenticating() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.confirm()
        #expect(flow.step == .authenticating(flagID: 1, key: "example-a", desired: false))
    }

    @Test("a gate that could not confirm the wearer fails closed")
    func failedAuthenticationFailsClosed() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.confirm()
        flow.authenticated(false)
        #expect(flow.step == .failed("Couldn't confirm it's you. The flag was not changed."))
    }

    @Test("only a satisfied gate reaches the write")
    func successfulAuthenticationReachesWriting() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.confirm()
        flow.authenticated(true)
        #expect(flow.step == .writing(flagID: 1, key: "example-a", desired: false))
    }

    @Test("a write that succeeded returns to idle and one that failed says why")
    func finishedRoutesOnTheError() {
        var success = FlagToggleFlow()
        success.propose(flag: flag)
        success.confirm()
        success.authenticated(true)
        success.finished(error: nil)
        #expect(success.step == .idle)

        var failure = FlagToggleFlow()
        failure.propose(flag: flag)
        failure.confirm()
        failure.authenticated(true)
        failure.finished(error: "PostHog refused the change.")
        #expect(failure.step == .failed("PostHog refused the change."))
    }

    @Test("no rung can be skipped from idle")
    func rungsCannotBeSkipped() {
        var flow = FlagToggleFlow()
        flow.confirm()
        #expect(flow.step == .idle)
        flow.authenticated(true)
        #expect(flow.step == .idle)
        flow.finished(error: nil)
        #expect(flow.step == .idle)
    }
}
