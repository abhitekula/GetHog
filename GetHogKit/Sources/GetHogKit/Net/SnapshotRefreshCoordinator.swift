import Foundation

public struct SnapshotPinnedDashboard: Sendable, Equatable {
    public let id: Int
    public let title: String

    public init(id: Int, title: String) {
        self.id = id
        self.title = title
    }
}

public enum SnapshotRefreshFailure: String, Codable, Sendable, Equatable {
    case offline
    case unauthorized
    case forbidden
    case unavailable
    case expired
}

public enum SnapshotRefreshResult: Sendable, Equatable {
    case refreshed(SharedSnapshot, pinnedDashboard: SnapshotPinnedDashboard?)
    case current(SharedSnapshot?)
    case coalesced(SharedSnapshot)
    case failed(SnapshotRefreshFailure, retained: SharedSnapshot?)
    case superseded
}

public struct SnapshotRefreshCoordinator: Sendable {
    public static let ingestionWindow: IngestionWarningWindow = .sevenDays

    public let store: SharedSnapshotStore
    public let leases: SnapshotRefreshLeaseStore

    public init(store: SharedSnapshotStore) {
        self.store = store
        self.leases = SnapshotRefreshLeaseStore(directory: store.directory)
    }

    public func refresh(
        trigger: SnapshotRefreshTrigger,
        client: PostHogClient,
        scope: SnapshotRefreshScope,
        now: Date = Date(),
        quickToggleAllowed: @escaping @Sendable (Int) -> Bool,
        isAuthorized: @escaping @Sendable () async -> Bool
    ) async -> SnapshotRefreshResult {
        var previous = store.loadOrNil()
        if let existing = previous,
           existing.projectID != scope.projectID
            || existing.projectRegion != scope.region
            || existing.authSessionID != scope.authSessionID {
            store.clearProjectData()
            previous = nil
        }

        guard SnapshotRefreshPolicy.shouldRefresh(
            trigger: trigger,
            capturedAt: previous?.capturedAt,
            now: now
        ) else {
            return .current(previous)
        }
        guard await isAuthorized() else { return .superseded }

        guard let lease = leases.acquire(scope: scope, trigger: trigger, now: now) else {
            if trigger == .manualWidget || trigger == .foreground {
                return await waitForMatchingRefresh(previous: previous, scope: scope)
            }
            return .current(previous)
        }
        defer { leases.release(token: lease.token) }

        var firstFailure: SnapshotRefreshFailure?
        var reachedTheAPI = false
        var metrics: [SharedSnapshot.Metric] = []
        var metricSource: SharedSnapshot.MetricSource = .unknown
        var flags: [SharedSnapshot.Flag] = []
        var pinnedDashboard: SnapshotPinnedDashboard?

        var summaries: Page<DashboardSummary>?
        do {
            summaries = try await client.send(
                PostHogAPI.dashboards(projectID: scope.projectID, limit: 50)
            )
            reachedTheAPI = true
        } catch {
            firstFailure = firstFailure ?? Self.failure(from: error)
        }
        guard await isAuthorized() else { return .superseded }

        if let summaries {
            let pinned = summaries.results.first(where: \.pinned)
            if let pinned {
                pinnedDashboard = SnapshotPinnedDashboard(id: pinned.id, title: pinned.title)
            }
            if let dashboardSummary = pinned ?? summaries.results.first {
                metricSource = pinned == nil ? .deterministicFallback : .pinnedDashboard
                do {
                    let dashboard: Dashboard = try await client.send(
                        PostHogAPI.dashboard(
                            projectID: scope.projectID,
                            dashboardID: dashboardSummary.id
                        )
                    )
                    metrics = dashboard.tiles.compactMap {
                        SharedSnapshot.Metric(tile: $0, dashboardID: dashboardSummary.id)
                    }
                    reachedTheAPI = true
                } catch {
                    firstFailure = firstFailure ?? Self.failure(from: error)
                }
                guard await isAuthorized() else { return .superseded }
            }
        }

        do {
            let page: Page<FeatureFlag> = try await client.send(
                PostHogAPI.featureFlags(projectID: scope.projectID, limit: 100)
            )
            flags = page.results
                .filter { !$0.deleted && !$0.archived }
                .map {
                    SharedSnapshot.Flag(
                        id: $0.id,
                        key: $0.key,
                        active: $0.active,
                        quickToggleAllowed: quickToggleAllowed($0.id)
                    )
                }
            reachedTheAPI = true
        } catch {
            firstFailure = firstFailure ?? Self.failure(from: error)
        }
        guard await isAuthorized() else { return .superseded }

        var ingestion = previous?.ingestion
        do {
            let data = try await client.data(
                for: PostHogAPI.ingestionWarnings(
                    projectID: scope.projectID,
                    window: Self.ingestionWindow
                )
            )
            let warnings = try IngestionWarning.decodeList(from: data)
            ingestion = SharedSnapshot.IngestionDigest(
                warnings: warnings,
                window: Self.ingestionWindow,
                capturedAt: now
            )
            reachedTheAPI = true
        } catch {
            firstFailure = firstFailure ?? Self.failure(from: error)
        }
        guard await isAuthorized() else { return .superseded }

        var quota = previous?.quota
        if SharedSnapshot.QuotaDigest.isDue(previous: quota, now: now) {
            do {
                let limits: QuotaLimits = try await client.send(
                    PostHogAPI.quotaLimits(projectID: scope.projectID)
                )
                quota = SharedSnapshot.QuotaDigest(limits, capturedAt: now)
                reachedTheAPI = true
            } catch {
                firstFailure = firstFailure ?? Self.failure(from: error)
            }
            guard await isAuthorized() else { return .superseded }
        }

        guard reachedTheAPI else {
            let failure = firstFailure ?? .unavailable
            recordStatus(at: now, failure: failure)
            return .failed(failure, retained: previous)
        }
        guard await isAuthorized() else { return .superseded }

        let refreshed = SharedSnapshot(
            projectID: scope.projectID,
            projectName: scope.projectName,
            metrics: metrics,
            metricSource: metricSource,
            flags: flags,
            ingestion: ingestion,
            quota: quota,
            projectRegion: scope.region,
            authSessionID: scope.authSessionID,
            capturedAt: now
        )
        do {
            try store.write(refreshed)
        } catch {
            recordStatus(at: now, failure: .unavailable)
            return .failed(.unavailable, retained: previous)
        }
        recordStatus(at: now, failure: nil)
        return .refreshed(refreshed, pinnedDashboard: pinnedDashboard)
    }

    private func waitForMatchingRefresh(
        previous: SharedSnapshot?,
        scope: SnapshotRefreshScope
    ) async -> SnapshotRefreshResult {
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            guard leases.current() == nil else { continue }
            if let snapshot = store.loadOrNil(),
               snapshot.projectID == scope.projectID,
               snapshot.projectRegion == scope.region,
               snapshot.authSessionID == scope.authSessionID,
               snapshot.capturedAt != previous?.capturedAt {
                return .coalesced(snapshot)
            }
            return .failed(.expired, retained: previous)
        }
        return .failed(.expired, retained: previous)
    }

    private static func failure(from error: any Error) -> SnapshotRefreshFailure {
        guard let postHog = error as? PostHogError else { return .unavailable }
        switch postHog {
        case .network, .transport:
            return .offline
        case .unauthorized:
            return .unauthorized
        case .forbidden, .accessDenied:
            return .forbidden
        default:
            return .unavailable
        }
    }

    private func recordStatus(at date: Date, failure: SnapshotRefreshFailure?) {
        try? store.writeSnapshotRefreshStatus(SnapshotRefreshStatus(
            attemptedAt: date,
            failure: failure
        ))
    }
}
