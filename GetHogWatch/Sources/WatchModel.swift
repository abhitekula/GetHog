import Foundation
import GetHogKit
import LocalAuthentication
import Observation

/// Keys the watch persists outside the snapshot file.
///
/// `UserDefaults`, not the keychain: none of these is a secret, and the
/// session listener writes them from a nonisolated `WCSession` callback that
/// has no actor to hop to. The credential itself never comes near this type —
/// that goes through `WatchKeyTransfer.ingest(into:)` and into the keychain.
enum WatchSettings {
    static let headlineMetricKey = "watchHeadlineMetricID"
    static let organizationIDKey = "watchOrganizationID"
    static let organizationNameKey = "watchOrganizationName"
    static let projectNameKey = "watchProjectName"
    /// Set when the last hand-off carried a watch list this build could not
    /// read — a phone running a newer GetHog than the wrist. The key still
    /// landed; the thresholds did not, and the Health page has to say so
    /// rather than draw the healthy-looking empty state that would otherwise
    /// be indistinguishable from "you have no watches".
    static let watchesDegradedKey = "watchThresholdsDegraded"
}

// MARK: - Health

/// What the Health page states, derived purely so it is testable without a
/// clock, a keychain, or a network.
struct WatchHealth: Equatable, Sendable {

    struct WatchRow: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let summary: String
        let isFiring: Bool
    }

    struct ErrorPulse: Equatable, Sendable {
        let activeCount: Int
        let topIssueName: String?
        let topOccurrences: Double
    }

    let rows: [WatchRow]
    /// `nil` means **not checked**, which is a different claim from "healthy"
    /// and must never render as one.
    let errorPulse: ErrorPulse?

    static let empty = WatchHealth(rows: [], errorPulse: nil)

    var firingCount: Int { rows.count(where: \.isFiring) }

    /// Evaluates the user's watches against the snapshot with the kit's own
    /// evaluator, so firing/quiet on the wrist is the same verdict the phone's
    /// notifications are built from — and costs **no request at all**, because
    /// the snapshot is already in hand.
    ///
    /// Returns the latch to persist alongside the health, which is the same
    /// anti-spam contract `SharedSnapshotStore.writeBreachingWatchIDs` holds:
    /// a watch leaves the set only when its metric is *seen* to be back inside
    /// the threshold, never because it was missing.
    static func derive(
        snapshot: SharedSnapshot?,
        watches: [MetricWatch],
        previouslyBreaching: Set<String>,
        issues: [ErrorIssue]?
    ) -> (health: WatchHealth, breaching: Set<String>) {
        var rows: [WatchRow] = []
        var breaching = previouslyBreaching
        if let snapshot {
            breaching = MetricWatchEvaluator.evaluate(
                snapshot: snapshot,
                watches: watches,
                breaching: previouslyBreaching
            ).breaching
        }
        for watch in watches where watch.isEnabled {
            rows.append(WatchRow(
                id: watch.id,
                // The current metric's name when the snapshot has it, the
                // watch's saved title when it does not — the same rule the
                // kit's evaluator applies to a notification title.
                title: snapshot?.metric(id: watch.metricID)?.title ?? watch.title,
                summary: watch.condition.summary,
                isFiring: breaching.contains(watch.id)
            ))
        }
        let pulse = issues.map { issues -> ErrorPulse in
            let active = issues.filter { $0.status == "active" }
            let top = active.max { $0.occurrences < $1.occurrences }
            return ErrorPulse(
                activeCount: active.count,
                topIssueName: top?.name,
                topOccurrences: top?.occurrences ?? 0
            )
        }
        return (WatchHealth(rows: rows, errorPulse: pulse), breaching)
    }
}

// MARK: - Hand-off

/// Provenance of the credential held by a running Watch model.
///
/// A missing value in a real credential store is not equivalent to the DEBUG
/// environment fallback. Keeping that distinction explicit prevents a keychain
/// record that vanished during `/me` from inheriting the process-only path's
/// permission to resolve without persistence and restore quarantined files.
enum WatchCredentialSource: Sendable, Equatable {
    case stored
    case processOnly
}

/// Everything about a running model that a phone hand-off can change.
///
/// A value rather than five reads scattered across `live()` and the session
/// listener, so a launch and a mid-flight transfer take the same state from
/// the same places and cannot diverge. `current()` is the only reader; the
/// listener writes those stores and posts, and the model reads them back.
struct WatchHandoff: Sendable, Equatable {
    let credential: StoredCredential?
    let credentialSource: WatchCredentialSource
    let credentialRevision: UInt64
    let organizationID: String?
    let organizationName: String?
    let projectName: String?
    let headlineMetricID: String?
    let watches: [MetricWatch]
    let watchesDegraded: Bool

    init(
        credential: StoredCredential?,
        credentialSource: WatchCredentialSource = .stored,
        credentialRevision: UInt64 = 0,
        organizationID: String? = nil,
        organizationName: String? = nil,
        projectName: String?,
        headlineMetricID: String?,
        watches: [MetricWatch],
        watchesDegraded: Bool
    ) {
        self.credential = credential
        self.credentialSource = credentialSource
        self.credentialRevision = credentialRevision
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.projectName = projectName
        self.headlineMetricID = headlineMetricID
        self.watches = watches
        self.watchesDegraded = watchesDegraded
    }

    /// What the three stores say right now.
    ///
    /// The DEBUG `GETHOG_API_KEY` fallback lives here rather than in `live()`
    /// so a re-read after a transfer cannot silently lose it — it is in
    /// memory, dies with the process, and is never written to the keychain,
    /// which is the whole point of the channel AGENTS.md documents.
    static func current(
        credentials: any CredentialStoring = KeychainTokenStore(),
        defaults: UserDefaults = .standard,
        snapshots: SharedSnapshotStore = .shared,
        mutationCoordinator: WatchCredentialMutationCoordinator = .shared
    ) -> WatchHandoff {
        mutationCoordinator.withSerializationLock {
            var credential = try? credentials.load()
            var credentialSource = WatchCredentialSource.stored
            #if DEBUG
            if credential == nil,
               let key = ProcessInfo.processInfo.environment["GETHOG_API_KEY"],
               !key.isEmpty {
                // No projectID: `refresh` resolves it through `/users/@me/` once.
                credential = StoredCredential(key: key, region: .usCloud)
                credentialSource = .processOnly
            }
            #endif
            return WatchHandoff(
                credential: credential,
                credentialSource: credentialSource,
                credentialRevision: mutationCoordinator.currentRevision,
                organizationID: defaults.string(forKey: WatchSettings.organizationIDKey),
                organizationName: defaults.string(forKey: WatchSettings.organizationNameKey),
                projectName: defaults.string(forKey: WatchSettings.projectNameKey),
                headlineMetricID: defaults.string(forKey: WatchSettings.headlineMetricKey),
                watches: snapshots.metricWatches(),
                watchesDegraded: defaults.bool(forKey: WatchSettings.watchesDegradedKey)
            )
        }
    }
}

