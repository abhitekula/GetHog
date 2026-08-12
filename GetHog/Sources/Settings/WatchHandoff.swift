#if os(iOS)
import Foundation
import GetHogKit
import GetHogUI
import Observation
import SwiftUI
import WatchConnectivity

/// What the phone can currently say about the watch on the other end.
struct WatchPairing: Sendable, Equatable {
    var isSupported = false
    var isPaired = false
    var isAppInstalled = false

    /// All three, which is exactly the Settings row's visibility rule.
    var canReach: Bool { isSupported && isPaired && isAppInstalled }
}

/// One payload, and the key it must be filed under.
///
/// A dictionary is not `Sendable`; carrying its key with the bytes keeps the
/// phone and watch spelling testable without moving a bearer credential into UI
/// state.
struct WatchTransferPayload: Sendable, Equatable {
    let key: String
    let data: Data

    var userInfo: [String: Any] { [key: data] }
}

/// Opaque correlation only. The controller may retain this value safely: it
/// contains no payload bytes, credential, project, or other user data.
struct WatchTransferID: Sendable, Hashable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

/// Associates an in-process `WCSessionUserInfoTransfer` object with an opaque
/// ID without retaining the transfer object or its key-bearing `userInfo`.
///
/// `WCSessionUserInfoTransfer` exposes no stable identifier. `ObjectIdentifier`
/// is therefore used only as the dictionary key for that object's lifetime;
/// the value crossing into controller state is a random, data-free UUID.
final class WatchTransferIdentityMap: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [ObjectIdentifier: WatchTransferID] = [:]

    func id(for transfer: AnyObject) -> WatchTransferID {
        lock.withLock {
            let objectID = ObjectIdentifier(transfer)
            if let existing = ids[objectID] { return existing }
            let id = WatchTransferID()
            ids[objectID] = id
            return id
        }
    }

    @discardableResult
    func remove(_ transfer: AnyObject) -> WatchTransferID? {
        lock.withLock { ids.removeValue(forKey: ObjectIdentifier(transfer)) }
    }
}

enum WatchSendEvent: Sendable, Equatable {
    case pairingChanged(WatchPairing)
    /// `nil` means the WatchConnectivity daemon reported delivery.
    case didFinish(id: WatchTransferID, failure: String?)
}

/// The slice of `WCSession` this feature uses, and nothing else.
///
/// The system delegate chooses its callback queue, so isolation belongs to the
/// controller and events cross to it through `observe` explicitly.
protocol WatchSending: AnyObject, Sendable {
    var pairing: WatchPairing { get }
    /// Idempotent: assigns the delegate and activates on every appearance.
    func activate()
    /// Opaque IDs for every transfer in the daemon's persistent outbox,
    /// including a prior launch's. A set because WCSession promises no order.
    var queuedTransferIDs: Set<WatchTransferID> { get }
    /// Discards every waiting transfer before a replacement or sign-out.
    func cancelQueued()
    /// Queues the payload and returns only its opaque, key-free correlation ID.
    func queue(_ payload: WatchTransferPayload) -> WatchTransferID?
    /// Replaces the observer; `nil` unsubscribes.
    func observe(_ sink: (@MainActor @Sendable (WatchSendEvent) -> Void)?)
}

/// `WCSession` backed sender for the deliberate `transferUserInfo` choice.
///
/// `transferUserInfo` queues this dictionary in WatchConnectivity's on-disk
/// outbox until delivery, including across relaunch and reboot. That makes it
/// available while a watch is away, at the accepted cost of a raw key outside
/// the Keychain for a window this app cannot control; `sendMessage` avoids the
/// outbox but fails whenever the watch is unreachable. `@unchecked Sendable` is
/// safe here for the same reason as `WatchSessionListener`: callbacks own no
/// mutable state beyond the observer, which is protected by `NSLock`.
final class LiveWatchSender: NSObject, WCSessionDelegate, WatchSending, @unchecked Sendable {
    static let shared = LiveWatchSender()

    private let session = WCSession.default
    private let observerLock = NSLock()
    private let transferStateLock = NSLock()
    private let transferIdentities = WatchTransferIdentityMap()
    private var sink: (@MainActor @Sendable (WatchSendEvent) -> Void)?

