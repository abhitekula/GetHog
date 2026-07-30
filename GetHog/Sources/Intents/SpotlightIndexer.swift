import AppIntents
import CoreSpotlight
import Foundation

/// Publishes the current project's dashboards, insights and feature flags to
/// Spotlight.
///
/// Because the entities are `IndexedEntity`, one call hands Spotlight the same
/// titles, subtitles and keywords that Shortcuts and Siri already use — there is
/// no second copy of the metadata to drift.
///
/// Nothing here ever throws into the UI. Spotlight is a convenience: on a device
/// where indexing is disabled, or during the window after a restore when the
/// index is rebuilding, the right behaviour is to skip quietly, not to surface a
/// failure the user can't act on.
enum SpotlightIndexer {

    private static let log = IntentDependencies.log

    /// Called by the app after a project switch or a manual refresh.
    ///
    /// Three CRUD list calls, so it must stay tied to those explicit moments —
    /// the rate-limit budget is organisation-wide and shared with the user's own
    /// integrations.
    static func reindex(projectID: Int) async {
        guard CSSearchableIndex.isIndexingAvailable() else {
            log.debug("Spotlight indexing unavailable; skipping reindex.")
            return
        }

        // Fetch before clearing. Clearing first would leave Spotlight empty for
        // as long as the user is offline, turning a network blip into missing
        // search results.
        let dashboards = await fetch("dashboards") {
            try await PostHogEntityFetch.dashboards(projectID: projectID)
        }
        let insights = await fetch("insights") {
            try await PostHogEntityFetch.insights(projectID: projectID)
        }
        let flags = await fetch("flags") {
            try await PostHogEntityFetch.flags(projectID: projectID)
        }

        // Replace per type, and only where a fetch actually succeeded. The
        // previous project's items must go — Spotlight offering a dashboard the
        // active project can't open is worse than offering nothing — but a
        // failed fetch is not evidence that anything should be removed.
        if let dashboards {
            await delete(DashboardEntity.self)
            await index(dashboards)
        }
        if let insights {
            await delete(InsightEntity.self)
            await index(insights)
        }
        if let flags {
            await delete(FeatureFlagEntity.self)
            await index(flags)
        }
    }

    /// Removes everything GetHog has published. Called on sign-out and before
    /// each reindex.
    static func deindexAll() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        await delete(DashboardEntity.self)
        await delete(InsightEntity.self)
        await delete(FeatureFlagEntity.self)
    }

    /// `nil` means the fetch failed, which is different from "this project has
    /// none" — only the latter should clear anything.
    private static func fetch<Entity: IndexedEntity>(
        _ label: String,
        _ body: () async throws -> [Entity]
    ) async -> [Entity]? {
        do {
            return try await body()
        } catch {
            log.error("Spotlight: could not load \(label, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func index<Entity: IndexedEntity>(_ entities: [Entity]) async {
        guard !entities.isEmpty else { return }
        do {
            try await CSSearchableIndex.default().indexAppEntities(entities)
        } catch {
            log.error("Spotlight: could not index \(entities.count) items — \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func delete<Entity: IndexedEntity>(_ type: Entity.Type) async {
        do {
            try await CSSearchableIndex.default().deleteAppEntities(ofType: type)
        } catch {
            log.error("Spotlight: could not clear \(String(describing: type), privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }
}
