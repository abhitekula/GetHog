import Foundation
import GetHogKit
import WatchConnectivity

/// The one throwable snapshot operation a hand-off needs. Keeping this seam
/// narrower than `SharedSnapshotStore` lets the receiver prove that a failed
/// file write does not publish a half-applied selection.
protocol MetricWatchWriting: Sendable {
    func writeMetricWatches(_ watches: [MetricWatch]) throws
}

extension SharedSnapshotStore: MetricWatchWriting {}

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

    /// One process-wide boundary for every source of a hand-off: durable
    /// WCSession delivery, application context, and manual entry. The three
    /// stores have no shared transaction primitive, so excluding another apply
    /// from credential save through the final defaults write is what prevents
    /// one scope's key from being paired with another scope's snapshot.
    private static let applyLock = NSLock()

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
    /// non-secret half. Watches go into the snapshot store's own file, where a
    /// widget or a background wake can read them without the app running. The
    /// selected organization, project, headline and degradation state go into
    /// defaults.
    ///
    /// Ingestion or snapshot writing failing aborts the whole apply. Because
    /// ingestion has already touched the keychain by the time the file write
    /// can fail, the previous credential is restored before returning false;
    /// defaults and the live-model notification remain untouched.
    @discardableResult
    static func apply(
        _ transfer: WatchKeyTransfer,
        credentials: any CredentialStoring = KeychainTokenStore(),
        snapshots: any MetricWatchWriting = SharedSnapshotStore.shared,
        defaults: UserDefaults = .standard,
        notify: @Sendable () -> Void = WatchSessionListener.postAppliedNotification
    ) -> Bool {
        let applied = applyLock.withLock {
            applyStores(
                transfer,
                credentials: credentials,
                snapshots: snapshots,
                defaults: defaults
            )
        }
        guard applied else { return false }

        // NotificationCenter delivers synchronously and observers may trigger
        // work of their own. The stores are now coherent, so release the lock
        // before announcing rather than making re-entry a deadlock.
        notify()
        return true
    }

    private static func applyStores(
        _ transfer: WatchKeyTransfer,
        credentials: any CredentialStoring,
        snapshots: any MetricWatchWriting,
        defaults: UserDefaults
    ) -> Bool {
        let previousCredential: StoredCredential?
        do {
            previousCredential = try credentials.load()
        } catch {
            return false
        }

        let selection: WatchKeyTransfer.Selection
        do {
            selection = try transfer.ingest(into: credentials)
        } catch {
            return false
        }

        do {
            try snapshots.writeMetricWatches(selection.watches)
        } catch {
            // Best-effort rollback across two stores that have no shared
            // transaction primitive. The return value remains failure even if
            // the keychain itself refuses this restoration.
            if let previousCredential {
                try? credentials.save(previousCredential)
            } else {
                try? credentials.clear()
            }
            return false
        }

        replace(selection.organizationID, forKey: WatchSettings.organizationIDKey, in: defaults)
        replace(selection.organizationName, forKey: WatchSettings.organizationNameKey, in: defaults)
        replace(selection.projectName, forKey: WatchSettings.projectNameKey, in: defaults)
        // Recorded rather than inferred. An empty watch list means "no
        // thresholds" and a *degraded* one means "your phone sent thresholds
        // this build cannot read" — the two look identical from here, and only
        // the second is something the user can do anything about.
        defaults.set(selection.watchesDegraded, forKey: WatchSettings.watchesDegradedKey)
        replace(selection.headlineMetricID, forKey: WatchSettings.headlineMetricKey, in: defaults)
        return true
    }

    private static func replace(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The default announcement, named so a test can pass its own and assert
    /// that a refused ingestion announces nothing — a listener that posted
    /// anyway would send a live model to refetch with a credential it does not
    /// have.
    static let postAppliedNotification: @Sendable () -> Void = {
        NotificationCenter.default.post(name: .gethogWatchKeyTransferApplied, object: nil)
    }
}

/// The watch's deliberately small independent-install fallback.
///
/// The raw input is passed straight into the same `WatchKeyTransfer` ingestion
/// path as a phone hand-off. It is never retained here, logged, or reflected;
/// the helper returns only whether the key reached the watch keychain.
enum WatchManualKeyEntry {
    static func save(
        key: String,
        region: PostHogRegion,
        credentials: any CredentialStoring = KeychainTokenStore(),
        snapshots: any MetricWatchWriting = SharedSnapshotStore.shared,
        defaults: UserDefaults = .standard,
        notify: @Sendable () -> Void = WatchSessionListener.postAppliedNotification
    ) -> Bool {
        WatchSessionListener.apply(
            WatchKeyTransfer(key: key, region: region),
            credentials: credentials,
            snapshots: snapshots,
            defaults: defaults,
            notify: notify
        )
    }
}
