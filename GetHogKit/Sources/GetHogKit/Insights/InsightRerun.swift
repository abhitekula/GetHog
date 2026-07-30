import Foundation

/// Re-running a saved insight over a different time range.
///
/// **The dashboard endpoint cannot do this.** `GET /dashboards/:id/?date_from=…`
/// returns HTTP 200 and *silently ignores* the parameter — verified against a
/// live project, where `-7d`, `-90d` and no parameter at all returned the same
/// 31 points. A picker built on it would appear to work and never change a
/// number, which is the worst kind of broken.
///
/// What does work is re-posting each insight's own query to `/query/` with the
/// date range replaced: verified live, `-7d` returned 8 points and `-90d`
/// returned 91.
///
/// The cost is one request per tile per change, against a budget shared with the
/// user's production integrations — so this belongs behind a deliberate user
/// action, never behind a continuous gesture.
public enum InsightRerun {

    /// The `/query/` response wrapper. A saved insight stores its payload under
    /// `result`; the same payload arrives under `results` when the query is run
    /// directly, so it has to be unwrapped before the shared decoder sees it.
    private struct Envelope: Decodable {
        let results: RawResult
    }

    /// Turns a `/query/` response into something drawable.
    ///
    /// Takes the kind and display from the *saved* insight rather than the
    /// response: the payload cannot say whether a trends result was meant to be
    /// a line, a stacked bar or a single bold number, and guessing would redraw
    /// the user's insight as a different chart.
    public static func renderModel(
        from data: Data,
        sourceKind: String,
        display: String?
    ) -> InsightRenderModel? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return Insight.renderModel(
            result: envelope.results,
            sourceKind: sourceKind,
            display: display
        )
    }

    /// Returns `source` with its date range replaced, everything else untouched.
    ///
    /// Non-object input is returned unchanged: a malformed saved query should
    /// fail its request and degrade one tile, not be rewritten into something
    /// that looks valid.
    public static func source(
        _ source: JSONValue,
        dateFrom: String,
        compare: Bool
    ) -> JSONValue {
        guard case .object(var fields) = source else { return source }

        fields["dateRange"] = .object(["date_from": .string(dateFrom)])

        if compare {
            fields["compareFilter"] = .object(["compare": .bool(true)])
        } else {
            // Removed rather than set to false: not asking to compare is a
            // different request from asking not to, and PostHog is free to treat
            // them differently.
            fields["compareFilter"] = nil
        }

        return .object(fields)
    }
}

public extension PostHogAPI {
    /// Executes a raw query node.
    ///
    /// Used to re-run a saved insight after overriding its date range. Costs one
    /// `query`-category slot per call.
    static func runQuery(projectID: Int, source: JSONValue) -> Endpoint {
        let body = try? JSONEncoder().encode(JSONValue.object(["query": source]))
        return Endpoint(
            path: "/api/projects/\(projectID)/query/",
            method: "POST",
            body: body,
            category: .query
        )
    }
}