// MARK: - Refresh failures

/// Device-specific recovery for any refresh section that could not reach
/// PostHog.
///
/// The Watch can issue requests through its paired iPhone. In that path
/// Foundation reports `NSURLErrorNotConnectedToInternet` on the Watch when the
/// phone is connected over Bluetooth but the phone itself has no internet.
/// Naming the phone is therefore useful for exactly that code and misleading
/// for every other transport failure.
enum WatchRefreshGuidance: Equatable, Sendable {
    case iPhoneOffline

    var message: String {
        switch self {
        case .iPhoneOffline:
            "Your iPhone may be offline. Connect it to the internet, then try again."
        }
    }
}

/// Why the last attempted refresh did not complete.
///
/// This is deliberately separate from the user-facing sentence. A failed
/// phase used to make every error look like a rejected key, which offered a
/// destructive replacement form for an outage, a 429, a 5xx, or malformed
/// JSON. Only a real 401 is authentication failure; everything else keeps the
/// credential and offers retry or a non-destructive explanation.
enum WatchRefreshFailure: Equatable, Sendable {
    case authentication
    case retryable
    case invalidResponse
    case other

    fileprivate var priority: Int {
        switch self {
        case .authentication: 4
        case .invalidResponse: 3
        case .retryable: 2
        case .other: 1
        }
    }

    var permitsCredentialReplacement: Bool { self == .authentication }
    var permitsRetry: Bool {
        switch self {
        case .retryable, .invalidResponse: true
        case .authentication, .other: false
        }
    }
}

/// Recovery attached to one best-effort Watch section. The aggregate refresh
/// failure still drives credential replacement on Metrics; this value prevents
/// a failed peer endpoint from masquerading as a successful empty response.
struct WatchSectionFailure: Equatable, Sendable {
    let message: String
    let canRetry: Bool
}

/// The Flags page's complete presentation contract. An empty array is not a
/// state by itself: the endpoint may not have been asked, may still be in
/// flight, or may have answered successfully with no rows.
enum WatchFlagsContentState: Equatable {
    case needsCredential
    case notChecked
    case loading
    case empty(capturedAt: Date)
    case rows([SharedSnapshot.Flag], capturedAt: Date?)
    case carried(
        [SharedSnapshot.Flag],
        failure: WatchSectionFailure,
        capturedAt: Date?
    )
    case failure(WatchSectionFailure)
}

/// Durable proof that the flags endpoint itself answered for one project
/// scope. Kept beside, rather than inside, the cross-platform snapshot so an
/// older app/widget binary can continue decoding that shared contract.
struct WatchFlagsReceipt: Codable, Equatable, Sendable {
    let projectID: Int
    let projectRegion: PostHogRegion
    let capturedAt: Date

    private static let fileName = "watch-flags-receipt.json"

    static func fileURL(in store: SharedSnapshotStore) -> URL {
        store.directory.appendingPathComponent(fileName)
    }

    func matches(
        snapshot: SharedSnapshot,
        projectID: Int,
        projectRegion: PostHogRegion
    ) -> Bool {
        self.projectID == projectID
            && self.projectRegion == projectRegion
            && snapshot.projectID == projectID
            && snapshot.projectRegion == projectRegion
    }

    static func read(from store: SharedSnapshotStore) -> WatchFlagsReceipt? {
        guard let data = try? Data(contentsOf: fileURL(in: store)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WatchFlagsReceipt.self, from: data)
    }

    func write(to store: SharedSnapshotStore) throws {
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(
            to: Self.fileURL(in: store), options: [.atomic]
        )
    }

    static func clear(from store: SharedSnapshotStore) {
        try? FileManager.default.removeItem(at: fileURL(in: store))
    }
}

/// Collects failures from one sequential wrist refresh without turning the
/// five independent best-effort sections into one all-or-nothing request.
@MainActor
private final class WatchRequestFailures {
    private var sawNotConnectedToInternet = false
    private(set) var failure: WatchRefreshFailure?
    private(set) var userMessage: String?

    func capture<Value>(
        _ operation: () async throws -> Value,
        onFailure: ((WatchSectionFailure) -> Void)? = nil
    ) async -> Value? {
        do {
            return try await operation()
        } catch {
            let isOffline = Self.isNotConnectedToInternet(error)
            if isOffline {
                sawNotConnectedToInternet = true
            }
            let classification = Self.classification(of: error)
            onFailure?(WatchSectionFailure(
                message: isOffline
                    ? WatchRefreshGuidance.iPhoneOffline.message
                    : Self.userMessage(for: error),
                canRetry: classification.permitsRetry
            ))
            if failure == nil || classification.priority > (failure?.priority ?? 0) {
                failure = classification
                userMessage = Self.userMessage(for: error)
            }
            return nil
        }
    }

    var guidance: WatchRefreshGuidance? {
        sawNotConnectedToInternet ? .iPhoneOffline : nil
    }

    private static func isNotConnectedToInternet(_ error: any Error) -> Bool {
        let code = URLError.Code.notConnectedToInternet.rawValue
        if let error = error as? PostHogError, error.networkErrorCode == code {
            return true
        }
        let foundation = error as NSError
        return foundation.domain == NSURLErrorDomain && foundation.code == code
    }

    private static func classification(of error: any Error) -> WatchRefreshFailure {
        if error is DecodingError {
            return .invalidResponse
        }
        if let postHog = error as? PostHogError {
            switch postHog {
            case .unauthorized:
                return .authentication
            case .decoding:
                return .invalidResponse
            default:
                return postHog.isRetryable ? .retryable : .other
            }
        }
        let foundation = error as NSError
        return foundation.domain == NSURLErrorDomain ? .retryable : .other
    }

    private static func userMessage(for error: any Error) -> String {
        if error is DecodingError {
            return "PostHog's response wasn't in a shape this app could read."
        }
        guard let postHog = error as? PostHogError else {
            return "PostHog couldn't be reached."
        }
        switch postHog {
        case .network, .transport:
            return "PostHog couldn't be reached."
        case .http(let status, _) where status >= 500:
            return "PostHog couldn't be reached."
        default:
            return postHog.errorDescription ?? "PostHog couldn't be reached."
        }
    }
}