    var pairing: WatchPairing {
        guard WCSession.isSupported() else { return WatchPairing() }
        // Pairing facts settle through activation. Advertising them before then
        // would let the button queue before WatchConnectivity accepts transfers.
        guard session.activationState == .activated else {
            return WatchPairing(isSupported: true)
        }
        return WatchPairing(
            isSupported: true,
            isPaired: session.isPaired,
            isAppInstalled: session.isWatchAppInstalled
        )
    }

    var queuedTransferIDs: Set<WatchTransferID> {
        guard WCSession.isSupported() else { return [] }
        // Read the framework's unordered snapshot and map it under the same
        // lock completion uses. Either this snapshot wins and completion emits
        // one of these IDs, or completion wins and the finished transfer is no
        // longer selected; there is no first/last ordering assumption.
        return transferStateLock.withLock {
            Set(session.outstandingUserInfoTransfers.map { transferIdentities.id(for: $0) })
        }
    }

    func activate() {
        guard WCSession.isSupported() else {
            emit(.pairingChanged(WatchPairing()))
            return
        }
        session.delegate = self
        session.activate()
    }

    func cancelQueued() {
        guard WCSession.isSupported() else { return }
        let transfers = transferStateLock.withLock {
            let transfers = session.outstandingUserInfoTransfers
            transfers.forEach { transfer in
                transferIdentities.remove(transfer)
            }
            return transfers
        }
        transfers.forEach { transfer in
            // A cancellation may still produce a late callback. Removing now
            // prevents unbounded growth; that callback receives a fresh,
            // necessarily stale ID and cannot match the replacement.
            transfer.cancel()
        }
    }

    func queue(_ payload: WatchTransferPayload) -> WatchTransferID? {
        guard WCSession.isSupported(), session.activationState == .activated else { return nil }
        return transferStateLock.withLock {
            let transfer = session.transferUserInfo(payload.userInfo)
            return transferIdentities.id(for: transfer)
        }
    }

    func observe(_ sink: (@MainActor @Sendable (WatchSendEvent) -> Void)?) {
        observerLock.withLock { self.sink = sink }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        emit(.pairingChanged(pairing))
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        emit(.pairingChanged(pairing))
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        // The system's error can include transport details. The status surface
        // is deliberately a fixed sentence, never an error description.
        let id = transferStateLock.withLock {
            transferIdentities.remove(userInfoTransfer) ?? WatchTransferID()
        }
        emit(.didFinish(
            id: id,
            failure: error == nil ? nil : "The transfer could not be delivered."
        ))
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    private func emit(_ event: WatchSendEvent) {
        let observer = observerLock.withLock { sink }
        guard let observer else { return }
        Task { @MainActor in observer(event) }
    }
}

/// Keeps the bearer credential confined to this controller's send operation.
///
/// The transfer and encoded bytes are locals only: no controller property,
/// status, or view state can retain or render the key.
@MainActor
@Observable
final class WatchHandoffController {
    enum Status: Equatable {
        case idle
        case queued
        case delivered(Date)
        case failed(String)
    }

    private(set) var pairing = WatchPairing()
    private(set) var status: Status = .idle

    private let sender: any WatchSending
    private let credentials: any CredentialStoring
    /// Opaque and key-free. This is a set because WCSession documents no order
    /// for `outstandingUserInfoTransfers`; membership, never first/last, decides
    /// whether a completion belongs to the queue Settings is describing.
    private var activeTransferIDs: Set<WatchTransferID> = []
    /// LiveWatchSender supplies only one fixed failure sentence. Keep the first
    /// while other outstanding transfers drain, without carrying system error
    /// details into observable state.
    private var pendingFailure: String?

    init(
        sender: any WatchSending = LiveWatchSender.shared,
        credentials: any CredentialStoring = KeychainTokenStore()
    ) {
        self.sender = sender
        self.credentials = credentials
    }

    /// A queued transfer is replaceable by design: pressing again cancels the
    /// old outbox item before queueing the newly selected scope and key.
    var canSend: Bool { pairing.canReach }

    func start() {
        sender.observe { [weak self] event in
            self?.receive(event)
        }
        sender.activate()
        pairing = sender.pairing
        activeTransferIDs = sender.queuedTransferIDs
        pendingFailure = nil
        status = activeTransferIDs.isEmpty ? .idle : .queued
    }

