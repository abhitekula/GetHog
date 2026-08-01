import Foundation

// Saved queries — the warehouse's modelling half — and the jobs that materialise
// them. All three requests are `.crud`; none of them is a `/query/` POST.
//
// **Why REST and not `system.data_modeling_views`.** REST exposes the core
// fields plus metadata useful to a row, and costs `.crud` rather than `.query`.
//
// The two sources corroborate each other on the one shape that matters. Asked
// through `system.information_schema.columns` — with the **fully qualified**
// `table_name = 'system.data_modeling_views'`, which is how that table spells a
// system table's name and the reason a bare `'data_modeling_views'` returns
// nothing — `columns` and `query` both come back typed `JSON`, not `String`.
// That is the same `{"kind": "HogQLQuery", "query": "…"}` object the REST detail
// response carries, and it is why `SavedQuery` unwraps rather than reading the
// field verbatim.
//
// Joining system tables can require an expensive cross-service query. REST keeps
// view details and job history as separate, bounded CRUD requests.
//
// **Cost.** Listing the views is **one** request, made with the warehouse
// screen's existing two. Opening a view is **two** more — the detail for its SQL
// and its job history — and they are made once per view opened and held for the
// life of the screen, which is the same bargain `PostHogAPI+Schema` documents
// for the table browser. A reader who opens the warehouse and looks at two views
// spends five requests, once.
extension PostHogAPI {

    /// Every saved query in the project, newest page first.
    ///
    /// **This endpoint paginates by page number, not by limit/offset**, and it
    /// is the only warehouse endpoint that does. Use `Page.next` to find later
    /// pages; `?limit=` is not its paging control.
    ///
    /// The response is PostHog's `DataWarehouseSavedQueryMinimal`, which drops
    /// `query`. See `SavedQuery` — the SQL needs `savedQuery(projectID:id:)`.
    public static func savedQueries(projectID: Int, page: Int = 1, search: String? = nil) -> Endpoint {
        var query = [URLQueryItem(name: "page", value: String(page))]
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/warehouse_saved_queries/",
            query: query,
            category: .crud
        )
    }

    /// One saved query in full — the only response that carries its SQL.
    public static func savedQuery(projectID: Int, id: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/warehouse_saved_queries/\(id)/",
            category: .crud
        )
    }

    /// Materialisation runs for one saved query, newest first.
    ///
    /// **`saved_query_id` is a `ModelChoiceFilter` over the project's own saved
    /// queries, so an unrecognised ID is an error, not an empty list. IDs come
    /// from the list response and failures are handled separately.
    ///
    /// This endpoint *does* take limit/offset, unlike the saved-query list above.
    ///
    /// Ten because a run history is read for its recent shape, not audited. A
    /// deeper history is a paging problem nobody has asked for on a phone.
    public static func dataModelingJobs(
        projectID: Int,
        savedQueryID: String,
        limit: Int = 10
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/data_modeling_jobs/",
            query: [
                URLQueryItem(name: "saved_query_id", value: savedQueryID),
                URLQueryItem(name: "limit", value: String(limit)),
            ],
            category: .crud
        )
    }

    // Neighbouring recent/running routes require session authentication and are
    // intentionally not exposed through a personal API key.
    //
    // `GET /warehouse_saved_queries/{id}/run_history/` is also unbuilt: it
    // exists, but the published contract types its 200 as
    // `DataWarehouseSavedQuery`, which cannot be what a *history* returns. With
    // no row in the project to check it against, `data_modeling_jobs/` — whose
    // contract and shape agree — is the honest choice.
}
