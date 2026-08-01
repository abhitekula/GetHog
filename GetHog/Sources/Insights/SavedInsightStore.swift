import Foundation
import Observation
import GetHogKit

/// One saved insight, resolved and computed.
///
/// Two jobs, and they are separate because they fail separately: finding the
/// insight (which can be "no such insight"), and getting numbers out of it
/// (which can be "PostHog hasn't computed this recently").
@MainActor
@Observable
final class SavedInsightStore {

    private(set) var insight: Insight?
    private(set) var isLoading = false
    private(set) var isComputing = false
    private(set) var failure: LoadFailure?
    /// True once the resolve finished and found nothing. Distinct from a
    /// failure: a deleted insight is a normal outcome for a link followed weeks
    /// after it was sent, and it deserves different words from a dead network.
    private(set) var notFound = false

    /// Whether the numbers on screen came from an escalation this screen paid
    /// for, rather than from PostHog's cache. Drives the freshness stamp, which
    /// would otherwise say "not yet loaded" over a chart full of data.
    private(set) var didCompute = false

    /// The result of re-running the insight with a narrowing applied. Absent
    /// means "draw the saved result", exactly as `DashboardDetailStore.overrides`
    /// does for a whole grid.
    private(set) var narrowed: InsightRenderModel?
    private(set) var isNarrowing = false
    /// Why the last narrowing did not produce numbers.
    ///
    /// Named rather than swallowed, for `DashboardDetailView`'s reason: a chart
    /// silently showing its saved, *unfiltered* result under a control that says
    /// "Chrome" is precisely the lie this feature exists to avoid. Three distinct
    /// paths reach it — a refused request, a response that decoded to nothing,
    /// and an insight with no runnable source — and each says which.
    private(set) var narrowError: String?

    // MARK: - Resolving

    /// Seeds from a row the list already fetched, so opening an insight from the
    /// library costs nothing before the chart appears.
    ///
    /// The row carries everything but `result` — name, description, the saved
    /// query, the kind — so the title, the subtitle and the chart's *shape* are
    /// on screen immediately and only the values are outstanding.
    func seed(_ insight: Insight) {
        guard self.insight == nil else { return }
        self.insight = insight
    }

    /// Finds the insight named by a link, which carries an id and nothing else.
    ///
    /// The id may be either spelling: PostHog's console builds its URLs from the
    /// 8-character `short_id`, while this app's own widgets and intents carry the
    /// numeric one. Both are tried in the order that costs least — a numeric id
    /// is a direct fetch, a handle is a filtered collection request — and neither
    /// is guessed at: a string that parses as an `Int` is only ever looked up as
    /// a numeric id, so a handle that happened to be all digits cannot silently
    /// select a different insight.
    func resolve(client: PostHogClient, projectID: Int, identifier: String) async {
        guard insight == nil || insight?.matches(identifier) == false else { return }
        isLoading = true
        defer { isLoading = false }
        notFound = false

        do {
            if let numericID = Int(identifier) {
                insight = try await client.send(
                    PostHogAPI.insight(projectID: projectID, insightID: numericID)
                )
            } else {
                let page: Page<Insight> = try await client.send(
                    PostHogAPI.insight(projectID: projectID, shortID: identifier)
                )
                guard let found = page.results.first else {
                    notFound = true
                    return
                }
                insight = found
            }
            failure = nil
        } catch {
            // A 404 is "no such insight", not "the request failed", and the two
            // must not read the same: one means the link is stale, the other
            // means to try again.
            if case PostHogError.http(status: 404, detail: _) = error {
                notFound = true
                return
            }
            failure = LoadFailure(error, loading: "insight")
        }
    }

    // MARK: - Results

    /// Fills in the numbers, cheaply first.
    ///
    /// Cache first, then **one** escalation to a real computation — the same two
    /// steps, in the same order and for the same reason, as
    /// `ReadInsightIntent`'s. The cache is free and the recomputation is charged
    /// to an organisation-wide budget shared with the user's own integrations,
    /// so it is spent only when the cheap answer was empty.
    ///
    /// That it is spent *at all* on merely opening a screen is a departure from
    /// the dashboard grid, which stops at the cache. The difference is arity: a
    /// dashboard opens 5–20 insights at once and this opens the one the user
    /// asked for by name. A saved definition may have no cached result, so the
    /// detail screen performs one explicit computation in that case.
    ///
    /// Nothing is escalated for a kind this app cannot draw. `HogQLQuery` has no
    /// render shape here; a
    /// blocking query would buy a card that already says so.
    func loadResults(client: PostHogClient, projectID: Int) async {
        guard let insight, !insight.hasDrawableResult else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let cached: Insight = try await client.send(
                PostHogAPI.insight(projectID: projectID, insightID: insight.id)
            )
            self.insight = cached
            failure = nil
            guard !cached.hasDrawableResult, cached.isDrawableKind else { return }
        } catch {
            failure = LoadFailure(error, loading: "insight")
            return
        }