    func send(
        organization: OrganizationSummary?,
        project: Project?,
        headlineMetricID: String?,
        watches: [MetricWatch]
    ) {
        guard let credential = try? credentials.load() else {
            status = .failed("There's no API key on this iPhone to send.")
            return
        }
        guard let organization else {
            status = .failed("Choose an organization above before sending it to your watch.")
            return
        }
        guard let project else {
            status = .failed("Choose a project above before sending it to your watch.")
            return
        }
        let transfer = WatchKeyTransfer(
            key: credential.key,
            region: credential.region,
            organizationID: organization.id,
            organizationName: organization.name,
            projectID: project.id,
            projectName: project.name,
            headlineMetricID: headlineMetricID,
            watches: watches
        )
        guard let data = try? transfer.encoded() else {
            status = .failed("Couldn't package the key for transfer.")
            return
        }
        // Rotation: cancelling before queueing leaves no superseded bearer key
        // at rest in WatchConnectivity's outbox.
        sender.cancelQueued()
        activeTransferIDs = []
        pendingFailure = nil
        guard let id = sender.queue(
            WatchTransferPayload(key: WatchKeyTransfer.userInfoKey, data: data)
        ) else {
            status = .failed("The watch session isn't ready to queue a transfer.")
            return
        }
        activeTransferIDs = [id]
        status = .queued
    }

    func cancelQueued() {
        sender.cancelQueued()
        activeTransferIDs = []
        pendingFailure = nil
        status = .idle
    }

    private func receive(_ event: WatchSendEvent) {
        switch event {
        case .pairingChanged(let pairing):
            self.pairing = pairing
        case .didFinish(let id, let failure):
            guard activeTransferIDs.remove(id) != nil else { return }
            if let failure, pendingFailure == nil { pendingFailure = failure }
            guard activeTransferIDs.isEmpty else {
                status = .queued
                return
            }
            let finalFailure = pendingFailure
            pendingFailure = nil
            status = finalFailure.map(Status.failed) ?? .delivered(Date())
        }
    }
}

struct SettingsWatchSection: View {
    @Environment(AppModel.self) private var model
    @State private var handoff = WatchHandoffController()
    @AppStorage("watchHandoffHeadlineMetricID") private var headlineMetricID = ""

    var body: some View {
        Group {
            if handoff.pairing.canReach {
                Section {
                    Picker("Headline metric", selection: $headlineMetricID) {
                        Text("First tile on the pinned dashboard").tag("")
                        ForEach(SharedSnapshotStore.shared.loadOrNil()?.metrics ?? []) { metric in
                            Text(metric.title).tag(metric.id)
                        }
                    }

                    Button {
                        handoff.send(
                            organization: model.selectedOrganization,
                            project: model.selectedProject,
                            headlineMetricID: headlineMetricID.isEmpty ? nil : headlineMetricID,
                            watches: SharedSnapshotStore.shared.metricWatches()
                        )
                    } label: {
                        Label(
                            "Send API key to Apple Watch",
                            systemImage: "applewatch.radiowaves.left.and.right"
                        )
                    }
                    .disabled(!handoff.canSend)

                    status
                } header: {
                    SectionLabel(text: "Apple Watch", systemImage: "applewatch")
                } footer: {
                    Text(
                        "Sends this iPhone's key, the current organization and project, and your thresholds to GetHog on your Apple Watch, where the key is stored in that watch's Keychain, device-only. Until the watch collects it, iOS holds the queued copy in WatchConnectivity's own on-disk queue — outside the Keychain, for a window this app doesn't control. Sending again cancels the copy that was waiting and replaces it, and so does signing out."
                    )
                }
            }
        }
        // Pairing facts settle after activation, so this section may appear just
        // after Settings rather than claiming a watch exists on its first frame.
        .task { handoff.start() }
    }

    @ViewBuilder private var status: some View {
        switch handoff.status {
        case .idle:
            EmptyView()
        case .queued:
            Label(
                "Queued — your watch will pick it up when it's nearby",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.footnote)
        case .delivered:
            Label("Delivered to your Apple Watch", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.Status.goodInk)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.Status.criticalInk)
        }
    }
}
#endif
