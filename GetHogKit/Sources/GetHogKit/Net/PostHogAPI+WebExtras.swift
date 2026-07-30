import Foundation

// The two remaining accepted web-analytics query kinds, kept out of the main
// catalog so the notes on their unusual responses live next to them.

extension PostHogAPI {

    /// Outbound links: which external URLs people clicked through to.
    ///
    /// Columns come back as dotted paths (`context.columns.url`) and each cell is
    /// a `[current, previous]` pair rather than a scalar — see
    /// `WebExternalClickRow`, which is what should decode this.
    ///
    /// No `limit` is sent. The query was only ever verified in the shape below,
    /// and a rejected parameter would blank the whole section for a report that
    /// is naturally short; the caller caps the list instead.
    public static func webExternalClicks(projectID: Int, dateFrom: String = "-7d") -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "WebExternalClicksTableQuery",
            "dateRange": ["date_from": dateFrom],
            "properties": [],
        ])
    }

    /// PostHog's own "what stands out" ranking over the web dimensions.
    ///
    /// The response is unlike other table queries: `results` holds **objects**
    /// and there is no `columns` array, so `QueryResponse` cannot decode it —
    /// use `WebNotableChangesResponse`.
    ///
    /// Its `percent_change` is not usable as reported; the reasoning is on
    /// `WebNotableChange.comparablePercentChange`.
    public static func webNotableChanges(projectID: Int, dateFrom: String = "-7d") -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "WebNotableChangesQuery",
            "dateRange": ["date_from": dateFrom],
            "properties": [],
        ])
    }
}
