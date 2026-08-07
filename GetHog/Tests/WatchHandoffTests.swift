import Foundation
import GetHogKit
@testable import GetHog
import Testing

@MainActor
@Suite("Watch key hand-off, phone side")
struct WatchHandoffTests {

    @Test("the payload carries the key, region, and selected project")
    func payloadCarriesTheKeyRegionAndSelection() throws {
        let (controller, sender, _) = makeController()

        controller.send(project: try project(), headlineMetricID: "720101", watches: [])

        let transfer = try decodedTransfer(from: sender)
        #expect(transfer.key == "test-key-0001")
        #expect(transfer.region == .usCloud)
        #expect(transfer.projectID == 1001)
        #expect(transfer.projectName == "Synthetic Analytics")
        #expect(transfer.headlineMetricID == "720101")
        #expect(transfer.version == WatchKeyTransfer.currentVersion)
    }

    @Test("the payload carries every threshold through its wire form")
    func payloadCarriesEveryThreshold() throws {
        let (controller, sender, _) = makeController()
        let watches = [
            MetricWatch(id: "watch-1", metricID: "720101", title: "Signups", condition: .above(40)),
            MetricWatch(id: "watch-2", metricID: "720102", title: "Errors", condition: .below(2)),
            MetricWatch(id: "watch-3", metricID: "720103", title: "Revenue", condition: .changesByPercent(10)),
        ]

        controller.send(project: try project(), headlineMetricID: nil, watches: watches)

        let transfer = try decodedTransfer(from: sender)
        #expect(transfer.watches.count == 3)
        #expect(transfer.watches[1].condition == .below(2))
    }

    @Test("the wire never claims threshold degradation")
    func theWireNeverClaimsDegradation() throws {
        let (controller, sender, _) = makeController()

        controller.send(project: try project(), headlineMetricID: nil, watches: [])

        #expect(try decodedTransfer(from: sender).watchesDegraded == false)
    }

    @Test("the queued dictionary is shaped the way the watch reads")
    func theQueuedDictionaryIsShapedTheWayTheWatchReads() throws {
        let (controller, sender, _) = makeController()

        controller.send(project: try project(), headlineMetricID: nil, watches: [])

        let payload = try queuedPayload(from: sender)
        // Deliberate transcription of GetHogWatch/Sources/WatchSessionListener.swift:76-79.
        // GetHogTests cannot link the watch target, so this pins the phone half to its shared key.
        let data = try #require(payload.userInfo[WatchKeyTransfer.userInfoKey] as? Data)
        let transfer = try WatchKeyTransfer.decode(data)
        #expect(transfer.key == "test-key-0001")
    }

    @Test("an unsupported session hides the row")
    func anUnsupportedSessionHidesTheRow() {
        let sender = FakeWatchSender(
            pairing: WatchPairing(isSupported: false, isPaired: true, isAppInstalled: true)
        )
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.start()

        #expect(!controller.pairing.canReach)
        #expect(!controller.canSend)
    }

    @Test("an unpaired watch hides the row")
    func anUnpairedWatchHidesTheRow() {
        let sender = FakeWatchSender(
            pairing: WatchPairing(isSupported: true, isPaired: false, isAppInstalled: true)
        )
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.start()

        #expect(!controller.pairing.canReach)
        #expect(!controller.canSend)
    }

    @Test("a watch without GetHog hides the row")
    func aWatchWithoutTheAppHidesTheRow() {
        let sender = FakeWatchSender(
            pairing: WatchPairing(isSupported: true, isPaired: true, isAppInstalled: false)
        )
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.start()

        #expect(!controller.pairing.canReach)
        #expect(!controller.canSend)
    }

    @Test("a paired watch with GetHog shows the row")
    func aPairedWatchWithTheAppShowsTheRow() {
        let (controller, _, _) = makeController()

        controller.start()

        #expect(controller.pairing.canReach)
        #expect(controller.canSend)
    }

    @Test("sending queues exactly one transfer")
    func sendingQueuesExactlyOneTransfer() throws {
        let (controller, sender, _) = makeController()
        controller.start()
        sender.calls.removeAll()

        controller.send(project: try project(), headlineMetricID: nil, watches: [])

        #expect(sender.calls.count == 2)
        #expect(sender.calls[0] == .cancelled)
        #expect(sender.calls[1].isQueued)
        #expect(controller.status == .queued)
        #expect(!controller.canSend)
    }

    @Test("a resend cancels the transfer still waiting")
    func aResendCancelsTheOneStillWaiting() throws {
        let (controller, sender, credentials) = makeController()
        let project = try project()

        controller.send(project: project, headlineMetricID: nil, watches: [])
        sender.emit(.transferFinished(failure: nil))
        try credentials.save(StoredCredential(key: "test-key-0002", region: .euCloud))
        controller.send(project: project, headlineMetricID: nil, watches: [])

        #expect(sender.calls.count == 4)
        #expect(sender.calls[0] == .cancelled)
        #expect(sender.calls[1].isQueued)
        #expect(sender.calls[2] == .cancelled)
        #expect(sender.calls[3].isQueued)
        #expect(try decodedTransfer(from: sender, queuedCall: 3).key == "test-key-0002")
    }

