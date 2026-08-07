import Foundation
import GetHogKit
import WatchConnectivity

/// The throwable snapshot operations a hand-off needs. Keeping this seam
/// narrower than `SharedSnapshotStore` lets the receiver prove that a failed
/// threshold write or project-data cleanup cannot publish a half-applied
/// selection.
protocol MetricWatchWriting: Sendable {
    func writeMetricWatches(_ watches: [MetricWatch]) throws
    func clearProjectScopedData() throws
}

extension SharedSnapshotStore: MetricWatchWriting {
    /// Removes every file a widget could render under the active project.
    /// All removals are attempted before the first error is rethrown, so a
    /// failed scope change leaves as little stale material as possible. The
    /// caller restores the old credential, making any surviving file belong
    /// to the still-active old scope rather than exposing it under the new one.
    func clearProjectScopedData() throws {
        var firstFailure: (any Error)?
        for url in [
            fileURL,
            WatchActivity.fileURL(in: self),
            breachingWatchIDsURL,
            metricWatchesURL,
        ] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }
}

/// Coordinates credential intent, commitment, and store serialization.
/// Production uses `.shared`; tests inject one instance per case so pending
/// intent and revisions cannot leak across independently running suites.
final class WatchCredentialMutationCoordinator: @unchecked Sendable {
    struct Intent: Sendable {
        let revision: UInt64
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var nextRevision: UInt64 = 0
        var currentRevision: UInt64 = 0
        var pending: Set<UInt64> = []
        var settlementWaiters: [CheckedContinuation<Void, Never>] = []
    }

    static let shared = WatchCredentialMutationCoordinator()

    private let serializationLock = NSLock()
    private let state = State()

    init() {}

    /// The latest successfully committed credential mutation. A pending intent
    /// is tracked separately so a failed transfer does not permanently move
    /// the revision beyond what any model could adopt.
    var currentRevision: UInt64 {
        state.lock.withLock { state.currentRevision }
    }

    var hasPendingMutation: Bool {
        state.lock.withLock { !state.pending.isEmpty }
    }

    var hasSettlementWaiters: Bool {
        state.lock.withLock { !state.settlementWaiters.isEmpty }
    }

    /// Registers before waiting for serialization. This is the load-bearing
    /// inverse-ordering guarantee: an old model sees pending intent even when
    /// the incoming apply has not touched a store yet.
    func registerIntent() -> Intent {
        state.lock.withLock {
            state.nextRevision &+= 1
            let intent = Intent(revision: state.nextRevision)
            state.pending.insert(intent.revision)
            return intent
        }
    }

    func withSerializationLock<Result>(_ operation: () -> Result) -> Result {
        serializationLock.withLock(operation)
    }

    /// A later-registered intent may acquire the non-fair lock first. Once it
    /// commits, an older waiter must be refused rather than overwrite newer
    /// stores while leaving the committed revision pointing at that newer
    /// value.
    func canApply(_ intent: Intent) -> Bool {
        state.lock.withLock {
            state.pending.contains(intent.revision)
                && intent.revision > state.currentRevision
        }
    }

    /// Called from inside serialization on every apply result. Committing under
    /// that same lock makes the stores and their revision one coherent value
    /// for `WatchHandoff.current`; failure only clears pending intent.
    func complete(_ intent: Intent, succeeded: Bool) {
        let waiters: [CheckedContinuation<Void, Never>] = state.lock.withLock {
            state.pending.remove(intent.revision)
            if succeeded {
                state.currentRevision = max(state.currentRevision, intent.revision)
            }
            guard state.pending.isEmpty else {
                return [CheckedContinuation<Void, Never>]()
            }
            defer { state.settlementWaiters.removeAll() }
            return state.settlementWaiters
        }
        // A resumed model can immediately try to register another read of the
        // stores, so continuations run outside the state lock.
        waiters.forEach { $0.resume() }
    }

    func isSettled(at adoptedRevision: UInt64) -> Bool {
        state.lock.withLock {
            state.pending.isEmpty && state.currentRevision == adoptedRevision
        }
    }

