import Foundation
import Observation
import GetHogKit

/// The saved-insight library's data.
///
/// Paged, and paged *properly*, because a project's saved insights can exceed
/// `limit=100` — the app's default everywhere else — and stopping after one
/// page silently loses the rest.
///
/// Everything that narrows the list is a server round trip rather than a local
/// filter, which is the opposite of `ProjectSearchStore` next door. The reason is
/// size: a `file_system` row is a name and a path, an insight row is the whole
/// saved query, and the collection measures 375,505 bytes. See
/// `PostHogAPI.insights` for the measurements behind that choice.
@MainActor
@Observable
final class InsightsStore {

    /// Everything loaded so far, in server order, deduplicated.
    private(set) var insights: [Insight] = []
    /// What PostHog says the *filtered* collection holds, so the screen can say
    /// "40 of 140" rather than leaving a reader to wonder whether the list ended
    /// or merely stopped.
    private(set) var total: Int?
    private(set) var isLoading = false
    /// A page after the first. Kept apart from `isLoading` so the skeleton is
    /// drawn only when there is nothing to look at yet, and a footer spinner
    /// otherwise.
    private(set) var isLoadingMore = false
    private(set) var failure: LoadFailure?
    private(set) var loadedAt: Date?

    /// Whether PostHog says another page exists.
    ///
    /// Read from `next` rather than compared against `count`: the two disagree
    /// the moment somebody saves an insight between two of this screen's
    /// requests, and `next` is the one the server computed for the offset we
    /// actually asked from.
    private(set) var hasMore = false

    /// Rows per request.
    ///
    /// Deliberately smaller than the app's usual 100. At 119,389 bytes for 50
    /// rows, a 100-row page is a quarter of a megabyte before anything is drawn,
    /// and the screen only ever shows a dozen at a time.
    static let pageSize = 50

    /// Ids already held, so a page that repeats a row cannot append it twice.
    ///
    /// Not merely defensive. The demo transport answers every `/insights/` path
    /// with the same five-row fixture *including its `next` link*, so a paging
    /// loop that trusted the server would grow the list forever without ever
    /// showing a sixth insight. `loadMore` stops when a page adds nothing new,
    /// which turns that into a list that simply ends.
    private var seenIDs: Set<Int> = []

    /// The request the current contents answer, so a reply that arrives after
    /// the user has changed the filter can be discarded rather than shown under
    /// the wrong heading.
    private var activeRequest: InsightsRequest?

    // MARK: - Loading

    /// Replaces the list with the first page for `request`.
    func load(client: PostHogClient, projectID: Int, request: InsightsRequest) async {
        activeRequest = request
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await fetch(client: client, projectID: projectID, request: request, offset: 0)
            // Another filter was chosen while this was in flight. Dropping the
            // reply is the whole point of stamping it: showing it would put
            // funnels under a heading that says trends.
            guard activeRequest == request else { return }
            insights = page.results.filter { !$0.deleted }
            seenIDs = Set(insights.map(\.id))
            total = page.count
            hasMore = page.next != nil && !page.results.isEmpty
            loadedAt = Date()
            failure = nil
        } catch {
            guard activeRequest == request else { return }
            failure = LoadFailure(error, loading: "insights")
        }
    }

    /// Appends the next page, if there is one.
    ///
    /// Silently does nothing when a load is already running or when the server
    /// said there is no more. Both are normal — this is called from a row
    /// appearing, which happens far more often than a page is needed.
    func loadMore(client: PostHogClient, projectID: Int) async {
        guard let request = activeRequest, hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await fetch(
                client: client,
                projectID: projectID,
                request: request,
                offset: insights.count
            )
            guard activeRequest == request else { return }
            let fresh = page.results.filter { !$0.deleted && !seenIDs.contains($0.id) }
            insights += fresh
            seenIDs.formUnion(fresh.map(\.id))
            // Two conditions, not one. `next` alone trusts the server; `fresh`
            // alone would stop on a page that happened to be all duplicates but
            // had more behind it. Requiring both means the list stops when it has
            // genuinely stopped growing, which is the only condition that
            // terminates against a fixture that always answers with page one.
            hasMore = page.next != nil && !fresh.isEmpty
            total = page.count
            loadedAt = Date()
        } catch {
            guard activeRequest == request else { return }
            // The rows already on screen stay. A failed *next* page is not a
            // failed screen, and replacing 50 good insights with an error because
            // the 51st did not arrive would be a worse answer than the footer
            // this sets.
            failure = LoadFailure(error, loading: "insights")
            hasMore = false
        }
    }

    private func fetch(
        client: PostHogClient,
        projectID: Int,
        request: InsightsRequest,
        offset: Int
    ) async throws -> Page<Insight> {
        try await client.send(
            PostHogAPI.insights(
                projectID: projectID,
                limit: Self.pageSize,
                offset: offset,
                search: request.search,
                kind: request.kind,
                favoritedOnly: request.favoritesOnly
            )
        )
    }

    // MARK: - Presentation

    /// Starred first, then the rest, each in the order the server sent them.
    ///
    /// A `partition` rather than a sort, so PostHog's own ordering survives
    /// inside each half. It is stable across pages for the same reason: a row
    /// keeps its place when the page after it arrives.
    ///
    /// A project can have no favorites, so this section must not read as broken
    /// when it is empty. The heading therefore appears only with rows under it.
    var favorites: [Insight] { insights.filter(\.favorited) }
    var others: [Insight] { insights.filter { !$0.favorited } }

    /// How much of the collection is on screen, stated rather than implied.
    ///
    /// A list that stops at 50 of 140 with no explanation is the same silent
    /// truncation `ProjectSearchStore.coverageSummary` exists to prevent, and
    /// this screen truncates by design on every project with more than a page.
    var coverageSummary: String? {
        guard !insights.isEmpty else { return nil }
        let shown = insights.count
        guard let total, total > shown else {
            return shown == 1 ? "1 insight." : "\(shown) insights."
        }
        return "Showing \(shown) of \(total) insights."
    }
}

/// One set of filter choices, as a value.
///
/// A single `Equatable` value rather than three properties so `.task(id:)` fires
/// exactly once when two of them change together, and so a reply can be checked
/// against the request that asked for it.
struct InsightsRequest: Equatable, Hashable {
    var search: String = ""
    /// `nil` is "every kind", which is not the same as any particular one and
    /// must not be spelled as a default case.
    var kind: InsightKind?
    var favoritesOnly = false

    /// Whether anything is narrowing the list, for the empty state to be able to
    /// tell "this project has no insights" from "nothing matched".
    var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || kind != nil
            || favoritesOnly
    }
}
