import Foundation
import GetHogKit
import LocalAuthentication
import Observation

/// Keys the watch persists outside the snapshot file.
///
/// `UserDefaults`, not the keychain: neither of these is a secret, and the
/// session listener writes them from a nonisolated `WCSession` callback that
/// has no actor to hop to. The credential itself never comes near this type —
/// that goes through `WatchKeyTransfer.ingest(into:)` and into the keychain.
enum WatchSettings {
    static let headlineMetricKey = "watchHeadlineMetricID"
    static let projectNameKey = "watchProjectName"
    /// Set when the last hand-off carried a watch list this build could not
    /// read — a phone running a newer GetHog than the wrist. The key still
    /// landed; the thresholds did not, and the Health page has to say so
    /// rather than draw the healthy-looking empty state that would otherwise
    /// be indistinguishable from "you have no watches".
    static let watchesDegradedKey = "watchThresholdsDegraded"
}

// MARK: - Activity

/// One activity row, already trimmed to what the watch will draw.
///
/// `Codable` so the feed survives a launch. Nothing in `SharedSnapshot`
/// carries events — it is the widgets' contract and widening it is not this
/// task's to do — so the wrist keeps its own small file beside it.
struct ActivityLine: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let event: String
    let timestamp: Date?
}

/// The Activity page's hard caps, applied in one place so no view can widen
/// them.
///
/// The caps live beside the reducer rather than at the call site because the
/// view renders whatever it is handed: a cap enforced only in `WatchModel`
/// would be one refactor away from a wrist scrolling a thousand rows.
enum WatchActivity {
    /// Rows kept, whatever the response carried.
    static let maxLines = 25
    /// Characters of event name kept per line — one watch line, no wrapping.
    static let maxEventNameLength = 60

    static func lines(from response: QueryResponse) -> [ActivityLine] {
        response.rows.prefix(maxLines).enumerated().map { index, row in
            let name = row.string("event") ?? "unknown event"
            return ActivityLine(
                // `uuid` is one of the four columns `recentEventLines` selects,
                // so the fallback is for a response that came from somewhere
                // else — a fixture, an older builder — rather than the ordinary
                // case. It still has to be stable across a redraw, hence the
                // index rather than a random component.
                id: row.string("uuid")
                    ?? "\(name)|\(row.string("timestamp") ?? "")|\(index)",
                event: String(name.prefix(maxEventNameLength)),
                timestamp: row.date("timestamp")
            )
        }
    }

    // MARK: - Persistence

    /// Written and read beside the snapshot, and for the same reason the
    /// snapshot is written at all.
    ///
    /// A refresh is throttled to one every quarter of an hour, so a relaunch
    /// inside that window spends no requests — and without this the Activity
    /// page rendered "No events in the last 24 hours" over a feed it had
    /// simply not asked for. That sentence is a claim about the project; the
    /// empty in-memory array was a fact about this process. They are not the
    /// same thing, and only one of them was true. Measured on the demo: the
    /// first launch drew four rows and every relaunch inside the window drew
    /// the empty state.
    ///
    /// Its own capture time rather than the snapshot's, because the two can
    /// come from different wakes: a refresh whose events query alone failed
    /// keeps the feed it had, and stamping that with the fresh snapshot's time
    /// would age it backwards.
    static func fileURL(in store: SharedSnapshotStore) -> URL {
        store.directory.appendingPathComponent("watch-activity.json")
    }

    static func write(_ feed: ActivityFeed, to store: SharedSnapshotStore) throws {
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true
        )
        let data = try JSONEncoder.watchActivity.encode(feed)
        try data.write(to: fileURL(in: store), options: [.atomic])
    }

    /// Non-throwing: a corrupt feed must degrade to "nothing carried over"
    /// rather than stop the app from launching.
    static func read(from store: SharedSnapshotStore) -> ActivityFeed? {
        guard let data = try? Data(contentsOf: fileURL(in: store)) else { return nil }
        return try? JSONDecoder.watchActivity.decode(ActivityFeed.self, from: data)
    }
}

/// The feed with the moment it was read, so the page can age it honestly.
struct ActivityFeed: Codable, Equatable, Sendable {
    let lines: [ActivityLine]
    let capturedAt: Date
}