        await compute(client: client, projectID: projectID)
    }

    /// Recomputes, on purpose.
    ///
    /// Reachable from the toolbar as well as from the escalation above, because
    /// "these numbers are from an hour ago" is a thing a reader can only fix by
    /// asking, and the screen states the age right beside the button.
    func compute(client: PostHogClient, projectID: Int) async {
        guard let insight else { return }
        isComputing = true
        defer { isComputing = false }

        do {
            let computed: Insight = try await client.send(
                PostHogAPI.computeInsight(projectID: projectID, insightID: insight.id)
            )
            self.insight = computed
            didCompute = true
            failure = nil
        } catch {
            // Deliberately not cleared: whatever was already drawn stays, and
            // the failure is stated beside it rather than replacing it. A
            // recomputation that timed out has not invalidated the previous
            // answer, it has only failed to improve on it.
            failure = LoadFailure(error, loading: "insight")
        }
    }

    // MARK: - Narrowing

    /// Re-runs the insight with a property filter and a breakdown laid over its
    /// saved query.
    ///
    /// **One `.query` request, and only from an explicit Apply.** The same price
    /// and the same rule as the dashboard's date rerun — see `InsightRerun`, which
    /// documents why `GET /insights/:id/?date_from=…` cannot do this and why a
    /// continuous control must never drive it.
    ///
    /// Nothing is written back into `insight`: the saved definition on PostHog is
    /// untouched, and a reader who clears the narrowing gets the stored result
    /// back without a second request.
    func applyNarrowing(
        dateFrom: String?,
        compare: Bool,
        filters: [InsightPropertyFilter],
        breakdown: InsightBreakdownOverride,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard let insight else { return }

        // Nothing asked for: drop the override rather than spending a request to
        // reproduce the result already on screen.
        if dateFrom == nil, !compare, filters.isEmpty, breakdown == .saved {
            narrowed = nil
            narrowError = nil
            return
        }

        guard let source = insight.rawSource else {
            narrowed = nil
            narrowError = "This insight's saved query isn't in a shape GetHog can re-run, so the chart is still showing the saved result."
            return
        }

        isNarrowing = true
        defer { isNarrowing = false }

        // `dateFrom` absent means "keep the saved window", and the rewrite has no
        // way to express that — it always writes a `dateRange`. So the saved
        // range is read back off the node rather than being replaced with a
        // default, which would silently move a 90-day insight to 30.
        let effectiveDateFrom = dateFrom
            ?? source["dateRange"]?["date_from"]?.stringValue
            ?? "-30d"

        let rebuilt = InsightRerun.source(
            source,
            dateFrom: effectiveDateFrom,
            compare: compare,
            filters: filters,
            breakdown: breakdown
        )

        do {
            let data = try await client.data(
                for: PostHogAPI.runQuery(projectID: projectID, source: rebuilt)
            )
            guard let model = InsightRerun.renderModel(
                from: data,
                sourceKind: insight.sourceKind,
                display: insight.displayType
            ) else {
                // A request that *succeeded* and produced nothing drawable. Not a
                // failure of the network and not an empty project — the response
                // arrived in a shape this build could not turn into a chart, and
                // saying so is the only honest option. Counting it as success
                // would leave the saved chart on screen under the new filter.
                narrowed = nil
                narrowError = "PostHog answered, but not in a shape this app could draw. The chart below is still the saved result."
                return
            }
            narrowed = model
            narrowError = nil
        } catch {
            narrowed = nil
            narrowError = LoadFailure(error, loading: "insight").summary
        }
    }

    func clearNarrowing() {
        narrowed = nil
        narrowError = nil
    }
}

extension Insight {
    /// Whether this row is the one a link named, in either spelling.
    func matches(_ identifier: String) -> Bool {
        shortID == identifier || String(id) == identifier
    }

    /// Whether the saved payload actually decoded into something with values in
    /// it.
    ///
    /// Not the same as "the render model is not `.unsupported`". A trends
    /// insight with an empty `result` decodes to `.timeSeries([], style:)` —
    /// a perfectly valid model of nothing — and drawing it produces a blank
    /// plot rather than an error, which is exactly the silent-empty failure
    /// this app treats as a bug.
    var hasDrawableResult: Bool {
        switch renderModel {
        case .timeSeries(let series, _): series.contains { !$0.points.isEmpty }
        case .barValue(let bars): !bars.isEmpty
        case .bigNumber: true
        case .funnel(let groups): groups.contains { !$0.steps.isEmpty }
        case .lifecycle(let series): !series.isEmpty
        case .retention(let grid): !grid.cohorts.isEmpty
        case .stickiness(let series): !series.isEmpty
        case .paths(let graph): !graph.edges.isEmpty
        // Not "no data" — a kind with no chart here. Computing it would change
        // nothing, so it counts as settled.
        case .unsupported: true
        }
    }

    /// Whether recomputing could plausibly produce a chart.
    ///
    /// Keyed on the *declared* query kind rather than on the decoded model, for
    /// the reason `Insight.renderModel` gives about never sniffing result
    /// shapes: an empty funnel and an unsupported kind both decode to
    /// `.unsupported`, and only one of them is worth spending a query on.
    var isDrawableKind: Bool {
        guard let kind else { return false }
        return kind != .sql
    }
}
