import Foundation
import Testing
@testable import GetHogKit

// The warehouse's modelling half: saved queries and the jobs that materialise
// them. These fixtures are deliberately fictional and exercise the serializer
// contract plus every client-side materialisation state.

@Suite("Saved queries")
struct SavedQueryTests {
    private func page() throws -> Page<SavedQuery> {
        try Page<SavedQuery>.decode(from: Fixture.data("warehouse_saved_queries.json"))
    }

    private func view(_ name: String) throws -> SavedQuery {
        let match = try page().results.first { $0.name == name }
        return try #require(match)
    }

    @Test("Decodes the list serializer")
    func decodesList() throws {
        let page = try page()
        #expect(page.count == 8)
        #expect(page.results.count == 8)
        #expect(page.results.map(\.name).contains("stalled_hourly_accounts"))
    }

    /// The single most important fact about the list endpoint: it does not carry
    /// SQL. If PostHog ever starts sending it, this test failing is how the
    /// second request per opened view becomes removable.
    @Test("The list carries no SQL, on any row")
    func listOmitsQuery() throws {
        for row in try page().results {
            #expect(row.query == nil, "\(row.name) unexpectedly carried a definition")
        }
    }

    private func detail() throws -> SavedQuery {
        try JSONDecoder().decode(
            SavedQuery.self,
            from: Fixture.data("warehouse_saved_query_detail.json")
        )
    }

