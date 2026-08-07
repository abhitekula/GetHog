import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch flag toggle flow")
struct WatchFlagToggleFlowTests {

    private let flag = SharedSnapshot.Flag(
        id: 1, key: "example-a", active: true, quickToggleAllowed: false
    )

    private var pending: FlagToggleFlow.Pending {
        FlagToggleFlow.Pending(flagID: 1, key: "example-a", desired: false)
    }

    @Test("proposing a toggle asks for the opposite of what the flag is")
    func proposeSetsConfirming() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        #expect(flow.step == .confirming(pending))
        #expect(flow.pending == pending)
    }

    @Test("a second proposal while one is in flight is ignored")
    func proposeWhileBusyIsIgnored() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.propose(flag: SharedSnapshot.Flag(
            id: 2, key: "example-b", active: false, quickToggleAllowed: false
        ))
        #expect(flow.step == .confirming(pending))
    }

    @Test("cancelling returns to idle")
    func cancelReturnsToIdle() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.cancel()
        #expect(flow.step == .idle)
    }

    @Test("confirming moves to the device-owner gate, not to the write")
    func confirmMovesToAuthenticating() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        let proceeded = flow.confirm(pending)
        #expect(proceeded)
        #expect(flow.step == .authenticating(pending))
    }

    @Test("a gate that could not confirm the wearer fails closed")
    func failedAuthenticationFailsClosed() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        _ = flow.confirm(pending)
        flow.authenticated(false)
        #expect(flow.step == .failed("Couldn't confirm it's you. The flag was not changed."))
    }

    @Test("only a satisfied gate reaches the write")
    func successfulAuthenticationReachesWriting() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        _ = flow.confirm(pending)
        flow.authenticated(true)
        #expect(flow.step == .writing(pending))
    }

    @Test("a write that succeeded returns to idle and one that failed says why")
    func finishedRoutesOnTheError() {
        var success = FlagToggleFlow()
        success.propose(flag: flag)
        _ = success.confirm(pending)
        success.authenticated(true)
        success.finished(error: nil)
        #expect(success.step == .idle)

        var failure = FlagToggleFlow()
        failure.propose(flag: flag)
        _ = failure.confirm(pending)
        failure.authenticated(true)
        failure.finished(error: "PostHog refused the change.")
        #expect(failure.step == .failed("PostHog refused the change."))
    }

    @Test("a ladder already under way refuses a second one")
    func aSecondLadderIsRefused() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        let first = flow.confirm(pending)
        // The double tap: two Tasks, one proposal.
        let second = flow.confirm(pending)
        #expect(first)
        #expect(second == false)
        #expect(flow.step == .authenticating(pending))
    }

    @Test("no rung can be reached from idle without a captured proposal")
    func rungsCannotBeSkipped() {
        var flow = FlagToggleFlow()
        flow.authenticated(true)
        #expect(flow.step == .idle)
        flow.finished(error: nil)
        #expect(flow.step == .idle)
    }

    @Test("the dialog's own dismissal clears the step and the proposal with it")
    func dismissalClearsEverythingTheStepCarried() {
        var flow = FlagToggleFlow()
        flow.propose(flag: flag)
        flow.dismissed()

        // This is the state the confirm button's Task actually starts in, and
        // it is why reading the step there could never work: by then there is
        // no flag id, no key and no desired value left to write.
        #expect(flow.step == .idle)
        #expect(flow.pending == nil)
    }
}

@Suite("Watch flag toggle controller")
@MainActor
struct WatchFlagToggleControllerTests {

    private func model(store: SharedSnapshotStore) -> WatchModel {
        WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                extra: [
                    .init(
                        pathContains: "/feature_flags/2/",
                        body: #"{"id":2,"key":"example-b","active":true}"#
                    ),
                ]
            )),
            store: store
        )
    }

    /// The regression this whole shape exists for.
    ///
    /// SwiftUI sets a `confirmationDialog`'s `isPresented` binding to false
    /// synchronously with the tap, so the binding's setter — and therefore the
    /// dismissal — runs *before* the button's `Task` body. This test performs
    /// exactly that order. Against a step-reading implementation the flow is
    /// `.idle` with no `pending` by the time `run` starts, every guard
    /// no-ops, and PostHog is never called; the sibling assertions in
    /// `dismissalClearsEverythingTheStepCarried` pin that there is nothing
    /// left for such an implementation to read.
    @Test("a dismissal that races the tap does not swallow the write")
    func dismissalBeforeTheTaskStillWrites() async throws {
        let store = WatchFixtures.tempStore()
        let model = model(store: store)
        await model.refresh()
        #expect(model.snapshot?.flag(id: 2)?.active == false)

        let controller = FlagToggleController()
        controller.propose(flag: try #require(model.snapshot?.flag(id: 2)))
        // Captured while the dialog is built, which is the only moment the
        // proposal exists.
        let pending = try #require(controller.flow.pending)

        // …then the dismissal lands first, exactly as the runtime orders it.
        controller.dismissed()
        #expect(controller.flow.step == .idle)
        #expect(controller.flow.pending == nil)

        // …and only then does the tap's Task body run.
        await controller.run(pending, on: model)

        #expect(model.snapshot?.flag(id: 2)?.active == true)
        #expect(store.loadOrNil()?.flag(id: 2)?.active == true)
        #expect(controller.flow.step == .idle)
    }

    @Test("a refused device-owner gate reaches neither PostHog nor the snapshot")
    func refusedGateWritesNothing() async throws {
        let store = WatchFixtures.tempStore()
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchFixtures.model(
            transport: transport, store: store, authenticate: { _ in false }
        )
        await model.refresh()
        let before = await transport.requests.count

        let controller = FlagToggleController()
        controller.propose(flag: try #require(model.snapshot?.flag(id: 2)))
        let pending = try #require(controller.flow.pending)
        controller.dismissed()
        await controller.run(pending, on: model)

        #expect(await transport.requests.count == before)
        #expect(model.snapshot?.flag(id: 2)?.active == false)
        #expect(controller.flow.step == .failed("Couldn't confirm it's you. The flag was not changed."))
    }

    @Test("a write PostHog refused is reported rather than assumed")
    func refusedWriteIsReported() async throws {
        let store = WatchFixtures.tempStore()
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                extra: [
                    .init(
                        pathContains: "/feature_flags/2/",
                        body: #"{"detail":"Synthetic refusal."}"#,
                        status: 403
                    ),
                ]
            )),
            store: store
        )
        await model.refresh()

        let controller = FlagToggleController()
        controller.propose(flag: try #require(model.snapshot?.flag(id: 2)))
        let pending = try #require(controller.flow.pending)
        await controller.run(pending, on: model)

        #expect(model.snapshot?.flag(id: 2)?.active == false)
        if case .failed = controller.flow.step {} else {
            Issue.record("a refused write must leave the flow on a stated failure")
        }
    }
}
