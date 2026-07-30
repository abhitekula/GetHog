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
    /// asked for by name. It is also not hypothetical — measured against project
    /// [REMOVED PRIVATE DATA], `last_refresh` is null and `result` is null on **all 140** saved
    /// insights, so a screen that stopped at the cache would draw an empty chart
    /// every single time.
    ///
    /// Nothing is escalated for a kind this app cannot draw. Five of that
    /// project's insights are `HogQLQuery`, which has no render shape here; a
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