    /// Suspends an adoption refresh until every intent that was already
    /// announced has either committed or been refused. This is distinct from
    /// an "applied" notification: an older rev-1 waiter can be refused after
    /// rev-2 committed, and that refusal is precisely what makes rev-2 safe to
    /// publish even though no second successful notification is emitted.
    func waitUntilSettled(at adoptedRevision: UInt64) async -> Bool {
        if hasPendingMutation {
            await withCheckedContinuation { continuation in
                let resumeImmediately = state.lock.withLock {
                    guard !state.pending.isEmpty else { return true }
                    state.settlementWaiters.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        return isSettled(at: adoptedRevision)
    }

    /// Linearizes final identity acceptance or refresh publication against a
    /// new intent. Once this guard succeeds, registration waits until the
    /// operation finishes; if intent registered first, the operation refuses.
    func performIfSettled(
        at adoptedRevision: UInt64,
        _ operation: () -> Void
    ) -> Bool {
        state.lock.withLock {
            guard state.pending.isEmpty,
                  state.currentRevision == adoptedRevision else { return false }
            operation()
            return true
        }
    }
}

extension Notification.Name {
    /// Posted after a hand-off changes the effective credential or completes.
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
    /// non-secret half. Watches go into the snapshot store's own file, where a
    /// widget or a background wake can read them without the app running. The
    /// selected organization, project, headline and degradation state go into
    /// defaults.
    ///
    /// Ingestion or snapshot writing failing aborts the whole apply. Because
    /// ingestion has already touched the keychain by the time the file write
    /// can fail, the previous credential is restored before returning false.
    /// If that best-effort restoration fails, the effective credential has
    /// still changed and the running model is notified to reconcile fail-closed
    /// state even though the transactional apply reports failure.
    @discardableResult
    static func apply(
        _ transfer: WatchKeyTransfer,
        credentials: any CredentialStoring = KeychainTokenStore(),
        snapshots: any MetricWatchWriting = SharedSnapshotStore.shared,
        defaults: UserDefaults = .standard,
        mutationCoordinator: WatchCredentialMutationCoordinator = .shared,
        mutationDidAnnounce: @Sendable (UInt64) -> Void = { _ in },
        projectDataDidChange: @Sendable () -> Void = WatchSessionListener.reloadProjectData,
        notify: @Sendable () -> Void = WatchSessionListener.postAppliedNotification
    ) -> Bool {
        let intent = mutationCoordinator.registerIntent()
        mutationDidAnnounce(intent.revision)
        let outcome = mutationCoordinator.withSerializationLock {
            var applied = false
            defer { mutationCoordinator.complete(intent, succeeded: applied) }
            guard mutationCoordinator.canApply(intent) else { return ApplyOutcome.refused }
            let outcome = applyStores(
                transfer,
                credentials: credentials,
                snapshots: snapshots,
                defaults: defaults
            )
            applied = outcome.applied
            return outcome
        }
        // A scope clear becomes visible to the widget process immediately,
        // including a safe partial clear followed by rollback. Reload only
        // after credential serialization is released.
        if outcome.projectDataChanged { projectDataDidChange() }

        // NotificationCenter delivers synchronously and observers may trigger
        // work of their own. Store mutation is finished, so release the lock
        // before announcing the effective state rather than making re-entry a
        // deadlock.
        if outcome.applied || outcome.credentialChangedAfterFailure { notify() }
        return outcome.applied
    }

    private struct ApplyOutcome {
        let applied: Bool
        let projectDataChanged: Bool
        let credentialChangedAfterFailure: Bool

        static let refused = ApplyOutcome(
            applied: false,
            projectDataChanged: false,
            credentialChangedAfterFailure: false
        )
    }

    private static func applyStores(
        _ transfer: WatchKeyTransfer,
        credentials: any CredentialStoring,
        snapshots: any MetricWatchWriting,
        defaults: UserDefaults
    ) -> ApplyOutcome {
        let previousCredential: StoredCredential?
        do {
            previousCredential = try credentials.load()
        } catch {
            return .refused
        }

        // Validate before cleanup. An empty hand-off is not an incoming scope
        // and must not be able to erase a working project's widget files.
        guard !transfer.key.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return .refused }

        // A verified same-project key rotation may keep its stale fallback.
        // Every other transition — including an unverified manual key — must
        // blank all active project files before the new credential is saved.
        // Cleanup therefore cannot need credential rollback, and even a later
        // save/write failure that cannot restore the old key leaves widgets
        // fail-closed on blank files.
        let preservesProjectData = previousCredential?.projectID != nil
            && previousCredential?.projectID == transfer.projectID
            && previousCredential?.region == transfer.region
        let shouldClearProjectData = !preservesProjectData

        if shouldClearProjectData {
            do {
                try snapshots.clearProjectScopedData()
            } catch {
                return ApplyOutcome(
                    applied: false,
                    projectDataChanged: true,
                    credentialChangedAfterFailure: false
                )
            }
            clearScopeDefaults(in: defaults)
        }

        let selection: WatchKeyTransfer.Selection
        do {
            selection = try transfer.ingest(into: credentials)
        } catch {
            restore(previousCredential, to: credentials)
            return ApplyOutcome(
                applied: false,
                projectDataChanged: shouldClearProjectData,
                credentialChangedAfterFailure: credentialDiffers(
                    from: previousCredential, in: credentials
                )
            )
        }

        do {
            try snapshots.writeMetricWatches(selection.watches)
        } catch {
            // Best-effort rollback across two stores that have no shared
            // transaction primitive. The return value remains failure even if
            // the keychain itself refuses this restoration.
            restore(previousCredential, to: credentials)
            return ApplyOutcome(
                applied: false,
                projectDataChanged: shouldClearProjectData,
                credentialChangedAfterFailure: credentialDiffers(
                    from: previousCredential, in: credentials
                )
            )
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
        return ApplyOutcome(
            applied: true,
            projectDataChanged: shouldClearProjectData,
            credentialChangedAfterFailure: false
        )
    }

    /// A failed write is still a live configuration change when its attempted
    /// credential rollback did not restore the value observed before the
    /// transaction. If the final read itself fails, reconcile conservatively:
    /// the listener cannot prove that the running model still matches storage.
    private static func credentialDiffers(
        from previousCredential: StoredCredential?,
        in store: any CredentialStoring
    ) -> Bool {
        do {
            return try store.load() != previousCredential
        } catch {
            return true
        }
    }

    private static func restore(
        _ credential: StoredCredential?,
        to store: any CredentialStoring
    ) {
        if let credential {
            try? store.save(credential)
        } else {
            try? store.clear()
        }
    }

    /// Metadata and thresholds are just as project-scoped as the rendered
    /// snapshot. Once file cleanup succeeds, blank these before installing the
    /// new credential so any later ingest/write failure leaves a relaunch with
    /// no old selection to pair with that replacement key.
    private static func clearScopeDefaults(in defaults: UserDefaults) {
        defaults.removeObject(forKey: WatchSettings.organizationIDKey)
        defaults.removeObject(forKey: WatchSettings.organizationNameKey)
        defaults.removeObject(forKey: WatchSettings.projectNameKey)
        defaults.removeObject(forKey: WatchSettings.headlineMetricKey)
        defaults.removeObject(forKey: WatchSettings.watchesDegradedKey)
    }

    private static func replace(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The default announcement, named so a test can pass its own and assert
    /// whether the effective credential changed. An ordinary refusal announces
    /// nothing; a failed rollback announces so the live model cannot keep using
    /// the credential and project scope it held before the transaction.
    static let postAppliedNotification: @Sendable () -> Void = {
        NotificationCenter.default.post(name: .gethogWatchKeyTransferApplied, object: nil)
    }

    /// WidgetKit is main-actor isolated under the target's Swift 6 defaults,
    /// while WCSession applies arrive on a queue it owns. The nonisolated
    /// callback only schedules after serialization has ended; the extension
    /// APIs themselves remain on MainActor rather than being unsafely erased.
    static let reloadProjectData: @Sendable () -> Void = {
        Task { @MainActor in
            WatchRefresh.snapshotDidPublish()
        }
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
        mutationCoordinator: WatchCredentialMutationCoordinator = .shared,
        notify: @Sendable () -> Void = WatchSessionListener.postAppliedNotification
    ) -> Bool {
        WatchSessionListener.apply(
            WatchKeyTransfer(key: key, region: region),
            credentials: credentials,
            snapshots: snapshots,
            defaults: defaults,
            mutationCoordinator: mutationCoordinator,
            notify: notify
        )
    }
}
