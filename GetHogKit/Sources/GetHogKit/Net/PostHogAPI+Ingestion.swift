import Foundation

/// How the server should rank the warnings it returns.
public enum IngestionWarningOrder: String, Sendable, Hashable, CaseIterable, Identifiable {
    case count
    case lastSeen = "last_seen"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .count: "Volume"
        case .lastSeen: "Most recent"
        }
    }
}

public extension PostHogAPI {

    /// Ingestion warnings — "is my data arriving, and is it arriving intact".
    ///
    /// **Use `ingestion_warnings_v2`.** The legacy `/ingestion_warnings/` path
    /// answers 403 *"This action does not support personal API key access"*, and
    /// a personal API key is the only credential this app can hold, so that path
    /// deliberately has no entry here — an endpoint that can only ever fail is
    /// worse than a missing one.
    ///
    /// The response is a **bare JSON array**, not a `Page`. Decode it with
    /// `IngestionWarning.decodeList(from:)`.
    ///
    /// Categorised `.crud` rather than `.analytics`: the server pre-aggregates
    /// the counts and the sparkline, so this triggers no query engine work and
    /// must not bill against the scarce analytics budget.
    ///
    /// - Note: The API also accepts `q` and `samples`. `q` is not sent because
    ///   the search field on this screen filters what is already loaded — the
    ///   rate-limit budget is organisation-wide and a request per keystroke is
    ///   the fastest way to spend somebody's production quota. `samples` is not
    ///   sent because its accepted values were not observable against a project
    ///   with no warnings in it, and guessing one risks a 400 on the whole
    ///   screen to control a field this client only counts.
    static func ingestionWarnings(
        projectID: Int,
        window: IngestionWarningWindow = .sevenDays,
        category: IngestionWarningCategory? = nil,
        orderBy: IngestionWarningOrder = .count,
        limit: Int = 100
    ) -> Endpoint {
        var query = [
            URLQueryItem(name: "date_from", value: window.rawValue),
            URLQueryItem(name: "order_by", value: orderBy.rawValue),
            // Documented range is 1–500 and the API rejects anything outside it.
            // Clamping costs nothing; not clamping turns a caller's typo into an
            // HTTP 400 the screen then has to explain.
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500))),
        ]
        // Omitted entirely when there is no filter: `category=` means "whose
        // category is the empty string", which is none of them.
        if let category {
            query.append(URLQueryItem(name: "category", value: category.apiValue))
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/ingestion_warnings_v2/",
            query: query,
            category: .crud
        )
    }
}