// MARK: - Model

/// Fetches directly from PostHog with trimmed queries, reduces to the same
/// `SharedSnapshot` the other platforms publish, and writes it to the
/// watch-local App Group container for `GetHogWatchWidgets` to read.
///
/// **Request budget per refresh**, all through the client's
/// `RateLimitGovernor`: dashboards list (crud) + dashboard detail (analytics,
/// `force_cache`) + flags (crud) + error pulse (query) + activity (query) =
/// **five requests**, throttled to at most one refresh per `refreshTolerance`.
/// No paging, no widening ladders, and the Health page's own reading costs
/// nothing on top — it is local arithmetic over the snapshot those five
/// requests already produced.
@MainActor
@Observable
final class WatchModel {

    enum Phase: Equatable {
        /// No credential yet — the phone has not sent one and no debug key is
        /// set. Distinct from `.failed`, which means we had a key and it did
        /// not work.
        case needsKey
        case loading
        case ready
        case failed(String)
    }

    /// What one wrist fetch may cost, in one value.
    ///
    /// Every range and every page size below comes from here. This started as
    /// five separate literals — a dashboards limit of 20, a flags limit of 50,
    /// an events limit of 25, and the string `"-24h"` and the interval
    /// `24 * 3600` spelling the same day twice — which is precisely the drift
    /// `QueryBudget` exists to stop: four of them were larger than the wrist
    /// budget the kit defines, and the flags page fetched fifty rows to render
    /// ten. The kit's budgeted overloads forward to the same builders, so a
    /// budgeted request is the ordinary request with smaller arguments rather
    /// than a second spelling that can drift.
    /// `nonisolated` because the pure copy builders — the Activity footer, the
    /// Health section title — are not main-actor code and must still be able to
    /// name the window they are describing.
    nonisolated static let budget = QueryBudget.wrist

    /// Deliberately tighter than `budget.pageSize`: the pulse is a count and a
    /// worst offender, not a triage list, and five rows answer that.
    nonisolated static let errorPulseLimit = 5
    /// The flags page fetches exactly what the shortlist draws, so no row is
    /// paid for and discarded.
    nonisolated static var flagShortlistCap: Int { budget.pageSize }
    /// A wrist glance does not need numbers fresher than this, and the budget
    /// is organisation-wide.
    static let refreshTolerance: TimeInterval = 15 * 60

    private(set) var phase: Phase
    /// Actionable only for the one Foundation code whose Watch meaning is
    /// specific. It can coexist with `.ready` when an older snapshot remains
    /// on screen or when another section produced a partial fresh snapshot.
    private(set) var refreshGuidance: WatchRefreshGuidance?
    /// Machine-readable recovery for every other failure. UI must consult this
    /// before offering credential replacement; `.failed` alone is only a
    /// presentation phase and says nothing about whether the key was rejected.
    private(set) var refreshFailure: WatchRefreshFailure?
    private(set) var refreshFailureMessage: String?
    private(set) var flagsRefreshFailure: WatchSectionFailure?
    private(set) var healthRefreshFailure: WatchSectionFailure?
    private(set) var activityRefreshFailure: WatchSectionFailure?
    private(set) var explicitRefreshInFlightCount = 0
    private(set) var snapshot: SharedSnapshot?
    private var flagsReceipt: WatchFlagsReceipt?
    private(set) var health: WatchHealth = .empty
    private(set) var activity: [ActivityLine] = []
    /// When `activity` was read from PostHog, which is not always when the
    /// snapshot was written. `nil` means the feed has never been fetched.
    private(set) var activityCapturedAt: Date?
    /// Full render models for time-series tiles, keyed by metric id, so the
    /// Metrics page draws the *real* dated chart the phone draws — no invented
    /// dates and no shape-only sparkline. Not persisted: the snapshot's
    /// `sparkline` is the cross-process contract, and this is the richer thing
    /// this process happens to still be holding.
    private var renders: [String: InsightRenderModel] = [:]

    /// All five change when a hand-off arrives while the app is running, so
    /// none of them can be `let`. See `adopt(_:)`.
    private(set) var headlineMetricID: String?
    /// True when the phone's last hand-off carried thresholds this build could
    /// not decode. See `WatchSettings.watchesDegradedKey`; `watches` is then
    /// empty for a reason the user can act on, and the Health page names it.
    private(set) var watchesDegraded: Bool
    /// Confirms device ownership before a flag write. Injected: live is the
    /// `LAContext` gate below; demo and tests substitute their own verdict, so
    /// no test has to satisfy a passcode prompt.
    let authenticate: @Sendable (String) async -> Bool

    /// Whether an unattended wake would have anything to fetch with.
    ///
    /// `WatchRefresh` asks before it schedules: a wake with no credential can
    /// only fail, and failures teach watchOS that this app's background
    /// requests are not worth granting.
    var hasCredential: Bool { client != nil }

    /// The endpoint carried by the active credential. Read-only outside the
    /// model so replacement entry can preserve it without making credential
    /// scope independently mutable from the client that uses it.
    var credentialRegion: PostHogRegion? { projectRegion }

    private var client: PostHogClient?
    /// The credential used to build `client`, retained only so a successful
    /// identity bootstrap can prove it is still the credential in the
    /// keychain before adding the resolved project id. A DEBUG environment key
    /// has no matching store item and therefore remains process-only.
    private var credential: StoredCredential?
    private var credentialSource: WatchCredentialSource
    private var adoptedCredentialRevision: UInt64
    private var projectID: Int?
    private var projectRegion: PostHogRegion?
    private var projectName: String
    private var watches: [MetricWatch]
    private let transport: any HTTPTransport
    private let store: SharedSnapshotStore
    private let credentialStore: (any CredentialStoring)?
    private let mutationCoordinator: WatchCredentialMutationCoordinator
    private let snapshotDidChange: () -> Void
    private let now: @Sendable () -> Date
    /// Same-generation callers await one operation. A hand-off increments the
    /// generation and may start its forced refresh without waiting for a stale
    /// request from the previous project.
    @ObservationIgnored private var refreshOperations: [Int: Task<Void, Never>] = [:]
    /// An attempt timestamp, not a success timestamp: an outage is not licence
    /// to spend the five-request budget on every wrist raise.
    private var lastRefreshAttemptAt: Date?
    /// Invalidates every suspended request from the previous hand-off. Main
    /// actor isolation makes the comparison atomic across each `await`.
    private var configurationGeneration = 0
    /// Project-scoped files captured from their active App Group URLs while a
    /// nil-id credential waits for `/me` to prove which project it belongs to.
    /// Widgets cannot see this memory, which is the defining property of the
    /// quarantine: the active files are deleted before init returns.
    private var quarantinedProjectData: QuarantinedProjectData?