private extension JSONEncoder {
    /// ISO-8601 explicitly, for the reason `SharedSnapshotStore` spells it out:
    /// this file outlives the build that wrote it, and `.deferredToDate`'s
    /// reference-date doubles would drift silently if the default ever changed.
    static let watchActivity: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let watchActivity: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
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

    /// One page of dashboards, wide enough that a pinned board is very likely
    /// on it. The list endpoint has no "pinned first" ordering to ask for, so
    /// the only lever is how much of the first page we look at.
    static let dashboardsPageLimit = 20
    static let flagsPageLimit = 50
    static let errorPulseLimit = 5
    static let errorPulseWindow = "-24h"
    static let activityWindow: TimeInterval = 24 * 3600
    static let flagShortlistCap = 10
    /// A wrist glance does not need numbers fresher than this, and the budget
    /// is organisation-wide.
    static let refreshTolerance: TimeInterval = 15 * 60

    private(set) var phase: Phase
    private(set) var snapshot: SharedSnapshot?
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

    let headlineMetricID: String?
    /// True when the phone's last hand-off carried thresholds this build could
    /// not decode. See `WatchSettings.watchesDegradedKey`; `watches` is then
    /// empty for a reason the user can act on, and the Health page names it.
    let watchesDegraded: Bool
    /// Confirms device ownership before a flag write. Injected: live is the
    /// `LAContext` gate below; demo and tests substitute their own verdict, so
    /// no test has to satisfy a passcode prompt.
    let authenticate: @Sendable (String) async -> Bool

    private let client: PostHogClient?
    private var projectID: Int?
    private var projectName: String
    private let watches: [MetricWatch]
    private let store: SharedSnapshotStore
    private let now: @Sendable () -> Date

    init(
        credential: StoredCredential?,
        projectName: String?,
        headlineMetricID: String?,
        watches: [MetricWatch],
        transport: any HTTPTransport,
        store: SharedSnapshotStore,
        authenticate: @escaping @Sendable (String) async -> Bool,
        watchesDegraded: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = credential.map {
            PostHogClient(
                auth: PersonalKeyAuthProvider(key: $0.key, region: $0.region),
                transport: transport
            )
        }
        self.projectID = credential?.projectID
        self.projectName = projectName ?? "PostHog"
        self.headlineMetricID = headlineMetricID
        self.watches = watches
        self.store = store
        self.authenticate = authenticate
        self.watchesDegraded = watchesDegraded
        self.now = now
        let carried = store.loadOrNil()
        self.snapshot = carried
        if let feed = WatchActivity.read(from: store) {
            self.activity = feed.lines
            self.activityCapturedAt = feed.capturedAt
        }
        self.phase = credential == nil ? .needsKey : Self.idlePhase(for: carried)
        if carried != nil {
            health = WatchHealth.derive(
                snapshot: carried,
                watches: watches,
                previouslyBreaching: store.breachingWatchIDs(),
                issues: nil
            ).health
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
        let defaults = UserDefaults.standard
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
                authenticate: { _ in true }
            )
        }
        var credential = try? KeychainTokenStore().load()
        #if DEBUG
        if credential == nil,
           let key = ProcessInfo.processInfo.environment["GETHOG_API_KEY"],
           !key.isEmpty {
            // No projectID: `refresh` resolves it through `/users/@me/` once.
            credential = StoredCredential(key: key, region: .usCloud)
        }
        #endif
        return WatchModel(
            credential: credential,
            projectName: defaults.string(forKey: WatchSettings.projectNameKey),
            headlineMetricID: defaults.string(forKey: WatchSettings.headlineMetricKey),
            watches: SharedSnapshotStore.shared.metricWatches(),
            transport: URLSessionTransport(),
            store: .shared,
            authenticate: WatchModel.deviceOwnerGate,
            watchesDegraded: defaults.bool(forKey: WatchSettings.watchesDegradedKey)
        )
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

    // MARK: - Refresh