    @Test("The detail response carries SQL, unwrapped from its object")
    func detailCarriesQuery() throws {
        let view = try detail()
        let sql = try #require(view.query)
        // Unwrapped from `{"kind": …, "query": …}` rather than decoded as a bare
        // string — a decoder that took the field exactly would either fail or
        // put the whole JSON object on screen.
        #expect(sql.hasPrefix("SELECT"))
        #expect(sql.contains("count(DISTINCT person_id)"))
        let raw = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("warehouse_saved_query_detail.json"))
                as? [String: Any]
        )
        #expect(raw["folder_id"] is NSNull)
        // Same view as the list's failed row, so the ids must agree or the demo
        // and the tests are describing two different things.
        #expect(view.id == "018f9000-0000-7000-8000-000000000362")
    }

    // MARK: - Suspension

    /// `suspended` is a **map keyed by engine name**, not a bool and not an
    /// array, and it is the field that says PostHog has stopped retrying. A
    /// decoder that read it as a flag would lose the reason and the timestamp,
    /// which are the only two things that make it actionable.
    @Test("Suspensions decode from the engine-keyed map")
    func suspensionsDecode() throws {
        let view = try detail()
        #expect(view.isSuspended)
        // Sorted by engine, because dictionary iteration order is not stable
        // across decodes and a list that reorders between redraws is a defect.
        #expect(view.suspensions.map(\.engine) == ["archive", "primary"])

        let primary = try #require(view.suspensions.first { $0.engine == "primary" })
        #expect(primary.reason.contains("384 MiB"))
        #expect(primary.jobID == "018f9000-0000-7000-8000-000000000453")
        #expect(primary.at != nil)

        // Required in the contract, but an empty reason renders as a suspension
        // with no cause, which reads as a bug rather than as a terse server.
        let archive = try #require(view.suspensions.first { $0.engine == "archive" })
        #expect(archive.reason == "No reason given")
    }

    /// `false` here has two meanings and only one of them is good news. The list
    /// serializer omits `suspended` entirely, so every row from it reports no
    /// suspension whether or not one exists.
    @Test("Suspension is invisible from the list, and that is the API's shape")
    func listCannotSeeSuspension() throws {
        for row in try page().results {
            #expect(row.suspensions.isEmpty)
            #expect(!row.isSuspended)
        }
        // The same view, from the detail endpoint, is suspended.
        let row = try view("stalled_hourly_accounts")
        let detail = try detail()
        #expect(row.id == detail.id)
        #expect(!row.isSuspended)
        #expect(detail.isSuspended)
    }

    // MARK: - Materialisation state

    @Test("A materialised view whose last run failed is serving stale data")
    func failedMaterialisationIsStale() throws {
        let view = try view("stalled_hourly_accounts")
        #expect(view.isMaterialized)
        #expect(view.materialization == .failed)
        #expect(view.isServingStaleData)
        #expect(view.latestError?.contains("384 MiB") == true)
    }

    /// The quiet one. Nothing errored; the SQL simply moved on without the
    /// table, and every query still answers.
    @Test("A view edited since its last run is serving stale data")
    func modifiedIsStale() throws {
        let view = try view("plan_value_rollup")
        #expect(view.status == .modified)
        #expect(view.materialization == .editedSinceRun)
        #expect(view.isServingStaleData)
        #expect(view.latestError == nil)
    }

    /// Materialised, completed, and no cadence at all. Notable, but not a
    /// failure — so it must not join the alarm.
    @Test("A materialised view with no cadence is unscheduled, not stale")
    func unscheduledIsNotStale() throws {
        let view = try view("activation_checkpoint")
        #expect(view.syncFrequency == nil)
        #expect(!view.hasRefreshSchedule)
        #expect(view.materialization == .unscheduled)
        #expect(!view.isServingStaleData)
    }

    /// `"never"` and an absent `sync_frequency` are two spellings PostHog's own
    /// contract gives the same meaning; folding them is the point.
    @Test("sync_frequency \"never\" reads as no schedule")
    func neverIsNoSchedule() throws {
        let view = try view("acquisition_origin")
        #expect(view.syncFrequency == "never")
        #expect(!view.hasRefreshSchedule)
    }

    @Test("A view with no stored table cannot be stale")
    func notMaterialisedIsNotStale() throws {
        let view = try view("acquisition_origin")
        #expect(!view.isMaterialized)
        #expect(view.materialization == .notMaterialized)
        #expect(!view.isServingStaleData)
    }

    @Test("A healthy materialised view is up to date")
    func healthyIsUpToDate() throws {
        let view = try view("billing_health")
        #expect(view.materialization == .upToDate)
        #expect(!view.isServingStaleData)
        #expect(view.hasRefreshSchedule)
    }

    /// A run in flight still carries the *previous* failure's `latest_error`.
    /// Reporting that as a current failure would tell someone their view is
    /// broken while it is in the middle of fixing itself.
    @Test("A running materialisation outranks the error it still carries")
    func runningOutranksStaleError() throws {
        let view = try view("renewal_watchlist")
        #expect(view.status == .running)
        #expect(view.latestError != nil)
        #expect(view.materialization == .running)
        #expect(!view.isServingStaleData)
    }

    @Test("Trouble sorts to the top")
    func severityOrdering() {
        let order = MaterializationState.allCases
            .sorted { $0.severity < $1.severity }
        #expect(order.first == .failed)
        #expect(order.last == .notMaterialized)
        // Every state has a distinct rank, or the sort is unstable in a way that
        // reorders the list between loads.
        #expect(Set(MaterializationState.allCases.map(\.severity)).count
            == MaterializationState.allCases.count)
    }

    @Test("Every state carries a word and a consequence")
    func everyStateSpeaks() {
        for state in MaterializationState.allCases {
            #expect(!state.title.isEmpty)
            #expect(!state.consequence.isEmpty)
            #expect(!state.systemImage.isEmpty)
        }
    }

    // MARK: - Lenient decoding

    /// The last fixture row omits eight optional keys and carries a status word
    /// that is in no published enum. It must decode, because a project with one
    /// unfamiliar row must not lose the other six.
    @Test("An unfamiliar row decodes rather than failing the page")
    func lenientRow() throws {
        let view = try view("governed_margin_view")
        #expect(view.status == .unknown)
        #expect(view.description == nil)
        #expect(view.createdBy == nil)
        #expect(view.createdAt == nil)
        #expect(view.folderName == nil)
        #expect(view.latestError == nil)
        // A column object with neither `key` nor `name` still yields an entry
        // rather than dropping the column silently.
        #expect(view.columns.count == 1)
        #expect(view.columns[0].name == "unnamed")
        // Materialised, a run recorded, an unrecognised status and no cadence.
        #expect(view.materialization == .unscheduled)
    }

    @Test("Empty strings decode as absent, not as content")
    func emptyStringsAreAbsent() throws {
        let view = try view("acquisition_origin")
        #expect(view.description == nil)
        #expect(view.latestError == nil)
    }

    /// An author with no first name set sends `""`, not null.
    @Test("A blank first name falls through to the email")
    func blankFirstNameFallsThrough() throws {
        #expect(try view("activation_checkpoint").createdBy == "analyst-05@example.org")
        #expect(try view("billing_health").createdBy == "Analyst Two")
    }

    @Test("A row with no columns and no cadence still has a summary line")
    func shapeSummaryNeverEmpty() throws {
        for row in try page().results {
            #expect(!row.shapeSummary.isEmpty)
        }
        #expect(try view("acquisition_origin").shapeSummary == "No columns reported")
        #expect(try view("billing_health").shapeSummary == "3 columns · every 1hour · Revenue lab")
    }
}

@Suite("Data modeling jobs")
struct DataModelingJobTests {
    private func page() throws -> Page<DataModelingJob> {
        try Page<DataModelingJob>.decode(from: Fixture.data("data_modeling_jobs.json"))
    }

