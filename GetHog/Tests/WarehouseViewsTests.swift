import Foundation
import GetHogKit
import GetHogUI
import SwiftUI
import Testing
import UIKit

@testable import GetHog

// The warehouse's modelling section: saved queries, their materialisation state,
// and the one thing on the screen that is not visible anywhere else in PostHog's
// mobile surface — a view whose stored table is quietly older than the queries
// reading it.
//
// `GetHogKit`'s `DataModelingTests` covers the decoder and the state
// derivation. This covers the screen's side: what the store puts in front of the
// reader, and the two things about the demo fixtures that no compiler checks.

/// Serves one canned page per path, and records what was asked for.
///
/// Not `DemoTransport`, which now does route these paths: this stub is how the
/// store's own behaviour is isolated from what the fixtures happen to contain —
/// a canned 404, a rejected job filter and a `next` link are all states no demo
/// fixture holds. `DemoTransportTests.warehouseRoutesSplitPerView` and
/// `dataModelingJobsAreMatchedPerView` cover the routing itself.
private actor StubTransport: HTTPTransport {
    private let bodies: [String: Data]
    private let status: Int
    private(set) var requestedURLs: [URL] = []

    init(bodies: [String: Data], status: Int = 200) {
        self.bodies = bodies
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requestedURLs.append(url)
        let match = bodies.first { url.absoluteString.contains($0.key) }?.value
        let code = match == nil ? 404 : status
        let response = HTTPURLResponse(
            url: url, statusCode: code, httpVersion: nil, headerFields: nil
        )!
        return (match ?? Data(#"{"detail":"Not found."}"#.utf8), response)
    }
}

private func client(_ transport: some HTTPTransport) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
        transport: transport
    )
}

private struct MissingDemoFixture: Error, CustomStringConvertible {
    let name: String
    var description: String { "demo fixture \(name).json is not in the app bundle" }
}

/// Reads a demo fixture the way `DemoTransport.load` does — both bundle layouts,
/// because the resources are copied as a folder reference in some configurations
/// and flattened in others.
private func demoFixture(_ name: String) throws -> Data {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json")
        ?? Bundle.main.url(forResource: "DemoData/\(name)", withExtension: "json")
    else { throw MissingDemoFixture(name: name) }
    return try Data(contentsOf: url)
}

@Suite("Warehouse views")
@MainActor
struct WarehouseViewsTests {

    // MARK: - Glyphs