    func refresh(force: Bool = false) async {
        guard let client else {
            phase = .needsKey
            return
        }
        if !force, let snapshot,
           snapshot.staleness(now: now()) < Self.refreshTolerance {
            phase = .ready
            return
        }
        if snapshot == nil { phase = .loading }

        if projectID == nil {
            // DEBUG env-key bootstrap: one identity request names the project.
            // Never reached on a hand-off credential, which carries the id.
            if let me: MeResponse = try? await client.send(PostHogAPI.me()),
               let project = me.currentProject {
                projectID = project.id
                projectName = project.name
            }
        }
        guard let projectID else {
            phase = .failed("Couldn't resolve a project for this key.")
            return
        }

        var reachedTheAPI = false
        var metrics: [SharedSnapshot.Metric] = []
        var freshRenders: [String: InsightRenderModel] = [:]
        var flags: [SharedSnapshot.Flag] = []
        var issues: [ErrorIssue]?
        var fetchedActivity: ActivityFeed?

        // 1 + 2. The pinned (or first) dashboard, cached tile results only —
        // the watch never asks PostHog to recompute anything.
        if let page: Page<DashboardSummary> = try? await client.send(
            PostHogAPI.dashboards(projectID: projectID, limit: Self.dashboardsPageLimit)
        ) {
            reachedTheAPI = true
            if let chosen = page.results.first(where: \.pinned) ?? page.results.first,
               let dashboard: Dashboard = try? await client.send(
                   PostHogAPI.dashboard(projectID: projectID, dashboardID: chosen.id)
               ) {
                for tile in dashboard.tiles {
                    guard let metric = SharedSnapshot.Metric(tile: tile, dashboardID: chosen.id)
                    else { continue }
                    metrics.append(metric)
                    if case .timeSeries = tile.renderModel {
                        freshRenders[metric.id] = tile.renderModel
                    }
                }
            }
        }

        // 3. Flags. `quickToggleAllowed` is the *iOS* per-flag opt-in, which
        // the watch has no UI to grant — written false so a watch-local widget
        // can never offer a toggle the user did not opt into.
        if let page: Page<FeatureFlag> = try? await client.send(
            PostHogAPI.featureFlags(projectID: projectID, limit: Self.flagsPageLimit)
        ) {
            reachedTheAPI = true
            flags = page.results
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

        // 4. Error pulse: last 24 h, five issues by occurrences — a pulse, not
        // the phone's triage screen, and the page says so.
        if let data = try? await client.data(for: PostHogAPI.errorTrackingIssues(
            projectID: projectID,
            dateFrom: Self.errorPulseWindow,
            orderBy: "occurrences",
            limit: Self.errorPulseLimit
        )), let response = try? ErrorTrackingResponse.decode(from: data) {
            reachedTheAPI = true
            issues = response.issues
        }

        // 5. Activity: the kit's trimmed feed — four columns, no `properties`,
        // one bounded window, a caller-written LIMIT. No paging.
        if let response: QueryResponse = try? await client.send(
            PostHogAPI.recentEventLines(
                projectID: projectID,
                limit: WatchActivity.maxLines,
                since: now().addingTimeInterval(-Self.activityWindow)
            )
        ) {
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
            phase = snapshot == nil
                ? .failed("PostHog couldn't be reached.")
                : .ready
            return
        }

        let fresh = SharedSnapshot(
            projectID: projectID,
            projectName: projectName,
            metrics: metrics,
            flags: flags,
            capturedAt: now()
        )
        snapshot = fresh
        renders = freshRenders
        try? store.write(fresh)
        if let fetchedActivity {
            activity = fetchedActivity.lines
            activityCapturedAt = fetchedActivity.capturedAt
            try? WatchActivity.write(fetchedActivity, to: store)
        }

        let derived = WatchHealth.derive(
            snapshot: fresh,
            watches: watches,
            previouslyBreaching: store.breachingWatchIDs(),
            issues: issues
        )
        health = derived.health
        try? store.writeBreachingWatchIDs(derived.breaching)
        phase = .ready
    }

    // MARK: - Flag writes

    /// Returns `nil` on success, or the sentence to show.
    ///
    /// The confirm dialog and the device-owner gate have both already run by
    /// the time this is called — see `FlagToggleFlow`, which is the only thing
    /// that may reach it.
    func setFlag(id: Int, active: Bool) async -> String? {
        guard let client, let projectID else { return "Not signed in." }
        do {
            _ = try await client.data(
                for: PostHogAPI.setFlagActive(projectID: projectID, flagID: id, active: active)
            )
        } catch {
            return (error as? PostHogError)?.errorDescription
                ?? "PostHog refused the change."
        }
        if let current = snapshot {
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
                capturedAt: current.capturedAt
            )
            snapshot = updated
            try? store.write(updated)
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
