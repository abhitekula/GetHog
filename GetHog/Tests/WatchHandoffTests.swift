import Foundation
import GetHogKit
@testable import GetHog
import Testing

@MainActor
@Suite("Watch key hand-off, phone side")
struct WatchHandoffTests {

    @Test("the payload carries the key, region, organization, and selected project")
    func payloadCarriesTheKeyRegionAndSelection() throws {
        let (controller, sender, _) = makeController()

        controller.send(
            organization: organization(),
            project: try project(),
            headlineMetricID: "720101"
        )

        let transfer = try decodedTransfer(from: sender)
        #expect(transfer.key == "test-key-0001")
        #expect(transfer.region == .usCloud)
        #expect(transfer.organizationID == "org-synthetic-1001")
        #expect(transfer.organizationName == "Synthetic Labs")
        #expect(transfer.projectID == 1001)
        #expect(transfer.projectName == "Synthetic Analytics")
        #expect(transfer.headlineMetricID == "720101")
        #expect(transfer.version == WatchKeyTransfer.currentVersion)
    }

    @Test("the queued dictionary is shaped the way the watch reads")
    func theQueuedDictionaryIsShapedTheWayTheWatchReads() throws {
        let (controller, sender, _) = makeController()

        controller.send(
            organization: organization(), project: try project(),
            headlineMetricID: nil
        )

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

        controller.send(
            organization: organization(), project: try project(),
            headlineMetricID: nil
        )

        #expect(sender.calls.count == 2)
        #expect(sender.calls[0] == .cancelled)
        #expect(sender.calls[1].isQueued)
        #expect(controller.status == .queued)
        #expect(controller.canSend)
    }

    @Test("a resend cancels the transfer still waiting")
    func aResendCancelsTheOneStillWaiting() throws {
        let (controller, sender, credentials) = makeController()
        let project = try project()
        controller.start()
        sender.calls.removeAll()

        controller.send(
            organization: organization(), project: project,
            headlineMetricID: nil
        )
        #expect(controller.status == .queued)
        #expect(controller.canSend)
        try credentials.save(StoredCredential(key: "test-key-0002", region: .euCloud))
        controller.send(
            organization: organization(), project: project,
            headlineMetricID: nil
        )

        #expect(sender.calls.count == 4)
        #expect(sender.calls[0] == .cancelled)
        #expect(sender.calls[1].isQueued)
        #expect(sender.calls[2] == .cancelled)
        #expect(sender.calls[3].isQueued)
        #expect(try decodedTransfer(from: sender, queuedCall: 3).key == "test-key-0002")
    }

    @Test("a canceled transfer's late callback cannot overwrite its queued replacement")
    func staleCompletionDoesNotOverwriteReplacement() throws {
        let (controller, sender, credentials) = makeController()
        let project = try project()
        controller.start()

        controller.send(
            organization: organization(), project: project,
            headlineMetricID: nil
        )
        let canceledID = try #require(sender.latestQueuedID)

        try credentials.save(StoredCredential(key: "test-key-0002", region: .euCloud))
        controller.send(
            organization: organization(), project: project,
            headlineMetricID: nil
        )
        let replacementID = try #require(sender.latestQueuedID)
        #expect(replacementID != canceledID)

        sender.finish(canceledID, failure: nil)

        #expect(controller.status == .queued)

        sender.finish(replacementID, failure: nil)

        guard case .delivered = controller.status else {
            Issue.record("Only the replacement transfer may claim delivery")
            return
        }
    }

