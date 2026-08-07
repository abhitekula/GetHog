import Foundation
import GetHogKit
import WatchConnectivity

extension Notification.Name {
    /// Posted after a hand-off has been written to all three stores.
    ///
    /// The notification carries no payload on purpose: the stores are the
    /// single source of truth and `WatchHandoff.current()` is the single
    /// reader, so a running model refetches its state rather than being handed
    /// a second copy that could disagree with what a relaunch would read.
    static let gethogWatchKeyTransferApplied =
        Notification.Name("app.gethog.watchKeyTransferApplied")
}

/// Receives the phone's `WatchKeyTransfer` and applies it.
///
/// Deliberately thin, and split in two on one line: activation and routing are
/// `WCSession`'s business and cannot be tested without a paired device;
/// `apply` is everything a transfer actually *does*, and takes its three stores
/// as parameters so all of it is covered without a session at all.
///
/// The phone-side sender is a later task's; both ends name the payload with
/// `WatchKeyTransfer.userInfoKey`, which is a kit constant precisely because it
/// is the last thing two independently shipped binaries can still spell
/// differently.
///
/// `@unchecked Sendable`: the type has no stored state. Everything it touches
/// is either a parameter or a process-wide store that is safe from any thread,
/// and the `WCSession` callbacks arrive on a queue the delegate does not choose.
final class WatchSessionListener: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSessionListener()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    /// The durable channel — queued by the phone until the watch is reachable.
    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        Self.route(userInfo)
    }

    /// The latest-wins channel. Both are routed, so the phone-side sender may
    /// choose either without a second receiver having to be written.
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Self.route(applicationContext)
    }

    /// A payload that is not a transfer, or not decodable as one, writes
    /// nothing: a malformed hand-off must not be able to clear a working
    /// credential.
    nonisolated static func route(_ payload: [String: Any]) {
        guard let transfer = transfer(from: payload) else { return }
        apply(transfer)
    }

    /// The decode half of `route`, split out so the wire can be tested end to
    /// end without a `WCSession` **and** without the real keychain: `route`
    /// itself takes the production stores by design, and a test that called it
    /// would write a credential into the device's own keychain.
    nonisolated static func transfer(from payload: [String: Any]) -> WatchKeyTransfer? {
        guard let data = payload[WatchKeyTransfer.userInfoKey] as? Data else { return nil }
        return try? WatchKeyTransfer.decode(data)
    }

    /// The testable half.
    ///
    /// Credential through the kit's ingestion helper — which trims, refuses an
    /// empty key *before* touching the store, and hands back only the
    /// non-secret half. Watches into the snapshot store's own file, where a
    /// widget or a background wake can read them without the app running. The
    /// two non-secrets into defaults.
    ///
    /// Ingestion failing aborts the whole apply: a receiver that stored a
    /// project name for a key it never saved would show the right heading over
    /// numbers it cannot fetch.
    static func apply(
        _ transfer: WatchKeyTransfer,
        credentials: any CredentialStoring = KeychainTokenStore(),
        snapshots: SharedSnapshotStore = .shared,
        defaults: UserDefaults = .standard,
        notify: @Sendable () -> Void = WatchSessionListener.postAppliedNotification
    ) {
        guard let selection = try? transfer.ingest(into: credentials) else { return }
        try? snapshots.writeMetricWatches(selection.watches)
        defaults.set(selection.projectName, forKey: WatchSettings.projectNameKey)
        // Recorded rather than inferred. An empty watch list means "no
        // thresholds" and a *degraded* one means "your phone sent thresholds
        // this build cannot read" — the two look identical from here, and only
        // the second is something the user can do anything about.
        defaults.set(selection.watchesDegraded, forKey: WatchSettings.watchesDegradedKey)
        if let id = selection.headlineMetricID {
            defaults.set(id, forKey: WatchSettings.headlineMetricKey)
        } else {
            defaults.removeObject(forKey: WatchSettings.headlineMetricKey)
        }
        // Last, and only on a complete write: a running model that adopted
        // half a hand-off would show the new project's name over the old
        // project's numbers. Posted rather than called directly, because this
        // runs on a `WCSession` queue with no reference to what is on screen.
        notify()
    }

    /// The default announcement, named so a test can pass its own and assert
    /// that a refused ingestion announces nothing — a listener that posted
    /// anyway would send a live model to refetch with a credential it does not
    /// have.
    static let postAppliedNotification: @Sendable () -> Void = {
        NotificationCenter.default.post(name: .gethogWatchKeyTransferApplied, object: nil)
    }
}