    private struct QuarantinedProjectData {
        let snapshot: SharedSnapshot?
        let flagsReceipt: WatchFlagsReceipt?
        let activity: ActivityFeed?
        let breachingWatchIDs: Set<String>
    }

    var canRetryRefresh: Bool {
        refreshGuidance != nil || refreshFailure?.permitsRetry == true
    }

    var isExplicitRefreshInFlight: Bool {
        explicitRefreshInFlightCount > 0
    }

    init(
        credential: StoredCredential?,
        projectName: String?,
        headlineMetricID: String?,
        watches: [MetricWatch],
        transport: any HTTPTransport,
        store: SharedSnapshotStore,
        credentialStore: (any CredentialStoring)? = nil,
        credentialSource: WatchCredentialSource = .stored,
        credentialRevision: UInt64? = nil,
        mutationCoordinator: WatchCredentialMutationCoordinator = .init(),
        authenticate: @escaping @Sendable (String) async -> Bool,
        watchesDegraded: Bool = false,
        snapshotDidChange: @escaping () -> Void = { WatchRefresh.snapshotDidPublish() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = Self.client(for: credential, transport: transport)
        self.credential = credential
        self.projectID = credential?.projectID
        self.projectRegion = credential?.region
        self.projectName = projectName ?? "PostHog"
        self.headlineMetricID = headlineMetricID
        self.watches = watches
        self.transport = transport
        self.store = store
        self.credentialStore = credentialStore
        self.credentialSource = credentialSource
        self.mutationCoordinator = mutationCoordinator
        self.adoptedCredentialRevision = credentialRevision
            ?? mutationCoordinator.currentRevision
        self.snapshotDidChange = snapshotDidChange
        self.authenticate = authenticate
        self.watchesDegraded = watchesDegraded
        self.now = now
        self.refreshGuidance = nil
        self.refreshFailure = nil
        self.refreshFailureMessage = nil
        self.flagsRefreshFailure = nil
        self.healthRefreshFailure = nil
        self.activityRefreshFailure = nil
        self.flagsReceipt = nil
        self.quarantinedProjectData = nil
        let stored = store.loadOrNil()
        let storedFlagsReceipt = WatchFlagsReceipt.read(from: store)
        let storedActivity = WatchActivity.read(from: store)
        let storedBreaches = store.breachingWatchIDs()
        let isAwaitingProjectVerification = credential != nil && credential?.projectID == nil
        let carried: SharedSnapshot?
        if let stored,
           let credentialProjectID = credential?.projectID,
           stored.projectID == credentialProjectID,
           stored.projectRegion == credential?.region {
            carried = stored
            if let credentialRegion = credential?.region,
               let storedFlagsReceipt,
               storedFlagsReceipt.matches(
                   snapshot: stored,
                   projectID: credentialProjectID,
                   projectRegion: credentialRegion
               ) {
                self.flagsReceipt = storedFlagsReceipt
            }
        } else {
            carried = nil
        }
        let hasStoredProjectData = stored != nil
            || storedFlagsReceipt != nil
            || storedActivity != nil
            || !storedBreaches.isEmpty
        // A manually entered or DEBUG-only key has no project id until `/me`
        // answers. Capture prior files privately, then remove the active copies
        // before any widget or complication can render them under an unverified
        // credential. A matching `/me` may restore them later in this process.
        if isAwaitingProjectVerification, hasStoredProjectData {
            quarantinedProjectData = QuarantinedProjectData(
                snapshot: stored,
                flagsReceipt: storedFlagsReceipt,
                activity: storedActivity,
                breachingWatchIDs: storedBreaches
            )
        }
        let clearedActiveProjectData = carried == nil && hasStoredProjectData
        if clearedActiveProjectData {
            store.clearSnapshot()
            WatchFlagsReceipt.clear(from: store)
            WatchActivity.clear(from: store)
            store.clearBreachingWatchIDs()
        }
        self.snapshot = carried
        // A manual credential has no selection payload to persist a project
        // name. Once its id is verified on a previous launch, the matching
        // snapshot is the authoritative local spelling and avoids replacing
        // it with the generic "PostHog" on the next successful refresh.
        if projectName == nil, let carried {
            self.projectName = carried.projectName
        }
        if carried != nil, let feed = storedActivity {
            self.activity = feed.lines
            self.activityCapturedAt = feed.capturedAt
        }
        self.phase = credential == nil ? .needsKey : Self.idlePhase(for: carried)
        if carried != nil {
            health = WatchHealth.derive(
                snapshot: carried,
                watches: watches,
                previouslyBreaching: storedBreaches,
                issues: nil
            ).health
        }
        if clearedActiveProjectData {
            snapshotDidChange()
        }
    }

    /// A launch that already found a snapshot shows it rather than a spinner —
    /// stale data with an honest age stamp beats a blank wrist.
    private static func idlePhase(for snapshot: SharedSnapshot?) -> Phase {
        snapshot == nil ? .loading : .ready
    }

    /// The production assembly.
    ///
    /// Demo wins first, so a demo launch can never touch a stored credential;
    /// then the keychain the phone hand-off writes; then, in DEBUG only, the
    /// same `GETHOG_API_KEY` channel the other platforms honor for authorized
    /// manual live testing — in memory, dying with the process, never written
    /// to the keychain.
    static func live() -> WatchModel {
        // First, before anything reads the watch list — including
        // `WatchHandoff.current()` two branches down. A demo launch puts its
        // thresholds where the complication process can read them; a live
        // launch takes them straight back out. See
        // `WatchDemoMode.reconcileSeededWatches`.
        WatchDemoMode.reconcileSeededWatches(in: .shared)
        #if DEBUG
        if let scenario = WatchDemoMode.syntheticScenario {
            WatchDemoMode.prepareSyntheticScenario(scenario, in: .shared)
            return WatchModel(
                credential: scenario.credential,
                projectName: scenario.projectName,
                headlineMetricID: nil,
                watches: scenario.watches,
                transport: WatchDemoMode.syntheticScenarioTransport(for: scenario),
                store: .shared,
                mutationCoordinator: .shared,
                authenticate: { _ in true }
            )
        }
        #endif
        if WatchDemoMode.isEnabled {
            return WatchModel(
                credential: WatchDemoMode.credential,
                projectName: WatchDemoMode.projectName,
                headlineMetricID: nil,
                watches: WatchDemoMode.seededWatches,
                transport: WatchDemoMode.transport(),
                // The same container a live launch writes, which is what the
                // phone's demo does too: a demo the widgets cannot see is a
                // demo of half the product, and the fixtures are labelled
                // synthetic wherever they surface.
                store: .shared,
                mutationCoordinator: .shared,
                authenticate: { _ in true }
            )
        }
        let credentials = KeychainTokenStore()
        let mutationCoordinator = WatchCredentialMutationCoordinator.shared
        let handoff = WatchHandoff.current(
            credentials: credentials,
            mutationCoordinator: mutationCoordinator
        )
        return WatchModel(
            credential: handoff.credential,
            projectName: handoff.projectName,
            headlineMetricID: handoff.headlineMetricID,
            watches: handoff.watches,
            transport: URLSessionTransport(),
            store: .shared,
            credentialStore: credentials,
            credentialSource: handoff.credentialSource,
            credentialRevision: handoff.credentialRevision,
            mutationCoordinator: mutationCoordinator,
            authenticate: WatchModel.deviceOwnerGate,
            watchesDegraded: handoff.watchesDegraded
        )
    }

    private static func client(
        for credential: StoredCredential?, transport: any HTTPTransport
    ) -> PostHogClient? {
        credential.map {
            PostHogClient(
                auth: PersonalKeyAuthProvider(key: $0.key, region: $0.region),
                transport: transport
            )
        }
    }

    // MARK: - Adopting a hand-off that arrived mid-flight

    /// Takes on everything a `WatchKeyTransfer` changed and refetches.
    ///
    /// Without this the Metrics page went on saying "Open GetHog on your iPhone
    /// to hand this watch its key" after the phone had done exactly that: the
    /// credential and the thresholds were read once, in `init`, and a transfer
    /// that landed while the app was running only reached the keychain and the
    /// defaults. The user's remedy was to force-quit the app they had just been
    /// told to wait on.
    ///
    /// Forced, because the throttle is about not re-asking for numbers we
    /// already have and this is a different project, key or threshold set. A
    /// hand-off that changed nothing still costs five requests, which is the
    /// right trade for the one that changed everything.
    func adopt(_ handoff: WatchHandoff) async {
        configurationGeneration &+= 1
        let incomingProjectID = handoff.credential?.projectID
        let incomingProjectRegion = handoff.credential?.region
        if projectID != incomingProjectID || projectRegion != incomingProjectRegion {
            clearProjectScopedState()
        }
        client = Self.client(for: handoff.credential, transport: transport)
        credential = handoff.credential
        credentialSource = handoff.credentialSource
        adoptedCredentialRevision = handoff.credentialRevision
        projectID = incomingProjectID
        projectRegion = incomingProjectRegion
        projectName = handoff.projectName ?? "PostHog"
        headlineMetricID = handoff.headlineMetricID
        watches = handoff.watches
        watchesDegraded = handoff.watchesDegraded
        refreshGuidance = nil
        refreshFailure = nil
        refreshFailureMessage = nil
        flagsRefreshFailure = nil
        healthRefreshFailure = nil
        activityRefreshFailure = nil
        // The rows in hand were evaluated against the *previous* thresholds,
        // so they are not merely stale, they are answers to a question nobody
        // is asking any more.
        health = .empty
        phase = handoff.credential == nil ? .needsKey : Self.idlePhase(for: snapshot)
        guard handoff.credential != nil else { return }
        await refresh(force: true)
    }

    /// Re-reads a committed hand-off that may have landed before the view's
    /// notification subscription existed, or while the scene was suspended.
    /// Same-revision, same-credential reconciliation is a no-op so every
    /// foreground transition does not force a five-request adoption refresh.
    /// A failed apply deliberately leaves the committed revision unchanged,
    /// but its best-effort keychain rollback can fail after writing the incoming
    /// credential. Comparing identity as well as revision makes that partial
    /// failure adopt the fail-closed hand-off instead of continuing to use the
    /// old in-memory client and scope.
    func reconcile(_ handoff: WatchHandoff) async {
        guard handoff.credentialRevision != adoptedCredentialRevision
                || handoff.credential != credential
                || handoff.credentialSource != credentialSource else { return }
        await adopt(handoff)
    }

    /// A stale snapshot is useful only inside one project. When identity
    /// changes, metrics, flags, events, and breach latches all belong to the
    /// previous scope and must leave both the running UI and widget container
    /// before the new network request begins.
    private func clearProjectScopedState() {
        quarantinedProjectData = nil
        snapshot = nil
        flagsReceipt = nil
        renders.removeAll()
        activity = []
        activityCapturedAt = nil
        health = .empty
        store.clearSnapshot()
        WatchFlagsReceipt.clear(from: store)
        WatchActivity.clear(from: store)
        store.clearBreachingWatchIDs()
        snapshotDidChange()
    }

    /// Restores privately quarantined files only after `/me` proves their full
    /// region-and-project identity. The caller holds both credential mutation
    /// gates, so a newer hand-off cannot announce itself between the identity
    /// check and these writes. Returns whether the caller must reload widgets;
    /// that callback deliberately runs only after both locks are released.
    private func restoreQuarantinedProjectDataIfMatching() -> Bool {
        guard let quarantinedProjectData else { return false }
        self.quarantinedProjectData = nil
        guard let projectID,
              let projectRegion,
              let stored = quarantinedProjectData.snapshot,
              stored.projectID == projectID,
              stored.projectRegion == projectRegion else {
            return false
        }
        let restoredFlagsReceipt = quarantinedProjectData.flagsReceipt.flatMap { receipt in
            receipt.matches(
                snapshot: stored,
                projectID: projectID,
                projectRegion: projectRegion
            ) ? receipt : nil
        }

        do {
            try store.write(stored)
            if let restoredFlagsReceipt {
                try restoredFlagsReceipt.write(to: store)
            }
            if let storedActivity = quarantinedProjectData.activity {
                try WatchActivity.write(storedActivity, to: store)
            }
            try store.writeBreachingWatchIDs(
                quarantinedProjectData.breachingWatchIDs
            )
        } catch {
            // Restoration is all-or-nothing from the extension's point of
            // view. Remove any prefix that landed before the failed write.
            store.clearSnapshot()
            WatchFlagsReceipt.clear(from: store)
            WatchActivity.clear(from: store)
            store.clearBreachingWatchIDs()
            return true
        }

        snapshot = stored
        flagsReceipt = restoredFlagsReceipt
        if let storedActivity = quarantinedProjectData.activity {
            activity = storedActivity.lines
            activityCapturedAt = storedActivity.capturedAt
        }
        health = WatchHealth.derive(
            snapshot: stored,
            watches: watches,
            previouslyBreaching: quarantinedProjectData.breachingWatchIDs,
            issues: nil
        ).health
        return true
    }

    /// Accepts `/me` only if no credential replacement has even been announced
    /// since this refresh began. The potentially blocking store load happens
    /// under the serialization lock; revision compare, credential save, and
    /// quarantine publication then happen together under the intention gate.
    /// This ordering lets a hand-off announce itself while the old load is
    /// suspended and guarantees the old response notices before publishing.
    private func acceptResolvedProject(
        id resolvedProjectID: Int,
        name resolvedProjectName: String,
        adoptedRevision: UInt64
    ) -> Bool {
        guard let credential, credential.projectID == nil else { return false }

        enum StoredState {
            case loaded(StoredCredential)
            case processOnly
            case missing
            case readFailure
        }

        var accepted = false
        var shouldReload = false
        mutationCoordinator.withSerializationLock {
            let storedState: StoredState
            if credentialSource == .processOnly {
                storedState = .processOnly
            } else if let credentialStore {
                do {
                    if let stored = try credentialStore.load() {
                        storedState = .loaded(stored)
                    } else {
                        storedState = .missing
                    }
                } catch {
                    storedState = .readFailure
                }
            } else {
                storedState = .missing
            }

            _ = mutationCoordinator.performIfSettled(at: adoptedRevision) {
                switch storedState {
                case .loaded(let stored):
                    guard stored.key == credential.key,
                          stored.region == credential.region,
                          stored.projectID == nil,
                          let credentialStore else {
                        self.quarantinedProjectData = nil
                        rejectResolvedProject(
                            "The saved API key changed before project verification finished."
                        )
                        return
                    }
                    var resolved = stored
                    resolved.projectID = resolvedProjectID
                    do {
                        try credentialStore.save(resolved)
                        self.credential = resolved
                    } catch {
                        // The current process can still use the verified
                        // identity. The next launch will verify it again.
                    }
                case .processOnly:
                    // The DEBUG environment credential deliberately has no
                    // keychain record and must remain process-only.
                    break
                case .missing:
                    // The stored credential disappeared. Stop using the
                    // in-memory client and return to the key-entry state.
                    self.quarantinedProjectData = nil
                    client = nil
                    self.credential = nil
                    projectID = nil
                    projectRegion = nil
                    refreshGuidance = nil
                    refreshFailure = nil
                    refreshFailureMessage = nil
                    phase = .needsKey
                    return
                case .readFailure:
                    self.quarantinedProjectData = nil
                    rejectResolvedProject("The Watch couldn't read its saved API key.")
                    return
                }

                projectID = resolvedProjectID
                projectName = resolvedProjectName
                shouldReload = restoreQuarantinedProjectDataIfMatching()
                accepted = true
            }
        }
        if shouldReload {
            snapshotDidChange()
        }
        return accepted
    }

    private func rejectResolvedProject(_ reason: String) {
        refreshGuidance = nil
        refreshFailure = .retryable
        refreshFailureMessage = reason + " Try again."
        phase = .failed(refreshFailureMessage!)
    }

    // MARK: - Derived for the pages

    var headlineMetric: SharedSnapshot.Metric? {
        if let headlineMetricID, let chosen = snapshot?.metric(id: headlineMetricID) {
            return chosen
        }
        return snapshot?.metrics.first
    }

    var headlineRender: InsightRenderModel? {
        headlineMetric.flatMap { renders[$0.id] }
    }

    var shortlistFlags: [SharedSnapshot.Flag] {
        Array((snapshot?.flags ?? []).prefix(Self.flagShortlistCap))
    }

    var flagsContentState: WatchFlagsContentState {
        guard hasCredential else { return .needsCredential }

        let rows = shortlistFlags
        let capturedAt = flagsReceipt?.capturedAt
            ?? (rows.isEmpty ? nil : snapshot?.capturedAt)
        if let flagsRefreshFailure {
            return rows.isEmpty
                ? .failure(flagsRefreshFailure)
                : .carried(
                    rows,
                    failure: flagsRefreshFailure,
                    capturedAt: capturedAt
                )
        }
        if phase == .loading { return .loading }
        if !rows.isEmpty { return .rows(rows, capturedAt: capturedAt) }
        if let flagsReceipt { return .empty(capturedAt: flagsReceipt.capturedAt) }
        return .notChecked
    }

    // MARK: - Refresh

    private func refreshContextIsCurrent(
        generation: Int,
        adoptedRevision: UInt64
    ) -> Bool {
        generation == configurationGeneration
            && mutationCoordinator.isSettled(at: adoptedRevision)
    }

    func refresh(force: Bool = false) async {
        let generation = configurationGeneration
        let adoptedRevision = adoptedCredentialRevision
        if let operation = refreshOperations[generation] {
            await operation.value
            return
        }

        guard client != nil else {
            refreshGuidance = nil
            refreshFailure = nil
            refreshFailureMessage = nil
            flagsRefreshFailure = nil
            healthRefreshFailure = nil
            activityRefreshFailure = nil
            phase = .needsKey
            return
        }

        let attemptedAt = now()
        let freshnessReference = [lastRefreshAttemptAt, snapshot?.capturedAt]
            .compactMap { $0 }
            .max()
        if !force, let freshnessReference,
           max(0, attemptedAt.timeIntervalSince(freshnessReference)) < Self.refreshTolerance {
            phase = .ready
            return
        }
        lastRefreshAttemptAt = attemptedAt

        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(
                generation: generation,
                adoptedRevision: adoptedRevision
            )
        }
        refreshOperations[generation] = operation
        await operation.value
        refreshOperations.removeValue(forKey: generation)
    }

