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
    /// The authority that produced `failure`. Kept separate from published-row
    /// provenance because a valid first-page failure has no rows to commit.
    private var failureScope: LoadScope?
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

    /// The authority that owns the rows currently published by this store.
    ///
    /// These are committed only after a successful first-page response. A live
    /// project or filter is merely a request until then, and must not relabel
    /// rows left by an earlier authority.
    private(set) var loadedProjectID: Int?
    private(set) var loadedProjectName: String?
    private(set) var loadedRequest: InsightsRequest?

    private struct LoadScope: Equatable {
        let projectID: Int
        let request: InsightsRequest
    }

    /// The newest requested authority, including one that is still in flight.
    private var activeScope: LoadScope?

    /// Scope equality alone cannot reject A -> B -> A completion races. Every
    /// first-page load therefore owns a distinct publication generation.
    private var generation = 0

    // MARK: - Loading

    /// Replaces the list with the first page for `request`.
    func load(
        client: PostHogClient,
        projectID: Int,
        request: InsightsRequest,
        projectName: String? = nil
    ) async {
        let scope = LoadScope(projectID: projectID, request: request)
        generation += 1
        let token = generation
        activeScope = scope

        if committedScope != scope {
            withdrawPublishedRows()
        }
        // A first-page replacement supersedes any page append, even when it
        // refreshes the same scope. The old append may finish, but its token no
        // longer owns publication.
        isLoadingMore = false
        failure = nil
        failureScope = nil
        isLoading = true
        defer {
            if token == generation, activeScope == scope {
                isLoading = false
            }
        }

        do {
            let page = try await fetch(client: client, projectID: projectID, request: request, offset: 0)
            // Another project or filter was chosen while this was in flight.
            // Dropping the reply prevents Project A rows from appearing under
            // Project B, or funnels under a heading that says trends.
            guard token == generation, activeScope == scope else { return }
            insights = page.results.filter { !$0.deleted }
            seenIDs = Set(insights.map(\.id))
            total = page.count
            hasMore = page.next != nil && !page.results.isEmpty
            loadedAt = Date()
            loadedProjectID = projectID
            loadedProjectName = projectName
            loadedRequest = request
            failure = nil
            failureScope = nil
        } catch is CancellationError {
            // A superseded `.task(id:)` is normal control flow. Its replacement
            // owns the screen now, so cancellation is neither an error nor a
            // fact worth flashing during the debounce before that task starts.
            return
        } catch {
            guard token == generation, activeScope == scope else { return }
            guard !Task.isCancelled else { return }
            failure = LoadFailure(error, loading: "insights")
            failureScope = scope
        }
    }

    /// Appends the next page, if there is one.
    ///
    /// Silently does nothing when a load is already running or when the server
    /// said there is no more. Both are normal — this is called from a row
    /// appearing, which happens far more often than a page is needed.
    func loadMore(client: PostHogClient, projectID: Int) async {
        guard
            let request = loadedRequest,
            loadedProjectID == projectID,
            hasMore,
            !isLoading,
            !isLoadingMore
        else { return }
        let scope = LoadScope(projectID: projectID, request: request)
        guard activeScope == scope else { return }
        let token = generation
        isLoadingMore = true
        defer {
            if token == generation, activeScope == scope {
                isLoadingMore = false
            }
        }

        do {
            let page = try await fetch(
                client: client,
                projectID: projectID,
                request: request,
                offset: insights.count
            )
            guard
                token == generation,
                activeScope == scope,
                loadedProjectID == projectID,
                loadedRequest == request
            else { return }
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
            failure = nil
            failureScope = nil
        } catch is CancellationError {
            return
        } catch {
            guard
                token == generation,
                activeScope == scope,
                loadedProjectID == projectID,
                loadedRequest == request
            else { return }
            guard !Task.isCancelled else { return }
            // The rows already on screen stay. A failed *next* page is not a
            // failed screen, and replacing 50 good insights with an error because
            // the 51st did not arrive would be a worse answer than the footer
            // this sets.
            failure = LoadFailure(error, loading: "insights")
            failureScope = scope
            hasMore = false
        }
    }

    /// Whether the published rows answer the screen's live authority.
    ///
    /// Kept as one predicate so the list, detail selection, and overview cannot
    /// drift into three subtly different provenance checks.
    func publishes(projectID: Int?, request: InsightsRequest) -> Bool {
        guard let projectID else { return false }
        return loadedProjectID == projectID && loadedRequest == request
    }

    /// Returns an error only to the authority whose request produced it.
    ///
    /// The screen's request changes immediately while its debounced load starts
    /// later. Looking at bare `failure` in that interval would put an old filter
    /// or project error under the new controls.
    func failure(projectID: Int?, request: InsightsRequest) -> LoadFailure? {
        guard let projectID else { return nil }
        let scope = LoadScope(projectID: projectID, request: request)
        return failureScope == scope ? failure : nil
    }

    private var committedScope: LoadScope? {
        guard let loadedProjectID, let loadedRequest else { return nil }
        return LoadScope(projectID: loadedProjectID, request: loadedRequest)
    }

    /// Withdraws facts published by a different authority before the new
    /// request can suspend. A replacement failure must leave an honest empty
    /// failure state, never old rows with a new project or filter label.
    private func withdrawPublishedRows() {
        insights = []
        total = nil
        hasMore = false
        seenIDs = []
        loadedAt = nil
        loadedProjectID = nil
        loadedProjectName = nil
        loadedRequest = nil
        failure = nil
        failureScope = nil
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

/// Scope-honest facts for the regular-width insight-library overview.
///
/// All values are derived from the rows already held by `InsightsStore`. The
/// server count is used only to state coverage; it never turns loaded-row
/// aggregates into project totals.
struct InsightOverviewFacts {
    struct KindGroup: Identifiable {
        enum Bucket: Hashable {
            case known(InsightKind)
            case other
        }

        let bucket: Bucket
        let count: Int
        let newest: Insight

        var id: String {
            switch bucket {
            case .known(let kind): kind.rawValue
            case .other: "other"
            }
        }

        var title: String {
            switch bucket {
            case .known(let kind): kind.title
            case .other: "Other"
            }
        }
    }

    let loadedCount: Int
    let favoriteCount: Int
    let kindCount: Int
    let coverageSummary: String
    let qualifiesMetricsAsLoaded: Bool
    let kindGroups: [KindGroup]
    let recentlyEdited: [Insight]

    init(
        insights: [Insight],
        total: Int?,
        hasMore: Bool,
        isFiltering: Bool
    ) {
        loadedCount = insights.count
        favoriteCount = insights.filter(\.favorited).count

        let rowsByKind = Dictionary(grouping: insights) { insight in
            insight.kind.map(KindGroup.Bucket.known) ?? .other
        }
        kindGroups = rowsByKind.compactMap { bucket, rows in
            guard let newest = rows.sorted(by: Self.isNewerDefinition).first else { return nil }
            return KindGroup(bucket: bucket, count: rows.count, newest: newest)
        }
        .sorted {
            $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count
        }
        kindCount = kindGroups.count

        recentlyEdited = Array(
            insights
                .filter { $0.lastModifiedAt != nil }
                .sorted(by: Self.isMoreRecentlyEdited)
                .prefix(5)
        )

        let incomplete = hasMore || total.map { $0 > insights.count } == true
        qualifiesMetricsAsLoaded = isFiltering || incomplete
        coverageSummary = Self.coverageSummary(
            loaded: insights.count,
            total: total,
            hasMore: hasMore,
            isFiltering: isFiltering
        )
    }

    private static func coverageSummary(
        loaded: Int,
        total: Int?,
        hasMore: Bool,
        isFiltering: Bool
    ) -> String {
        let noun = isFiltering ? "matching insights" : "insights"
        if let total, total > loaded {
            return "Showing \(loaded) of \(total) \(noun)."
        }
        if hasMore {
            return "Showing \(loaded) loaded \(noun); more are available."
        }
        if loaded == 1 {
            return isFiltering ? "1 matching insight." : "1 insight."
        }
        return "\(loaded) \(noun)."
    }

    /// A saved definition may omit `last_modified_at` while still carrying its
    /// creation date. Kind representatives use both facts; otherwise a newer
    /// definition without a modification timestamp would be demoted behind an
    /// older row solely because its id happened to be smaller.
    private static func isNewerDefinition(_ lhs: Insight, _ rhs: Insight) -> Bool {
        compareRecency(
            lhs: lhs,
            lhsDate: lhs.lastModifiedAt ?? lhs.createdAt,
            rhs: rhs,
            rhsDate: rhs.lastModifiedAt ?? rhs.createdAt
        )
    }

    /// This comparator is deliberately narrower than the kind representative's:
    /// the section says "edited", so creation alone cannot put a row in it.
    private static func isMoreRecentlyEdited(_ lhs: Insight, _ rhs: Insight) -> Bool {
        compareRecency(
            lhs: lhs,
            lhsDate: lhs.lastModifiedAt,
            rhs: rhs,
            rhsDate: rhs.lastModifiedAt
        )
    }

    private static func compareRecency(
        lhs: Insight,
        lhsDate: Date?,
        rhs: Insight,
        rhsDate: Date?
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (.some(left), .some(right)):
            return left == right ? lhs.id > rhs.id : left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.id > rhs.id
        }
    }
}

/// Spoken content for overview navigation rows.
///
/// The visible subtitle is an aggregate on kind rows, not the representative
/// insight's description. Keeping this formatter value-only makes the VoiceOver
/// contract testable and prevents the spoken count from drifting from the row.
enum InsightOverviewAccessibility {
    static func spokenSummary(
        title: String,
        subtitle: String?,
        footnote: String?
    ) -> String {
        [title, subtitle, footnote]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// Authority gate for the compact navigation binding.
///
/// A raw selection can outlive its project or filter. Returning `nil` while the
/// published rows do not answer the live scope pops the destination before it
/// can resolve that old id against a new project.
enum InsightsSelectionAuthority {
    static func current(
        selectedID: Int?,
        publishesCurrentScope: Bool
    ) -> Int? {
        publishesCurrentScope ? selectedID : nil
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