    /// Every glyph `MaterializationState` names resolves to a real symbol.
    ///
    /// `SymbolNameTests` explains why this needs its own test: its source scan
    /// finds names passed to a *labelled* symbol parameter, and these are bare
    /// string literals returned from `case` arms — the exact shape that put
    /// three invented names on screen as blank grey space. These arms are also
    /// in `GetHogKit`, which that scan does not read at all.
    @Test("Every materialisation state names a real SF Symbol")
    func stateGlyphsExist() {
        for state in MaterializationState.allCases {
            #expect(
                UIImage(systemName: state.systemImage) != nil,
                "\(state) names a symbol that does not exist: \(state.systemImage)"
            )
        }
    }

    /// Each state's tint has to be one `Theme.Status.ink(for:)` recognises, or
    /// the pill's word silently falls back to a neutral and loses the hue that
    /// tells the states apart. `StatusInkContrastTests` measures the contrast of
    /// exactly these five tints; this is what keeps the two lists the same list.
    @Test("Every state's tint is one the pill ink table knows")
    func stateTintsAreKnown() {
        let known: [Color] = [
            Theme.Status.critical, Theme.Status.good, Theme.accent, Theme.accentWarm, .secondary,
        ]
        for state in MaterializationState.allCases {
            let tint = materializationTint(state)
            #expect(
                known.contains(where: { $0 == tint }),
                "\(state) uses a tint outside the measured set"
            )
        }
    }

    // MARK: - Store

    @Test("The demo publishes source and table rows without a partial failure")
    func demoWarehouseStoreIsComplete() async {
        let store = WarehouseStore()
        await store.load(client: client(DemoTransport()), projectID: 1001)

        #expect(store.sourcesError == nil)
        #expect(store.tablesError == nil)
        #expect(Set(store.sources.map(\.displayName)) == ["S3", "Github (example_)"])
        #expect(Set(store.tables.map(\.name)) == [
            "demo_accounts", "example_pull_requests",
        ])
        #expect(store.loadedAt != nil)
        #expect(!store.isLoading)
    }

    private func loadedStore(_ fixture: String = "warehouse_saved_queries") async throws -> SavedQueryStore {
        let transport = StubTransport(
            bodies: ["warehouse_saved_queries": try demoFixture(fixture)]
        )
        let store = SavedQueryStore()
        await store.load(client: client(transport), projectID: 1)
        return store
    }

    @Test("Loads the demo fixture and sorts trouble to the top")
    func sortsTroubleFirst() async throws {
        let store = try await loadedStore()
        #expect(store.error == nil)
        #expect(store.views.count == 4)
        // Failed first, then edited-since-run, then healthy, then the plain view
        // — `MaterializationState.severity`, not alphabetical order.
        #expect(store.views.map(\.name) == [
            "example_meteor_delivery_failures",
            "example_orbital_signup_rollup",
            "example_comet_plan_summary",
            "example_moonbase_first_touch",
        ])
    }

    /// The banner's contents, and the reason the screen exists.
    @Test("Only views serving old rows reach the alert banner")
    func staleSelection() async throws {
        let store = try await loadedStore()
        #expect(store.stale.map(\.name) == [
            "example_meteor_delivery_failures", "example_orbital_signup_rollup",
        ])
        // The healthy one and the un-materialised one are not "less urgent" —
        // neither of them can be serving stale data at all.
        #expect(store.views.first { $0.name == "example_comet_plan_summary" }?.isServingStaleData == false)
        #expect(store.views.first { $0.name == "example_moonbase_first_touch" }?.isServingStaleData == false)
    }

    /// A failure here must not blank the screen; `WarehouseRoot` keeps sources
    /// and tables on it. The store's job is to report rather than to throw.
    @Test("A failed load leaves an error and no rows, not a crash")
    func failedLoad() async throws {
        let store = SavedQueryStore()
        await store.load(client: client(StubTransport(bodies: [:])), projectID: 1)
        #expect(store.views.isEmpty)
        #expect(store.error != nil)
        // Not marked as loaded: a freshness label saying "updated just now" over
        // an empty list is the exact failure `FreshnessLabel` exists to prevent.
        #expect(store.loadedAt == nil)
    }

    /// **The list endpoint paginates by page number and ignores `?limit=`**, so
    /// a project with more views than one page holds cannot be widened into one
    /// request. The screen has to say it is showing a prefix.
    @Test("A next link is carried through as a truncation flag")
    func reportsMorePages() async throws {
        var payload = try #require(
            try JSONSerialization.jsonObject(
                with: try demoFixture("warehouse_saved_queries")
            ) as? [String: Any]
        )
        payload["next"] = "https://us.posthog.com/api/projects/1/warehouse_saved_queries/?page=2"
        let transport = StubTransport(
            bodies: ["warehouse_saved_queries": try JSONSerialization.data(withJSONObject: payload)]
        )
        let store = SavedQueryStore()
        await store.load(client: client(transport), projectID: 1)
        #expect(store.hasMorePages)

        let honest = try await loadedStore()
        #expect(!honest.hasMorePages)
    }

    // MARK: - Detail store

    @Test("Definition and run history are fetched together")
    func detailLoadsBoth() async throws {
        let transport = StubTransport(bodies: [
            "warehouse_saved_queries/018f9000-0000-7000-8000-000000000400": try demoFixture("warehouse_saved_query_failed"),
            "data_modeling_jobs": try demoFixture("data_modeling_jobs"),
        ])
        let store = SavedQueryDetailStore()
        await store.load(
            client: client(transport),
            projectID: 1,
            id: "018f9000-0000-7000-8000-000000000400"
        )
        #expect(store.definitionError == nil)
        #expect(store.historyError == nil)
        #expect(store.detail?.query?.hasPrefix("SELECT") == true)
        #expect(store.jobs.count == 4)
        // Newest first, imposed rather than assumed — the endpoint's contract
        // does not pin an order.
        #expect(store.latestJob?.status == .failed)
        let newest = try #require(store.jobs.first?.lastRunAt)
        let oldest = try #require(store.jobs.last?.lastRunAt)
        #expect(newest > oldest)
    }

    /// `data_modeling_jobs` answers **HTTP 400** for a `saved_query_id` its
    /// filter does not recognise — represented by an authored response with an
    /// all-zeroes UUID. Losing the run history is not a reason to lose the
    /// definition the reader opened the screen for.
    @Test("A rejected job filter does not take the definition with it")
    func historyFailsAlone() async throws {
        let transport = StubTransport(bodies: [
            "warehouse_saved_queries/018f9000-0000-7000-8000-000000000400": try demoFixture("warehouse_saved_query_failed"),
        ])
        let store = SavedQueryDetailStore()
        await store.load(
            client: client(transport),
            projectID: 1,
            id: "018f9000-0000-7000-8000-000000000400"
        )
        #expect(store.detail != nil)
        #expect(store.detail?.query != nil)
        #expect(store.jobs.isEmpty)
        #expect(store.historyError != nil)
        #expect(store.definitionError == nil)
    }

    @Test("Two requests per opened view, and not one more on a second visit")
    func detailIsFetchedOnce() async throws {
        let transport = StubTransport(bodies: [
            "warehouse_saved_queries/018f9000-0000-7000-8000-000000000400": try demoFixture("warehouse_saved_query_failed"),
            "data_modeling_jobs": try demoFixture("data_modeling_jobs"),
        ])
        let store = SavedQueryDetailStore()
        let api = client(transport)
        await store.load(client: api, projectID: 1, id: "018f9000-0000-7000-8000-000000000400")
        await store.load(client: api, projectID: 1, id: "018f9000-0000-7000-8000-000000000400")
        // A `.task` re-firing on a width transition must not spend the budget
        // again; the rate limit is organisation-wide and shared.
        let requested = await transport.requestedURLs
        #expect(requested.count == 2)
    }

    // MARK: - Demo fixtures

    /// Decoding each fixture through the type its endpoint answers with, plus
    /// the cross-checks no decoder makes: that every detail is a row in the list
    /// and agrees with it, and that no run belongs to a view the reader cannot
    /// open. `DemoTransportTests` asserts that the right file reaches the right
    /// request; this asserts that the files agree with each other.
    @Test("Every demo fixture decodes as the shape its endpoint answers")
    func demoFixturesDecode() throws {
        let list = try Page<SavedQuery>.decode(from: demoFixture("warehouse_saved_queries"))
        #expect(list.results.count == 4)

        for name in [
            "warehouse_saved_query_failed",
            "warehouse_saved_query_modified",
            "warehouse_saved_query_healthy",
            "warehouse_saved_query_plain",
        ] {
            let detail = try JSONDecoder().decode(SavedQuery.self, from: demoFixture(name))
            // The one field the list serializer drops. A detail fixture without
            // it would draw "PostHog returned no SQL for this view", which reads
            // as a broken view rather than as a missing fixture.
            #expect(detail.query != nil, "\(name) carries no definition")
            // Every detail must be a row in the list, or a demo tap lands on a
            // view the list never showed.
            #expect(list.results.contains { $0.id == detail.id }, "\(name) is not in the list")
            #expect(
                list.results.first { $0.id == detail.id }?.name == detail.name,
                "\(name) disagrees with its list row about the view's name"
            )
        }

        for name in ["data_modeling_jobs", "data_modeling_jobs_healthy"] {
            let jobs = try Page<DataModelingJob>.decode(from: demoFixture(name))
            #expect(!jobs.results.isEmpty)
            // Runs that belong to no view in the list would show a history for a
            // view the reader cannot open.
            for job in jobs.results {
                #expect(list.results.contains { $0.id == job.savedQueryID }, "\(name) orphan run")
            }
        }
    }

    /// Authored fixtures should not retain provenance metadata from an earlier
    /// capture workflow. Their deterministic content is the contract.
    @Test("Authored demo fixtures omit capture provenance metadata")
    func syntheticFixturesOmitProvenance() throws {
        for name in [
            "warehouse_saved_queries",
            "warehouse_saved_query_failed",
            "warehouse_saved_query_modified",
            "warehouse_saved_query_healthy",
            "warehouse_saved_query_plain",
            "data_modeling_jobs",
            "data_modeling_jobs_healthy",
        ] {
            let object = try JSONSerialization.jsonObject(with: demoFixture(name)) as? [String: Any]
            #expect(object?["_note"] == nil, "\(name).json retains provenance metadata")
        }
    }

    /// The suspension section is only reachable from a detail payload that
    /// carries `suspended`, and the demo is the only place that payload exists.
    /// Without this fixture the worst state the screen can report would never be
    /// drawn, screenshotted or audited.
    @Test("The demo can reach the suspension section")
    func demoReachesSuspension() throws {
        let failed = try JSONDecoder().decode(
            SavedQuery.self, from: demoFixture("warehouse_saved_query_failed")
        )
        #expect(failed.isSuspended)
        #expect(failed.suspensions.first?.reason.isEmpty == false)

        // And the list row for that same view reports no suspension, because the
        // list serializer has no such field. Both halves of that asymmetry are
        // load-bearing: the banner cannot count suspensions, the detail can.
        let row = try #require(
            try Page<SavedQuery>.decode(from: demoFixture("warehouse_saved_queries"))
                .results.first { $0.id == failed.id }
        )
        #expect(!row.isSuspended)
    }

    /// The demo set has to span the states, or the screen ships with only its
    /// happy path ever seen.
    @Test("The demo covers a failure, a silent one, a healthy view and a plain one")
    func demoSpansTheStates() throws {
        let states = try Page<SavedQuery>
            .decode(from: demoFixture("warehouse_saved_queries"))
            .results.map(\.materialization)
        #expect(Set(states) == [.failed, .editedSinceRun, .upToDate, .notMaterialized])
    }
}