    private func performRefresh(
        generation: Int,
        adoptedRevision: UInt64
    ) async {
        guard await mutationCoordinator.waitUntilSettled(
            at: adoptedRevision
        ) else { return }
        guard let client else {
            refreshGuidance = nil
            refreshFailure = nil
            refreshFailureMessage = nil
            flagsRefreshFailure = nil
            healthRefreshFailure = nil
            activityRefreshFailure = nil
            phase = .needsKey
            return
        }
        if snapshot == nil { phase = .loading }

        let failures = WatchRequestFailures()

        if projectID == nil {
            // DEBUG env-key bootstrap: one identity request names the project.
            // Never reached on a hand-off credential, which carries the id.
            let me: MeResponse? = await failures.capture({
                try await client.send(PostHogAPI.me())
            })
            guard refreshContextIsCurrent(
                generation: generation, adoptedRevision: adoptedRevision
            ) else { return }
            if let project = me?.currentProject {
                guard acceptResolvedProject(
                    id: project.id,
                    name: project.name,
                    adoptedRevision: adoptedRevision
                ) else { return }
            }
        }
        guard let projectID else {
            refreshGuidance = failures.guidance
            refreshFailure = failures.failure ?? .other
            refreshFailureMessage = refreshGuidance?.message
                ?? failures.userMessage
                ?? "Couldn't resolve a project for this key."
            flagsRefreshFailure = nil
            healthRefreshFailure = nil
            activityRefreshFailure = nil
            phase = .failed(
                refreshFailureMessage ?? "Couldn't resolve a project for this key."
            )
            return
        }
        guard let projectRegion else {
            refreshGuidance = nil
            refreshFailure = .other
            refreshFailureMessage = "Couldn't resolve the PostHog endpoint for this key."
            flagsRefreshFailure = nil
            healthRefreshFailure = nil
            activityRefreshFailure = nil
            phase = .failed(refreshFailureMessage!)
            return
        }

        var reachedTheAPI = false
        var fetchedMetrics: [SharedSnapshot.Metric]?
        var freshRenders: [String: InsightRenderModel] = [:]
        var fetchedFlags: [SharedSnapshot.Flag]?
        var flagsCapturedAt: Date?
        var issues: [ErrorIssue]?
        var fetchedActivity: ActivityFeed?
        var flagsFailure: WatchSectionFailure?
        var healthFailure: WatchSectionFailure?
        var activityFailure: WatchSectionFailure?

        // 1 + 2. The pinned (or first) dashboard, cached tile results only —
        // the watch never asks PostHog to recompute anything.
        let dashboardPage: Page<DashboardSummary>? = await failures.capture({
            try await client.send(
                PostHogAPI.dashboards(projectID: projectID, budget: Self.budget)
            )
        })
        guard refreshContextIsCurrent(
            generation: generation, adoptedRevision: adoptedRevision
        ) else { return }
        if let page = dashboardPage {
            reachedTheAPI = true
            if let chosen = page.results.first(where: \.pinned) ?? page.results.first {
                let dashboard: Dashboard? = await failures.capture({
                    try await client.send(
                        PostHogAPI.dashboard(projectID: projectID, dashboardID: chosen.id)
                    )
                })
                guard refreshContextIsCurrent(
                    generation: generation, adoptedRevision: adoptedRevision
                ) else { return }
                if let dashboard {
                    var metrics: [SharedSnapshot.Metric] = []
                    for tile in dashboard.tiles {
                        guard let metric = SharedSnapshot.Metric(
                            tile: tile, dashboardID: chosen.id
                        ) else { continue }
                        metrics.append(metric)
                        if case .timeSeries = tile.renderModel {
                            freshRenders[metric.id] = tile.renderModel
                        }
                    }
                    fetchedMetrics = metrics
                }
            } else {
                fetchedMetrics = []
            }
        }

        // 3. Flags. `quickToggleAllowed` is the *iOS* per-flag opt-in, which
        // the watch has no UI to grant — written false so a watch-local widget
        // can never offer a toggle the user did not opt into.
        let flagPage: Page<FeatureFlag>? = await failures.capture(
            {
                try await client.send(
                    PostHogAPI.featureFlags(projectID: projectID, budget: Self.budget)
                )
            },
            onFailure: { flagsFailure = $0 }
        )
        guard refreshContextIsCurrent(
            generation: generation, adoptedRevision: adoptedRevision
        ) else { return }
        if let page = flagPage {
            reachedTheAPI = true
            flagsCapturedAt = now()
            fetchedFlags = page.results
                .filter { !$0.deleted && !$0.archived }
                .map {
                    SharedSnapshot.Flag(
                        id: $0.id,
                        key: $0.key,
                        active: $0.active,
                        quickToggleAllowed: false
                    )
                }
        }

        // 4. Error pulse: the budget's window, five issues by occurrences — a
        // pulse, not the phone's triage screen, and the page says so.
        // `errorTrackingIssues` takes the range as a string, so the budget's
        // own `dateFrom` is passed rather than a literal that could disagree
        // with the events feed's floor one block below.
        let errorResponse: ErrorTrackingResponse? = await failures.capture(
            {
                let data = try await client.data(for: PostHogAPI.errorTrackingIssues(
                    projectID: projectID,
                    dateFrom: Self.budget.dateFrom,
                    orderBy: "occurrences",
                    limit: Self.errorPulseLimit
                ))
                return try ErrorTrackingResponse.decode(from: data)
            },
            onFailure: { healthFailure = $0 }
        )
        guard refreshContextIsCurrent(
            generation: generation, adoptedRevision: adoptedRevision
        ) else { return }
        if let response = errorResponse {
            reachedTheAPI = true
            issues = response.issues
        }

        // 5. Activity: the kit's trimmed, budgeted feed — four columns, no
        // `properties`, the budget's window and page size. No paging.
        let activityResponse: QueryResponse? = await failures.capture(
            {
                try await client.send(
                    PostHogAPI.recentEventLines(
                        projectID: projectID,
                        budget: Self.budget,
                        now: now()
                    )
                )
            },
            onFailure: { activityFailure = $0 }
        )
        guard refreshContextIsCurrent(
            generation: generation, adoptedRevision: adoptedRevision
        ) else { return }
        if let response = activityResponse {
            reachedTheAPI = true
            // Only a query that answered replaces the carried feed. One that
            // failed leaves the previous rows and their own age in place,
            // which is the rule the snapshot follows one block below.
            fetchedActivity = ActivityFeed(
                lines: WatchActivity.lines(from: response), capturedAt: now()
            )
        }

        // A wake that found no network must not overwrite a good snapshot with
        // an empty one — the same rule the phone's publisher follows.
        guard reachedTheAPI else {
            _ = mutationCoordinator.performIfSettled(at: adoptedRevision) {
                refreshGuidance = failures.guidance
                refreshFailure = failures.failure ?? .other
                refreshFailureMessage = refreshGuidance?.message
                    ?? failures.userMessage
                    ?? "PostHog couldn't be reached."
                flagsRefreshFailure = flagsFailure
                healthRefreshFailure = healthFailure
                activityRefreshFailure = activityFailure
                if refreshFailure == .authentication {
                    // A stale metric remains useful context, but a real 401
                    // still exposes the only action that can recover.
                    phase = .failed(refreshFailureMessage ?? "Your API key was rejected.")
                } else {
                    phase = snapshot == nil
                        ? .failed(refreshFailureMessage ?? "PostHog couldn't be reached.")
                        : .ready
                }
            }
            return
        }

        let didPublish = mutationCoordinator.performIfSettled(at: adoptedRevision) {
            // A best-effort refresh may be partial: one endpoint answered while
            // another failed. Keep its recovery alongside answered sections.
            refreshGuidance = failures.guidance
            refreshFailure = failures.failure
            refreshFailureMessage = refreshGuidance?.message ?? failures.userMessage
            flagsRefreshFailure = flagsFailure
            healthRefreshFailure = healthFailure
            activityRefreshFailure = activityFailure

            // Metrics and flags merge independently with same-project carry.
            let carried = snapshot?.projectID == projectID
                && snapshot?.projectRegion == projectRegion ? snapshot : nil
            var publishedSnapshot = carried
            if fetchedMetrics != nil || fetchedFlags != nil {
                let complete = fetchedMetrics != nil && fetchedFlags != nil
                let merged = SharedSnapshot(
                    projectID: projectID,
                    projectName: projectName,
                    metrics: fetchedMetrics ?? carried?.metrics ?? [],
                    flags: fetchedFlags ?? carried?.flags ?? [],
                    ingestion: carried?.ingestion,
                    quota: carried?.quota,
                    projectRegion: projectRegion,
                    capturedAt: complete ? now() : carried?.capturedAt ?? now()
                )
                snapshot = merged
                publishedSnapshot = merged
                let answeredFlagsReceipt = flagsCapturedAt.map {
                    WatchFlagsReceipt(
                        projectID: projectID,
                        projectRegion: projectRegion,
                        capturedAt: $0
                    )
                }
                if let answeredFlagsReceipt {
                    flagsReceipt = answeredFlagsReceipt
                }
                if fetchedMetrics != nil {
                    renders = freshRenders
                }
                do {
                    try store.write(merged)
                    if let answeredFlagsReceipt {
                        try answeredFlagsReceipt.write(to: store)
                    }
                } catch {
                    // In-memory state still reflects the response. A failed
                    // receipt write degrades a later empty relaunch to
                    // `notChecked`, never to a false answered-empty state.
                }
            }
            if let fetchedActivity {
                activity = fetchedActivity.lines
                activityCapturedAt = fetchedActivity.capturedAt
                try? WatchActivity.write(fetchedActivity, to: store)
            }

            let derived = WatchHealth.derive(
                snapshot: publishedSnapshot,
                watches: watches,
                previouslyBreaching: store.breachingWatchIDs(),
                issues: issues
            )
            health = derived.health
            try? store.writeBreachingWatchIDs(derived.breaching)
            phase = refreshFailure == .authentication
                ? .failed(refreshFailureMessage ?? "Your API key was rejected.")
                : .ready
        }
        guard didPublish else { return }
        // Snapshot, activity, and breach state are three files read together by
        // complications. Reload only after every answered section has landed,
        // so the extension cannot observe a half-published refresh.
        snapshotDidChange()
    }

