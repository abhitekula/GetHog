import Foundation
import Observation
import GetHogKit
import WidgetKit

/// Session-wide state: who we are, which project we're looking at, and what the
/// current credential is actually allowed to do.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var client: PostHogClient?
    private(set) var me: MeResponse?
    private(set) var capabilities: CapabilityReport?
    private(set) var connectionError: String?

    var projects: [Project] = []
    var selectedProject: Project? {
        didSet {
            guard let selectedProject, selectedProject.id != oldValue?.id else { return }
            persistSelectedProject(selectedProject.id)
            Task { await refreshCapabilities() }
        }
    }

    let store: any CredentialStoring
    let cache = ResponseCache()
    private let governor = RateLimitGovernor()
    private let transport: any HTTPTransport

    init(
        store: any CredentialStoring = KeychainTokenStore(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.store = store
        self.transport = transport
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard let credential = try? store.load() else {
            phase = .onboarding
            return
        }
        do {
            try await activate(credential: credential)
        } catch {
            // A stored key that no longer works should land the user on
            // onboarding with an explanation, not an empty dashboard.
            connectionError = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
            phase = .onboarding
        }
    }

    /// Validates a credential and, on success, becomes the active session.
    func connect(key: String, region: PostHogRegion) async throws {
        let credential = StoredCredential(key: key, region: region)
        try await activate(credential: credential)
        try store.save(credential)
    }

    private func activate(credential: StoredCredential) async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: credential.key, region: credential.region),
            transport: transport,
            governor: governor
        )

        let me: MeResponse = try await client.send(PostHogAPI.me())

        self.client = client
        self.me = me
        self.projects = me.projects.isEmpty
            ? [me.currentProject].compactMap { $0 }
            : me.projects

        let storedID = credential.projectID ?? loadPersistedProjectID()
        self.selectedProject = projects.first { $0.id == storedID }
            ?? me.currentProject
            ?? projects.first

        self.connectionError = nil
        self.phase = .ready

        await refreshCapabilities()
        await publishWidgetSnapshot()
    }

    func refreshCapabilities() async {
        guard let client, let project = selectedProject else { return }
        capabilities = await ScopePreflight(client: client).run(projectID: project.id)
    }

    // MARK: - Widget snapshot

    /// Publishes the values widgets and Control Center read.
    ///
    /// Extensions never call the API themselves — the rate-limit budget is
    /// organisation-wide and shared with the user's own integrations, so N
    /// widgets each fetching would multiply request volume against a budget that
    /// isn't ours. Everything they show is computed here, once, and written to
    /// the App Group container.
    ///
    /// Returns whether anything was actually fetched, which is what a background
    /// wake reports back to `BGTaskScheduler`.
    @discardableResult
    func publishWidgetSnapshot() async -> Bool {
        guard let client, let project = selectedProject else { return false }
        return await publish(using: client, projectID: project.id, projectName: project.name)
    }

    /// The fetch itself, decoupled from the session so a background wake can run
    /// it against a client it built for one call without disturbing `phase`,
    /// `selectedProject`, or anything else the UI observes.
    private func publish(
        using client: PostHogClient,
        projectID: Int,
        projectName: String
    ) async -> Bool {
        var metrics: [SharedSnapshot.Metric] = []
        var flags: [SharedSnapshot.Flag] = []
        var reachedTheAPI = false

        // Reuse the dashboard the user pinned; its tiles already carry results,
        // so this costs one request rather than one per metric.
        if let summaries: Page<DashboardSummary> = try? await client.send(
            PostHogAPI.dashboards(projectID: projectID, limit: 50)
        ) {
            reachedTheAPI = true
            // The pinned dashboard is already being resolved for the widgets, so
            // handing it to the home screen menu as well costs no request. Only
            // a genuinely pinned one is recorded — the fallback below is "the
            // first dashboard", which is not the same claim.
            if let pinned = summaries.results.first(where: \.pinned) {
                QuickActions.recordPinnedDashboard(
                    id: pinned.id,
                    title: pinned.title,
                    projectID: projectID
                )
                // The project this publish is for, not the selected one: a
                // background wake runs with no session, and rebuilding the menu
                // for a nil project would empty the home screen instead.
                QuickActions.refresh(projectID: projectID)
            }
            if let pinned = summaries.results.first(where: \.pinned) ?? summaries.results.first,
               let dashboard: Dashboard = try? await client.send(
                   PostHogAPI.dashboard(projectID: projectID, dashboardID: pinned.id)
               ) {
                metrics = dashboard.tiles.compactMap(Self.metric(from:))
            }
        }

        if let page: Page<FeatureFlag> = try? await client.send(
            PostHogAPI.featureFlags(projectID: projectID, limit: 100)
        ) {
            reachedTheAPI = true
            flags = page.results
                .filter { !$0.deleted && !$0.archived }
                .map {
                    SharedSnapshot.Flag(
                        id: $0.id,
                        key: $0.key,
                        active: $0.active,
                        // Only an explicit in-app opt-in exposes a flag to
                        // Control Center or an interactive widget.
                        quickToggleAllowed: FlagQuickToggle.isAllowed(flagID: $0.id)
                    )
                }
        }

        // A wake that found no network must not overwrite a good snapshot with
        // an empty one: the widget would go blank and claim to be current,
        // which is worse than showing older numbers with an honest age on them.
        guard reachedTheAPI || SharedSnapshotStore.shared.loadOrNil() == nil else { return false }

        let snapshot = SharedSnapshot(
            projectID: projectID,
            projectName: projectName,
            metrics: metrics,
            flags: flags,
            capturedAt: Date()
        )
        try? SharedSnapshotStore.shared.write(snapshot)
        // Every publish evaluates, foreground included. A background wake is the
        // usual trigger, but a user who opens the app and watches a metric
        // recover would otherwise leave its watch latched, and the next real
        // crossing would pass in silence.
        await MetricAlertDelivery.evaluate(snapshot: snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        return reachedTheAPI
    }

    // MARK: - Background refresh

    /// Whether a background wake is worth scheduling at all.
    var hasStoredCredential: Bool { (try? store.load()) != nil }

    /// When the widgets' data was last written, wherever it was written from.
    ///
    /// The snapshot is its own record of freshness, so the refresh cadence needs
    /// no separate bookkeeping that could disagree with it.
    var lastSnapshotDate: Date? { SharedSnapshotStore.shared.loadOrNil()?.capturedAt }

    /// One coalesced refresh for a background wake.
    ///
    /// *One* refresh per wake, not one per widget: a single dashboard fetch
    /// feeds every metric the extensions render, exactly as it does in the
    /// foreground, and everything still passes the rate-limit governor.
    ///
    /// A background launch is a fresh process with no session, and rebuilding
    /// one the way `bootstrap()` does would cost an identity request plus four
    /// scope probes before the first useful byte. None of that tells a wake
    /// anything: the last snapshot already names the project, so the client is
    /// rebuilt from the stored credential alone and the wake costs exactly the
    /// three requests the refresh needs.
    func performBackgroundRefresh(now: Date = Date()) async -> Bool {
        let lastRefreshedAt = lastSnapshotDate

        // The app may have been in the foreground minutes ago and published a
        // snapshot itself. Then this wake has nothing to add, and the cheapest
        // correct thing it can do is nothing.
        guard BackgroundRefreshPolicy.isDue(lastRefreshedAt: lastRefreshedAt, now: now) else {
            return true
        }

        if let client, let project = selectedProject {
            return await publish(using: client, projectID: project.id, projectName: project.name)
        }

        guard let credential = try? store.load() else { return false }
        // Without a previous snapshot there is no project to refresh and no
        // widget showing anything to correct. Discovering one would cost six
        // requests to learn what the next foreground launch learns for free.
        guard let previous = SharedSnapshotStore.shared.loadOrNil() else { return false }

        // Built here rather than stored: the wake must not leave a half-started
        // session behind for the next foreground launch to inherit. It shares
        // this model's governor, so background traffic counts against the same
        // budget and shows up in the Settings meter like everything else.
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: credential.key, region: credential.region),
            transport: transport,
            governor: governor
        )
        return await publish(
            using: client,
            projectID: previous.projectID,
            projectName: previous.projectName
        )
    }

    /// Reduces a dashboard tile to a single headline figure, when it has one.
    private static func metric(from tile: Tile) -> SharedSnapshot.Metric? {
        guard let insight = tile.insight else { return nil }

        switch tile.renderModel {
        case .bigNumber(let number):
            return .init(id: String(insight.id), title: tile.title, value: number.value,
                         unit: nil, previous: nil, sparkline: [])
        case .timeSeries(let series, _):
            guard let first = series.first, !first.points.isEmpty else { return nil }
            let values = first.points.map(\.value)
            return .init(id: String(insight.id), title: tile.title,
                         value: values.last ?? 0, unit: nil,
                         previous: values.count > 1 ? values[values.count - 2] : nil,
                         sparkline: Array(values.suffix(24)))
        case .barValue(let bars):
            guard let top = bars.first else { return nil }
            return .init(id: String(insight.id), title: tile.title, value: top.value,
                         unit: top.label, previous: nil, sparkline: bars.map(\.value))
        case .funnel(let groups):
            guard let group = groups.first, let last = group.steps.last else { return nil }
            return .init(id: String(insight.id), title: tile.title, value: last.count,
                         unit: nil, previous: group.steps.first?.count,
                         sparkline: group.steps.map(\.count))
        default:
            // Retention grids, paths and stickiness have no single headline
            // figure, so they are simply not offered as widget metrics.
            return nil
        }
    }

    // MARK: - Intent hand-off

    /// Applies work an out-of-process intent could not finish itself.
    ///
    /// The extension has no keychain access, no rate-limit governor and nowhere
    /// to show a 403, so a flag toggle requested from a widget is recorded and
    /// completed here instead.
    func consumePendingIntentWork() async {
        if let pending = SharedSnapshotStore.shared.pendingFlagWrite() {
            SharedSnapshotStore.shared.clearPendingFlagWrite()
            guard FlagQuickToggle.isAllowed(flagID: pending.flagID) else { return }
            await setFlag(id: pending.flagID, active: pending.desiredActive)
        }
    }

    func setFlag(id: Int, active: Bool) async {
        guard let client, let project = selectedProject else { return }
        _ = try? await client.data(
            for: PostHogAPI.setFlagActive(projectID: project.id, flagID: id, active: active)
        )
        await publishWidgetSnapshot()
    }

    func signOut() {
        try? store.clear()
        // A pending wake would otherwise launch the app in the background with
        // nothing to authenticate as, teaching iOS that its requests are futile.
        BackgroundRefresh.cancel()
        // Dashboard and flag names are project data — they name a customer's
        // business — and must not survive on the home screen past the credential
        // that could read them.
        QuickActions.clear()
        Task { await cache.clear() }
        client = nil
        me = nil
        capabilities = nil
        projects = []
        selectedProject = nil
        phase = .onboarding
    }

    // MARK: - Convenience

    var projectID: Int? { selectedProject?.id }

    func isAvailable(_ capability: Capability) -> Bool {
        capabilities?.isAvailable(capability) ?? true
    }

    func lockedScope(for capability: Capability) -> String? {
        guard case .locked(let scope) = capabilities?.status(capability) else { return nil }
        return scope ?? capability.requiredScopes.joined(separator: ", ")
    }

    /// Deep link into the equivalent page of the web console.
    func webURL(path: String) -> URL? {
        guard let client, let project = selectedProject else { return nil }
        return client.host
            .appendingPathComponent("project/\(project.id)")
            .appendingPathComponent(path)
    }

    /// What happened when a link asked for a particular project.
    enum ProjectSwitch: Equatable, Sendable {
        /// Already looking at it; nothing moved.
        case current
        /// Switched, and the new project's name, so the caller can say which.
        case switched(name: String)
        /// This credential has no such project. Never resolved to anything else.
        case inaccessible
    }

    /// Moves to the project a link named, or refuses.
    ///
    /// The refusal is the point. A link carries a project id, and the id it
    /// carries is routinely not the one on screen — a colleague's link, a link
    /// from a week ago, a link from the other environment. Falling back to the
    /// selected project would render that link's dashboard id against a
    /// *different* project's data: the same numbers-under-the-wrong-name bug the
    /// project switcher sits on every screen to prevent. So an id this key
    /// cannot see stops here and is reported.
    func selectProject(id: Int) -> ProjectSwitch {
        if id == selectedProject?.id { return .current }
        guard let project = projects.first(where: { $0.id == id }) else { return .inaccessible }
        selectedProject = project
        return .switched(name: project.name)
    }

    /// Picks up a project chosen outside the app — by a Focus filter or an
    /// intent — without clobbering the user's choice if it hasn't changed.
    func adoptExternallySelectedProject() {
        guard let id = IntentDependencies.storedProjectID(),
              id != selectedProject?.id,
              let project = projects.first(where: { $0.id == id })
        else { return }
        selectedProject = project
    }

    private func persistSelectedProject(_ id: Int) {
        // Written to both stores: the app reads `.standard`, while intents and
        // widgets run in other processes and can only see the App Group.
        UserDefaults.standard.set(id, forKey: "selectedProjectID")
        IntentDependencies.persistSelectedProject(id)
        Task {
            await publishWidgetSnapshot()
            await SpotlightIndexer.reindex(projectID: id)
        }
    }

    private func loadPersistedProjectID() -> Int? {
        let id = UserDefaults.standard.integer(forKey: "selectedProjectID")
        return id == 0 ? nil : id
    }
}