    @Test("Decodes a run history")
    func decodes() throws {
        let page = try page()
        #expect(page.count == 5)
        #expect(page.results.count == 5)
        #expect(page.results.allSatisfy {
            $0.savedQueryID == "018f9000-0000-7000-8000-000000000362"
        })
    }

    @Test("A failed run reports its error")
    func failedRun() throws {
        let job = try #require(try page().results.first { $0.status == .failed })
        #expect(job.status == .failed)
        #expect(job.didFail)
        #expect(job.rowsMaterialized == 0)
        #expect(job.error?.contains("384 MiB") == true)
        // Zero here really is zero rows: `rows_materialized` is required and
        // non-nullable in the contract, unlike `WarehouseTable.rowCount`.
        #expect(job.rowSummary == "0 of 328,640 rows")
    }

    @Test("A run with no expected count says only what it knows")
    func unknownExpectedCount() throws {
        let job = try #require(try page().results.first { $0.status == .cancelled })
        #expect(job.rowsExpected == nil)
        #expect(job.rowSummary == "72,315 rows")
        // Empty error string is absence, not an error with no message.
        #expect(job.error == nil)
        // …but a cancelled run is still a failure to produce rows, and the row
        // must not read as a success.
        #expect(!job.didFail)
        #expect(job.status == .cancelled)
    }

    @Test("Duration comes from the gap, and is nil rather than zero when unknown")
    func duration() throws {
        let completed = try #require(try page().results.first { $0.status == .completed })
        let seconds = try #require(completed.duration)
        #expect(seconds == 275)

        let noDates = try JSONDecoder().decode(
            DataModelingJob.self,
            from: Data(#"{"id":"x","status":"Completed","rows_materialized":1}"#.utf8)
        )
        #expect(noDates.duration == nil)
        #expect(noDates.lastRunAt == nil)
    }

    /// The two-endpoint disagreement: the view claims to be fine while the
    /// selected job says otherwise, so the client reports the conflict without
    /// trying to diagnose it.
    @Test("A healthy-looking view whose newest job failed is flagged")
    func disagreement() throws {
        let views = try Page<SavedQuery>
            .decode(from: Fixture.data("warehouse_saved_queries.json")).results
        let healthy = try #require(views.first { $0.name == "billing_health" })
        let failing = try #require(try page().results.first { $0.status == .failed })

        #expect(healthy.disagreesWith(latestJob: failing))
        // A view already known to be stale is not "disagreeing" — it is
        // agreeing, and saying otherwise would double-report one problem.
        let known = try #require(views.first { $0.name == "stalled_hourly_accounts" })
        #expect(!known.disagreesWith(latestJob: failing))
        // Nor does a non-materialised view: there is no stored table to be
        // wrong about.
        let plain = try #require(views.first { $0.name == "acquisition_origin" })
        #expect(!plain.disagreesWith(latestJob: failing))
        #expect(!healthy.disagreesWith(latestJob: nil))
    }
}

@Suite("Data modeling endpoints")
struct DataModelingEndpointTests {
    @Test("The saved query list paginates by page number, never by limit")
    func listPaginatesByPage() {
        let endpoint = PostHogAPI.savedQueries(projectID: 1_001)
        #expect(endpoint.path == "/api/projects/1001/warehouse_saved_queries/")
        #expect(endpoint.method == "GET")
        #expect(endpoint.category == .crud)
        #expect(endpoint.query.contains { $0.name == "page" && $0.value == "1" })
        // `?limit=` is accepted and silently ignored by this endpoint, so
        // sending one would look like a cap and be none. The contract uses
        // page-number pagination here.
        #expect(!endpoint.query.contains { $0.name == "limit" })
    }

    @Test("Search is only sent when there is something to search for")
    func searchIsOptional() {
        #expect(!PostHogAPI.savedQueries(projectID: 1_001, search: "").query
            .contains { $0.name == "search" })
        #expect(PostHogAPI.savedQueries(projectID: 1_001, search: "mrr").query
            .contains { $0.name == "search" && $0.value == "mrr" })
    }

    @Test("The detail path is the only one that yields SQL")
    func detailPath() {
        let endpoint = PostHogAPI.savedQuery(projectID: 1_001, id: "abc")
        #expect(endpoint.path == "/api/projects/1001/warehouse_saved_queries/abc/")
        #expect(endpoint.category == .crud)
    }

    /// The jobs endpoint takes limit/offset while the saved-query list next to
    /// it takes a page number. Two neighbouring endpoints, two paginations —
    /// worth a test precisely because it is the kind of thing that gets
    /// "tidied" into consistency and then silently caps nothing.
    @Test("The jobs endpoint filters by saved query and does take a limit")
    func jobsEndpoint() {
        let endpoint = PostHogAPI.dataModelingJobs(projectID: 1_001, savedQueryID: "abc")
        #expect(endpoint.path == "/api/projects/1001/data_modeling_jobs/")
        #expect(endpoint.query.contains { $0.name == "saved_query_id" && $0.value == "abc" })
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "10" })
        #expect(endpoint.category == .crud)
    }
}