    /// The explicit recovery action shown with a transient refresh failure.
    /// Forced so a cached snapshot inside the ordinary 15-minute tolerance can
    /// never swallow the user's retry tap.
    func retry() async {
        explicitRefreshInFlightCount += 1
        defer { explicitRefreshInFlightCount -= 1 }
        await refresh(force: true)
    }

    // MARK: - Flag writes

    /// Watch owns a direct PATCH path, so its recovery contract must move with
    /// the same named catalog descriptor as the full client's flag writers.
    static var requiredFlagWriteScope: String {
        APIKeyScopeGuidance.optionalWriteDescriptor(for: .featureFlags).scope
    }

    /// Returns `nil` on success, or the sentence to show.
    ///
    /// The confirm dialog and the device-owner gate have both already run by
    /// the time this is called — see `FlagToggleFlow`, which is the only thing
    /// that may reach it.
    func setFlag(id: Int, active: Bool) async -> String? {
        let adoptedRevision = adoptedCredentialRevision
        guard mutationCoordinator.isSettled(at: adoptedRevision) else {
            return "The project changed before PostHog answered. Refresh and try again."
        }
        guard let client, let projectID else { return "Not signed in." }
        guard snapshot?.projectID == projectID,
              snapshot?.projectRegion == projectRegion,
              snapshot?.flag(id: id) != nil else {
            return "Refresh this project before changing a flag."
        }
        let generation = configurationGeneration
        do {
            _ = try await client.data(
                for: PostHogAPI.setFlagActive(projectID: projectID, flagID: id, active: active)
            )
        } catch {
            if let posthog = error as? PostHogError,
               case .forbidden(missingScope: nil, detail: let detail) = posthog {
                let said = detail.map { " PostHog said: \($0)" } ?? ""
                return """
                    PostHog refused the flag change and didn't say which permission was missing.\
                    \(said) If your key is missing the \(Self.requiredFlagWriteScope) scope, \
                    adding it may fix this; otherwise ask an organization admin to check your role.
                    """
            }
            return (error as? PostHogError)?.errorDescription
                ?? "PostHog refused the change."
        }
        guard refreshContextIsCurrent(
                generation: generation, adoptedRevision: adoptedRevision
              ),
              self.projectID == projectID,
              self.projectRegion == projectRegion,
              let current = snapshot,
              current.projectID == projectID,
              current.projectRegion == projectRegion else {
            return "The project changed before PostHog answered. Refresh and try again."
        }
        if current.flag(id: id) != nil {
            let flipped = current.flags.map { flag in
                flag.id == id
                    ? SharedSnapshot.Flag(
                        id: flag.id,
                        key: flag.key,
                        active: active,
                        quickToggleAllowed: flag.quickToggleAllowed
                    )
                    : flag
            }
            let updated = SharedSnapshot(
                projectID: current.projectID,
                projectName: current.projectName,
                metrics: current.metrics,
                flags: flipped,
                ingestion: current.ingestion,
                quota: current.quota,
                projectRegion: current.projectRegion,
                capturedAt: current.capturedAt
            )
            let published = mutationCoordinator.performIfSettled(at: adoptedRevision) {
                snapshot = updated
                try? store.write(updated)
            }
            guard published else {
                return "The project changed before PostHog answered. Refresh and try again."
            }
        }
        return nil
    }

    /// The live gate.
    ///
    /// Fails **closed**: a watch with no passcode cannot prove its wearer, and
    /// a bearer-key write is not worth a guess. `.deviceOwnerAuthentication`
    /// rather than `.deviceOwnerAuthenticationWithBiometrics` because a watch
    /// has no biometrics — the wrist-detect unlock is the proof it can offer.
    static let deviceOwnerGate: @Sendable (String) async -> Bool = { reason in
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: reason
        )) ?? false
    }
}