    @Test("no stored key refuses to send and says why")
    func noStoredKeyRefusesToSendAndSaysSo() throws {
        let sender = FakeWatchSender()
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.send(
            organization: organization(), project: try project(),
            headlineMetricID: nil
        )

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

        controller.send(
            organization: organization(), project: nil,
            headlineMetricID: nil
        )

        #expect(sender.calls.isEmpty)
        guard case let .failed(reason) = controller.status else {
            Issue.record("Expected a missing project to fail")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("no selected organization refuses to send and says why")
    func noSelectedOrganizationRefusesToSendAndSaysSo() throws {
        let (controller, sender, _) = makeController()

        controller.send(
            organization: nil, project: try project(),
            headlineMetricID: nil
        )

        #expect(sender.calls.isEmpty)
        guard case let .failed(reason) = controller.status else {
            Issue.record("Expected a missing organization to fail")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("a finished transfer reads as delivered")
    func aFinishedTransferReadsAsDelivered() throws {
        let (controller, sender, _) = makeController()
        controller.start()
        controller.send(
            organization: organization(), project: try project(),
            headlineMetricID: nil
        )

        sender.finishLatest(failure: nil)

        guard case .delivered = controller.status else {
            Issue.record("Expected a finished transfer to be delivered")
            return
        }
        #expect(controller.canSend)
    }

    @Test("a failed transfer surfaces its reason and allows a retry")
    func aFailedTransferSurfacesItsReasonAndAllowsARetry() throws {
        let (controller, sender, _) = makeController()
        controller.start()
        controller.send(
            organization: organization(), project: try project(),
            headlineMetricID: nil
        )

        sender.finishLatest(failure: "The watch could not receive it.")

        guard case let .failed(reason) = controller.status else {
            Issue.record("Expected a failed transfer to surface its reason")
            return
        }
        #expect(reason == "The watch could not receive it.")
        #expect(controller.canSend)
    }

    @Test("one transfer left over from a previous launch resolves when it finishes")
    func oneStartupTransferResolvesOnCompletion() {
        let id = WatchTransferID()
        let sender = FakeWatchSender(queuedTransferIDs: [id])
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.start()

        #expect(controller.status == .queued)
        #expect(controller.canSend)

        sender.finish(id, failure: nil)

        guard case .delivered = controller.status else {
            Issue.record("The last startup transfer should resolve queued state")
            return
        }
    }

    @Test("multiple startup transfers stay queued and preserve a fixed failure until all finish")
    func multipleStartupTransfersDrainAsASet() {
        let failedID = WatchTransferID()
        let deliveredID = WatchTransferID()
        let sender = FakeWatchSender(queuedTransferIDs: [deliveredID, failedID])
        let controller = WatchHandoffController(sender: sender, credentials: InMemoryTokenStore())

        controller.start()

        sender.finish(failedID, failure: "The transfer could not be delivered.")
        #expect(controller.status == .queued)

        sender.finish(deliveredID, failure: nil)

        #expect(controller.status == .failed("The transfer could not be delivered."))
    }

    @Test("no status the user can see carries the key")
    func noStatusTheUserCanSeeCarriesTheKey() throws {
        let (controller, sender, _) = makeController()
        var statuses: [WatchHandoffController.Status] = [controller.status]
        controller.send(
            organization: organization(), project: try project(),
            headlineMetricID: nil
        )
        let transferID = try #require(sender.latestQueuedID)
        statuses.append(controller.status)
        sender.finish(transferID, failure: nil)
        statuses.append(controller.status)
        sender.finish(transferID, failure: "Unable to transfer.")
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

    private func organization() -> OrganizationSummary {
        OrganizationSummary(id: "org-synthetic-1001", name: "Synthetic Labs")
    }

    @Test("transfer identity mapping releases completed and canceled objects")
    func transferIdentityMappingDoesNotGrowStaleEntries() {
        let identities = WatchTransferIdentityMap()
        let transfer = NSObject()

        let first = identities.id(for: transfer)
        #expect(identities.remove(transfer) == first)
        #expect(identities.remove(transfer) == nil)
        #expect(identities.id(for: transfer) != first)
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
    var queuedTransferIDs: Set<WatchTransferID>
    private(set) var latestQueuedID: WatchTransferID?
    private var sink: (@MainActor @Sendable (WatchSendEvent) -> Void)?

    init(
        pairing: WatchPairing = WatchPairing(isSupported: true, isPaired: true, isAppInstalled: true),
        queuedTransferIDs: Set<WatchTransferID> = []
    ) {
        self.pairing = pairing
        self.queuedTransferIDs = queuedTransferIDs
    }

    func activate() {
        calls.append(.activated)
    }

    func cancelQueued() {
        calls.append(.cancelled)
        queuedTransferIDs = []
        latestQueuedID = nil
    }

    func queue(_ payload: WatchTransferPayload) -> WatchTransferID? {
        let id = WatchTransferID()
        calls.append(.queued(payload))
        queuedTransferIDs = [id]
        latestQueuedID = id
        return id
    }

    func observe(_ sink: (@MainActor @Sendable (WatchSendEvent) -> Void)?) {
        self.sink = sink
    }

    @MainActor
    func emit(_ event: WatchSendEvent) {
        sink?(event)
    }

    @MainActor
    func finish(_ id: WatchTransferID, failure: String?) {
        queuedTransferIDs.remove(id)
        if latestQueuedID == id { latestQueuedID = nil }
        emit(.didFinish(id: id, failure: failure))
    }

    @MainActor
    func finishLatest(failure: String?) {
        guard let latestQueuedID else {
            Issue.record("Expected a queued transfer identity")
            return
        }
        finish(latestQueuedID, failure: failure)
    }
}
