import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Shared result-surface state")
struct ResultSurfaceStateTests {

    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("An unresolved result is loading rather than empty")
    func unresolvedIsLoading() {
        let state = ResultSurfaceState.resolve(
            lastSuccess: nil,
            isLoading: false,
            failure: nil
        )

        #expect(state == .loading)
        #expect(state.completedFreshness == nil)
        #expect(!state.ownsSearch)
    }

    @Test("A failed first load has no freshness or search ownership")
    func initialFailure() {
        let failure = LoadFailure(summary: "The result could not be loaded.")
        let state = ResultSurfaceState.resolve(
            lastSuccess: nil,
            isLoading: false,
            failure: failure
        )

        #expect(state == .failed(failure))
        #expect(state.completedFreshness == nil)
        #expect(!state.ownsSearch)
    }

    @Test("A successful empty response is dated and is not searchable")
    func successfulEmpty() {
        let state = ResultSurfaceState.resolve(
            lastSuccess: .init(content: .empty, updatedAt: updatedAt),
            isLoading: false,
            failure: nil
        )

        #expect(state == .empty(updatedAt: updatedAt))
        #expect(state.completedFreshness == .current(updatedAt))
        #expect(!state.ownsSearch)
    }

    @Test("A populated response is dated and owns search")
    func populated() {
        let state = ResultSurfaceState.resolve(
            lastSuccess: .init(content: .populated, updatedAt: updatedAt),
            isLoading: false,
            failure: nil
        )

        #expect(state == .populated(updatedAt: updatedAt))
        #expect(state.completedFreshness == .current(updatedAt))
        #expect(state.ownsSearch)
    }

    @Test("Refreshing last-good content does not claim completed freshness")
    func refreshingLastGood() {
        let success = ResultSuccess(content: .populated, updatedAt: updatedAt)
        let state = ResultSurfaceState.resolve(
            lastSuccess: success,
            isLoading: true,
            failure: LoadFailure(summary: "An older failure must not win while retrying.")
        )

        #expect(state == .refreshing(success))
        #expect(state.completedFreshness == nil)
        #expect(state.ownsSearch)
    }

    @Test("A failed refresh preserves and labels the last-good result as stale")
    func staleLastGood() {
        let success = ResultSuccess(content: .populated, updatedAt: updatedAt)
        let failure = LoadFailure(summary: "The refresh failed.")
        let state = ResultSurfaceState.resolve(
            lastSuccess: success,
            isLoading: false,
            failure: failure
        )

        #expect(state == .stale(success, failure: failure))
        #expect(state.completedFreshness == .stale(updatedAt))
        #expect(state.ownsSearch)
    }

    @Test("A success from another request scope is never retained")
    func crossScopeSuccessIsRejected() {
        let previous = ResultSuccess(
            content: .populated,
            updatedAt: updatedAt,
            scope: .init(["project:1", "window:7d"])
        )
        let failure = LoadFailure(summary: "The new request failed.")

        let state = ResultSurfaceState.resolve(
            lastSuccess: previous,
            currentScope: .init(["project:2", "window:7d"]),
            isLoading: false,
            failure: failure
        )

        #expect(state == .failed(failure))
        #expect(state.presentation == nil)
        #expect(state.completedFreshness == nil)
    }

    @Test("Only the latest invocation for a request authority may publish")
    func latestInvocationWins() {
        var authority = ResultRequestAuthority()
        let scope = ResultScope(["host:https://example.test", "project:1", "auth:synthetic"])
        let first = authority.begin(scope: scope)
        let second = authority.begin(scope: scope)

        #expect(!authority.owns(first))
        #expect(authority.owns(second))
        let obsoleteDidFinish = authority.finish(first)
        let currentDidFinish = authority.finish(second)
        #expect(!obsoleteDidFinish)
        #expect(currentDidFinish)
        #expect(!authority.isLoading)
    }

    @Test("Result scopes include host, project, and credential session")
    func resultScopesIncludeSecurityAuthority() {
        let authSession = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let replacementSession = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let us = ResourceRequestAuthority(
            projectID: 7,
            region: .usCloud,
            authSessionID: authSession
        )
        let eu = ResourceRequestAuthority(
            projectID: 7,
            region: .euCloud,
            authSessionID: authSession
        )
        let replacement = ResourceRequestAuthority(
            projectID: 7,
            region: .usCloud,
            authSessionID: replacementSession
        )

        #expect(ResultScope.request(authority: us) != ResultScope.request(authority: eu))
        #expect(ResultScope.request(authority: us) != ResultScope.request(authority: replacement))
    }

