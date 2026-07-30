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
    func publishWidgetSnapshot() async {
        guard let client, let project = selectedProject else { return }

        var metrics: [SharedSnapshot.Metric] = []
        var flags: [SharedSnapshot.Flag] = []

        // Reuse the dashboard the user pinned; its tiles already carry results,
        // so this costs one request rather than one per metric.
        if let summaries: Page<DashboardSummary> = try? await client.send(
            PostHogAPI.dashboards(projectID: project.id, limit: 50)
        ), let pinned = summaries.results.first(where: \.pinned) ?? summaries.results.first,
           let dashboard: Dashboard = try? await client.send(
               PostHogAPI.dashboard(projectID: project.id, dashboardID: pinned.id)
           ) {
            metrics = dashboard.tiles.compactMap(Self.metric(from:))
        }

        if let page: Page<FeatureFlag> = try? await client.send(
            PostHogAPI.featureFlags(projectID: project.id, limit: 100)
        ) {
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

        let snapshot = SharedSnapshot(
            projectID: project.id,
            projectName: project.name,
            metrics: metrics,
            flags: flags,
            capturedAt: Date()
        )
        try? SharedSnapshotStore.shared.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
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
