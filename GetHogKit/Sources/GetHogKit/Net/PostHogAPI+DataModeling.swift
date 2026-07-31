import Foundation

// Saved queries — the warehouse's modelling half — and the jobs that materialise
// them. All three requests are `.crud`; none of them is a `/query/` POST.
//
// **Why REST and not `system.data_modeling_views`.** Both exist and both answer.
// Measured 2026-07-30 against project [REMOVED PRIVATE DATA]:
//
//   GET  /api/projects/[REMOVED PRIVATE DATA]/warehouse_saved_queries/   200, count 0
//   GET  /api/environments/[REMOVED PRIVATE DATA]/warehouse_saved_queries/ 200, count 0
//   GET  /api/projects/[REMOVED PRIVATE DATA]/data_modeling_jobs/        200, count 0
//   POST /query/ SELECT * FROM system.data_modeling_views  200, 0 rows, columns
//        id, team_id, name, status, columns, query, last_run_at, is_materialized,
//        deleted, deleted_at, created_at, updated_at
//   POST /query/ SELECT * FROM system.data_modeling_jobs   200, 0 rows, columns
//        id, team_id, data_modeling_view_id, status, rows_materialized,
//        rows_expected, error, storage_delta_mib, last_run_at, created_at,
//        updated_at
//
// The system tables carry no field the REST list lacks, and the REST list adds
// `sync_frequency`, `folder_name`, `description`, `origin` and `created_by`,
// which are four fifths of what a row can usefully say. REST also costs `.crud`
// budget rather than `.query`.
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
// **And the join does not work.** The obvious single-request shape — join the
// two system tables so one call gets both the view and its last job — times out.
// Measured, same session, same project, against **zero rows** in both tables:
//
//   3 columns, LIMIT 10   HTTP 200 in 8.8s (0.1s on the cached repeat)
//   3 columns, LIMIT 500  HTTP 200 in 8.8s
//   5 columns, LIMIT 10   HTTP 504  "Query has hit the max execution time
//                                    before completing."
//   13 columns, LIMIT 500 HTTP 504, same message
//
// The generated ClickHouse explains it: both tables are `postgresql()` remote
// table functions, and joining two of them is a cross-service round trip that
// eats the 10s `max_execution_time` before it reads a row. Each table on its own
// answers in ~0.25s. So there was never a one-request version of this; the only
// question was which two-or-three requests to make, and REST wins that on
// budget and on payload.
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
    /// is the only warehouse endpoint that does. Measured: `?page=2` against a
    /// project with zero saved queries answers **HTTP 404
    /// `{"type":"invalid_request","code":"not_found","detail":"Invalid page."}`**,
    /// which is DRF's `PageNumberPagination` and nothing else. `?limit=` is
    /// accepted and silently ignored, so passing one would look like it worked
    /// and cap nothing. Read `Page.next` to know whether there is more; do not
    /// try to widen the page.
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
    /// queries, so an id it does not recognise is a 400, not an empty list.**
    /// Measured with an all-zeroes UUID: **HTTP 400
    /// `{"type":"validation_error","code":"invalid_choice","detail":"Select a
    /// valid choice. That choice is not one of the available choices.","attr":
    /// "saved_query_id"}`**. Harmless as used here — the id always comes from a
    /// row the list just returned — but it means this must never be fired
    /// speculatively, and the caller catches its failure separately so a 400
    /// here cannot blank the definition the reader came for.
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

    // Two neighbouring routes are deliberately **not** built, because this key
    // cannot reach them. Measured 2026-07-30:
    //
    //   GET /api/projects/[REMOVED PRIVATE DATA]/data_modeling_jobs/recent/   403
    //   GET /api/projects/[REMOVED PRIVATE DATA]/data_modeling_jobs/running/  403
    //
    // both answering
    // `{"type":"authentication_error","code":"permission_denied","detail":"This
    // action does not support personal API key access","attr":null}`.
    //
    // Worth recording as a *shape*, because this project has now seen four
    // different spellings of "no": 400 for an access-control failure, 402 for
    // the activity log, 404 for a page past the end, and this — a 403 that is
    // not about scopes at all. No scope on any key opens these two; they are
    // session-auth only. A cross-project "what is failing right now" summary
    // would have been the natural home for `running/`, and it is unbuildable
    // from a personal API key.
    //
    // `GET /warehouse_saved_queries/{id}/run_history/` is also unbuilt: it
    // exists, but the published contract types its 200 as
    // `DataWarehouseSavedQuery`, which cannot be what a *history* returns. With
    // no row in the project to check it against, `data_modeling_jobs/` — whose
    // contract and shape agree — is the honest choice.
}