    @Test("Refreshing and stale successful-empty results keep the empty presentation")
    func retainedEmptyPresentation() {
        let success = ResultSuccess(content: .empty, updatedAt: updatedAt)

        #expect(ResultSurfaceState.refreshing(success).presentation == .empty)
        #expect(
            ResultSurfaceState.stale(
                success,
                failure: .init(summary: "The refresh failed.")
            ).presentation == .empty
        )
        #expect(ResultSurfaceState.refreshing(success).retainedUpdate == .refreshing)
        #expect(
            ResultSurfaceState.stale(
                success,
                failure: .init(summary: "The refresh failed.")
            ).retainedUpdate == .stale(.init(summary: "The refresh failed."))
        )
    }

    @Test("Refreshing and stale populated results keep the populated presentation")
    func retainedPopulatedPresentation() {
        let success = ResultSuccess(content: .populated, updatedAt: updatedAt)

        #expect(ResultSurfaceState.refreshing(success).presentation == .populated)
        #expect(
            ResultSurfaceState.stale(
                success,
                failure: .init(summary: "The refresh failed.")
            ).presentation == .populated
        )
    }

    @Test("Composite freshness waits for every relevant source")
    func compositeWaitsForAllSources() {
        let earlier = Date(timeIntervalSince1970: 1_699_999_000)
        let settled = ResultSurfaceState.populated(updatedAt: earlier)
        let refreshing = ResultSurfaceState.refreshing(
            .init(content: .empty, updatedAt: updatedAt)
        )

        #expect(ResultFreshness.combining([settled, refreshing]) == nil)
        #expect(ResultFreshness.combining([settled, .loading]) == nil)
        #expect(
            ResultFreshness.combining([
                settled,
                .failed(.init(summary: "One source did not answer.")),
            ]) == nil
        )
    }

    @Test("Composite freshness uses the oldest settled source")
    func compositeUsesOldestSource() {
        let earlier = Date(timeIntervalSince1970: 1_699_999_000)

        #expect(
            ResultFreshness.combining([
                .populated(updatedAt: updatedAt),
                .empty(updatedAt: earlier),
            ]) == .current(earlier)
        )
        #expect(
            ResultFreshness.combining([
                .populated(updatedAt: updatedAt),
                .stale(
                    .init(content: .populated, updatedAt: earlier),
                    failure: .init(summary: "The older source could not refresh.")
                ),
            ]) == .stale(earlier)
        )
    }

    @Test("Clickmap does not publish page freshness while one result source is loading")
    @MainActor
    func clickmapWaitsForBothResultSources() {
        let store = HeatmapsStore()
        store.elementsLoadedAt = updatedAt
        store.isLoadingHeatmap = true

        #expect(store.elementsResultState == .empty(updatedAt: updatedAt))
        #expect(store.heatmapResultState == .loading)
        #expect(store.resultFreshness == nil)

        let earlier = updatedAt.addingTimeInterval(-60)
        store.isLoadingHeatmap = false
        store.heatmapLoadedAt = earlier
        #expect(store.resultFreshness == .current(earlier))
    }

    @Test("Clickmap keeps saved-render navigation visible while click results load")
    @MainActor
    func clickmapPreservesIndependentNavigationDuringLoading() {
        let store = HeatmapsStore()

        #expect(store.clickResultPresentation == .report)

        store.renderLookup = .loaded([
            SavedHeatmap(
                id: "synthetic-render-id",
                shortID: "synthetic-render",
                name: "Synthetic saved page",
                url: "https://example.test/synthetic",
                type: "screenshot",
                status: "completed",
                targetWidths: [1_280],
                snapshots: [.init(width: 1_280, hasContent: true)],
                updatedAt: updatedAt,
                exception: nil
            ),
        ])
        #expect(store.renderablePages.count == 1)
        #expect(!store.hasNothingToShow)
        #expect(store.clickResultPresentation == .report)

        store.renderLookup = .loaded([])
        #expect(store.clickResultPresentation == .loading)
    }

    @Test("Clickmap only declares empty after both result sources succeed empty")
    @MainActor
    func clickmapEmptyRequiresBothSuccesses() {
        let store = HeatmapsStore()
        store.renderLookup = .loaded([])

        #expect(store.clickResultPresentation == .loading)

        store.heatmapLoadedAt = updatedAt
        #expect(store.clickResultPresentation == .loading)

        store.elementsLoadedAt = updatedAt
        #expect(store.clickResultPresentation == .empty)

        store.heatmapError = "The refresh failed."
        #expect(store.clickResultPresentation == .report)
    }

    @Test("Clickmap rejects saved renders from an obsolete project request")
    @MainActor
    func clickmapRenderLookupIsProjectAuthoritative() {
        let store = HeatmapsStore()
        let oldAuthority = ResourceRequestAuthority(
            projectID: 1,
            region: .usCloud,
            authSessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let newAuthority = ResourceRequestAuthority(
            projectID: 2,
            region: .usCloud,
            authSessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let staleToken = store.beginRenderLookup(authority: oldAuthority)
        let currentToken = store.beginRenderLookup(authority: newAuthority)

        store.completeRenderLookup(
            token: staleToken,
            result: .loaded([syntheticSavedHeatmap])
        )
        #expect(store.renderablePages.isEmpty)
        #expect(store.isResolvingRenders)

        store.completeRenderLookup(token: currentToken, result: .loaded([]))
        #expect(store.renderablePages.isEmpty)
        #expect(!store.isResolvingRenders)
    }

    @Test("Clickmap clears raw click rows when the result authority changes")
    @MainActor
    func clickmapClearsRowsAcrossAuthorityChanges() {
        let store = HeatmapsStore()
        store.profile = HeatmapProfile.make(points: [
            HeatmapPoint(
                count: 3,
                pointerY: 120,
                pointerRelativeX: 0.5,
                isTargetFixed: false
            ),
        ])
        store.heatmapLoadedAt = updatedAt
        let authority = ResourceRequestAuthority(
            projectID: 2,
            region: .euCloud,
            authSessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        _ = store.beginHeatmapRequest(authority: authority, window: .week)

        #expect(store.profile.isEmpty)
        #expect(store.heatmapLoadedAt == nil)
        #expect(store.heatmapResultState == .loading)
    }

    @Test("Server-search controls remain owned while a submitted filter is resolving")
    @MainActor
    func submittedSearchKeepsOwnership() {
        let tracing = TracingStore()
        let logs = LogsStore()

        #expect(!tracing.ownsSearch)
        #expect(!logs.ownsSearch)

        tracing.spanName = "checkout"
        logs.search = "timeout"

        #expect(tracing.ownsSearch)
        #expect(logs.ownsSearch)

        tracing.spanName = ""
        logs.search = ""

        #expect(tracing.ownsSearch)
        #expect(logs.ownsSearch)

        tracing.completeSearchSession(submittedQuery: "checkout", currentQuery: "")
        logs.completeSearchSession(submittedQuery: "timeout", currentQuery: "")

        #expect(tracing.ownsSearch)
        #expect(logs.ownsSearch)

        tracing.completeSearchSession(submittedQuery: "", currentQuery: "")
        logs.completeSearchSession(submittedQuery: "", currentQuery: "")

        #expect(!tracing.ownsSearch)
        #expect(!logs.ownsSearch)
    }

    @Test("Resource walls and successful empty results do not own search")
    func resourceStateSearchOwnership() {
        #expect(
            ResultSurfaceState.resource(
                .denied(resource: "logs"),
                hasContent: false,
                updatedAt: nil,
                isLoading: false
            ).ownsSearch == false
        )
        #expect(
            ResultSurfaceState.resource(
                .empty,
                hasContent: false,
                updatedAt: updatedAt,
                isLoading: false
            ) == .empty(updatedAt: updatedAt)
        )
        #expect(
            ResultSurfaceState.resource(
                .loaded,
                hasContent: true,
                updatedAt: updatedAt,
                isLoading: false
            ).ownsSearch
        )
    }

    private var syntheticSavedHeatmap: SavedHeatmap {
        SavedHeatmap(
            id: "synthetic-render-id",
            shortID: "synthetic-render",
            name: "Synthetic saved page",
            url: "https://example.test/synthetic",
            type: "screenshot",
            status: "completed",
            targetWidths: [1_280],
            snapshots: [.init(width: 1_280, hasContent: true)],
            updatedAt: updatedAt,
            exception: nil
        )
    }
}