    @Test("no stored key refuses to send and says why")
    func noStoredKeyRefusesToSendAndSaysSo() throws {
        let sender = FakeWatchSender()
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.send(project: try project(), headlineMetricID: nil, watches: [])

        #expect(sender.calls.isEmpty)
        guard case let .failed(reason) = controller.status else {
            Issue.record("Expected a missing credential to fail")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("no selected project refuses to send and says why")
    func noSelectedProjectRefusesToSendAndSaysSo() {
        let (controller, sender, _) = makeController()

        controller.send(project: nil, headlineMetricID: nil, watches: [])

        #expect(sender.calls.isEmpty)
        guard case let .failed(reason) = controller.status else {
            Issue.record("Expected a missing project to fail")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("a finished transfer reads as delivered")
    func aFinishedTransferReadsAsDelivered() {
        let (controller, sender, _) = makeController()
        controller.start()

        sender.emit(.transferFinished(failure: nil))

        guard case .delivered = controller.status else {
            Issue.record("Expected a finished transfer to be delivered")
            return
        }
        #expect(controller.canSend)
    }

    @Test("a failed transfer surfaces its reason and allows a retry")
    func aFailedTransferSurfacesItsReasonAndAllowsARetry() {
        let (controller, sender, _) = makeController()
        controller.start()

        sender.emit(.transferFinished(failure: "The watch could not receive it."))

        guard case let .failed(reason) = controller.status else {
            Issue.record("Expected a failed transfer to surface its reason")
            return
        }
        #expect(reason == "The watch could not receive it.")
        #expect(controller.canSend)
    }

    @Test("a transfer left over from a previous launch reads as queued")
    func aTransferLeftOverFromAPreviousLaunchReadsAsQueued() {
        let sender = FakeWatchSender(queuedCount: 1)
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.start()

        #expect(controller.status == .queued)
    }

    @Test("no status the user can see carries the key")
    func noStatusTheUserCanSeeCarriesTheKey() throws {
        let (controller, sender, _) = makeController()
        var statuses: [WatchHandoffController.Status] = [controller.status]
        controller.send(project: try project(), headlineMetricID: nil, watches: [])
        statuses.append(controller.status)
        sender.emit(.transferFinished(failure: nil))
        statuses.append(controller.status)
        sender.emit(.transferFinished(failure: "Unable to transfer."))
        statuses.append(controller.status)

        #expect(statuses.allSatisfy { !String(describing: $0).contains("test-key-0001") })
    }

    private func makeController() -> (WatchHandoffController, FakeWatchSender, InMemoryTokenStore) {
        let sender = FakeWatchSender()
        let credentials = InMemoryTokenStore(
            credential: StoredCredential(key: "test-key-0001", region: .usCloud)
        )
        return (WatchHandoffController(sender: sender, credentials: credentials), sender, credentials)
    }

    private func project() throws -> Project {
        try JSONDecoder().decode(
            Project.self,
            from: Data(#"{"id":1001,"name":"Synthetic Analytics"}"#.utf8)
        )
    }

    private func queuedPayload(
        from sender: FakeWatchSender,
        queuedCall: Int? = nil
    ) throws -> WatchTransferPayload {
        let calls = sender.calls
        let call = queuedCall.flatMap { calls.indices.contains($0) ? calls[$0] : nil }
            ?? calls.last
        guard case let .queued(payload)? = call else {
            throw HandoffTestError.missingQueuedPayload
        }
        return payload
    }

    private func decodedTransfer(
        from sender: FakeWatchSender,
        queuedCall: Int? = nil
    ) throws -> WatchKeyTransfer {
        try WatchKeyTransfer.decode(queuedPayload(from: sender, queuedCall: queuedCall).data)
    }
}

private enum HandoffTestError: Error {
    case missingQueuedPayload
}

private final class FakeWatchSender: WatchSending, @unchecked Sendable {
    enum Call: Equatable {
        case activated
        case cancelled
        case queued(WatchTransferPayload)

        var isQueued: Bool {
            if case .queued = self { return true }
            return false
        }
    }

    var calls: [Call] = []
    var pairing: WatchPairing
    var queuedCount: Int
    private var sink: (@MainActor @Sendable (WatchSendEvent) -> Void)?

    init(
        pairing: WatchPairing = WatchPairing(isSupported: true, isPaired: true, isAppInstalled: true),
        queuedCount: Int = 0
    ) {
        self.pairing = pairing
        self.queuedCount = queuedCount
    }

    func activate() {
        calls.append(.activated)
    }

    func cancelQueued() {
        calls.append(.cancelled)
        queuedCount = 0
    }

    func queue(_ payload: WatchTransferPayload) {
        calls.append(.queued(payload))
        queuedCount = 1
    }

    func observe(_ sink: (@MainActor @Sendable (WatchSendEvent) -> Void)?) {
        self.sink = sink
    }

    @MainActor
    func emit(_ event: WatchSendEvent) {
        sink?(event)
    }
}
