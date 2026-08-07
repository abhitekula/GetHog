import Foundation
import GetHogKit
@testable import GetHogWatch

/// A transport that answers by **marker** rather than by call order.
///
/// A refresh spends five requests and the model fires them in a fixed order
/// today, but a test that encoded that order would fail the first time the
/// order changed for a reason nobody cares about. Routing on the path — and on
/// a substring of the body, which is how two `/query/` nodes are told apart —
/// keeps the fixtures pinned to the *request* instead.
///
/// An actor because the recording has to survive concurrent sends without a
/// lock of its own.
actor RouteTransport: HTTPTransport {

    struct Route: Sendable {
        let pathContains: String
        let bodyContains: String?
        let body: String
        let status: Int

        init(
            pathContains: String,
            bodyContains: String? = nil,
            body: String,
            status: Int = 200
        ) {
            self.pathContains = pathContains
            self.bodyContains = bodyContains
            self.body = body
            self.status = status
        }
    }

    private let routes: [Route]
    private(set) var requests: [URLRequest] = []

    init(routes: [Route]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path(percentEncoded: false) ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard let route = routes.first(where: {
            path.contains($0.pathContains) && ($0.bodyContains.map(body.contains) ?? true)
        }) else {
            throw PostHogError.transport("no route for \(path)")
        }
        return (
            Data(route.body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: route.status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    /// Every request's path and query, as one string per request — enough to
    /// assert what was asked for without a test reaching into `URLRequest`.
    func requestedPaths() -> [String] {
        requests.map { request in
            let url = request.url
            let path = url?.path(percentEncoded: false) ?? ""
            let query = url?.query.map { "?\($0)" } ?? ""
            return path + query
        }
    }

    func requestBodies() -> [String] {
        requests.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }
}

/// A transport that refuses everything — the offline case, which the model has
/// a specific and load-bearing answer for.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PostHogError.transport("offline")
    }
}

/// Synthetic fixtures, valid against the kit's real decoders. Every id, name
/// and number here is invented; nothing is copied from a PostHog response.
enum WatchFixtures {

    /// A fixed instant, so a capture time can be asserted exactly.
    static let now = Date(timeIntervalSince1970: 1_754_000_000)

    static let credential = StoredCredential(
        key: "test-key-0001", region: .usCloud, projectID: 1001
    )

    static let dashboards = #"""
        {"count":1,"next":null,"previous":null,
         "results":[{"id":9001,"name":"Example wrist board","pinned":true}]}
        """#

    /// Two reducible tiles: a trends line (501) and a bold number (502).
    static let dashboard = #"""
        {"id":9001,"name":"Example wrist board","pinned":true,"tiles":[
          {"id":1,"insight":{"id":501,"name":"Example signups",
            "query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
            "result":[{"label":"signups","count":6,"data":[1,2,3],
              "days":["2026-01-16","2026-01-17","2026-01-18"]}]}},
          {"id":2,"insight":{"id":502,"name":"Example total",
            "query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery",
              "trendsFilter":{"display":"BoldNumber"}}},
            "result":[{"label":"total","count":0,"data":[],"aggregated_value":393}]}}
        ]}
        """#

    static let flags = #"""
        {"count":3,"next":null,"previous":null,"results":[
          {"id":1,"key":"example-a","active":true},
          {"id":2,"key":"example-b","active":false},
          {"id":3,"key":"example-dead","active":true,"deleted":true}]}
        """#

    static let errors = #"""
        {"results":[
          {"id":"i1","name":"ExampleFault","status":"active",
           "aggregations":{"occurrences":29}},
          {"id":"i2","name":"QuietFault","status":"resolved",
           "aggregations":{"occurrences":99}}]}
        """#

    /// A `QueryResponse` shaped exactly as `recentEventLines` asks for it:
    /// four columns, no `properties`.
    static func events(_ count: Int) -> String {
        let rows = (0..<count).map { index in
            """
            ["example-row-\(String(format: "%04d", index))",\
            "example_event_\(index)",\
            "2026-01-18T12:00:00.000Z",\
            "person-example-\(index)"]
            """
        }
        return """
            {"columns":["uuid","event","timestamp","distinct_id"],
             "results":[\(rows.joined(separator: ","))]}
            """
    }

    /// The five routes a full refresh needs, in one place so a test that cares
    /// about one of them does not have to spell the other four.
    static func fullRefreshRoutes(
        dashboards: String = WatchFixtures.dashboards,
        dashboard: String = WatchFixtures.dashboard,
        flags: String = WatchFixtures.flags,
        errors: String = WatchFixtures.errors,
        events: String = WatchFixtures.events(3),
        extra: [RouteTransport.Route] = []
    ) -> [RouteTransport.Route] {
        extra + [
            .init(pathContains: "/dashboards/9001/", body: dashboard),
            .init(pathContains: "/dashboards/", body: dashboards),
            .init(pathContains: "/feature_flags/", body: flags),
            .init(pathContains: "/query/", bodyContains: "ErrorTrackingQuery", body: errors),
            .init(pathContains: "/query/", bodyContains: "HogQLQuery", body: events),
        ]
    }

    /// A store in its own temporary directory, so no test can read another's
    /// snapshot and none of them can reach the real App Group container.
    static func tempStore() -> SharedSnapshotStore {
        SharedSnapshotStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("GetHogWatchTests-\(UUID().uuidString)", isDirectory: true),
            isSharedContainer: false
        )
    }

    @MainActor
    static func model(
        transport: any HTTPTransport,
        store: SharedSnapshotStore,
        headline: String? = nil,
        watches: [MetricWatch] = [],
        authenticate: @escaping @Sendable (String) async -> Bool = { _ in true },
        watchesDegraded: Bool = false,
        now: Date = WatchFixtures.now
    ) -> WatchModel {
        WatchModel(
            credential: credential,
            projectName: "Synthetic Analytics",
            headlineMetricID: headline,
            watches: watches,
            transport: transport,
            store: store,
            authenticate: authenticate,
            watchesDegraded: watchesDegraded,
            now: { now }
        )
    }

    /// A snapshot to pre-seed a store with, when a test is about what happens
    /// to data that was already there.
    static func snapshot(
        metrics: [SharedSnapshot.Metric] = [
            SharedSnapshot.Metric(
                id: "501", title: "Example signups", value: 3, unit: nil,
                previous: 2, sparkline: [1, 2, 3], dashboardID: 9001
            ),
        ],
        capturedAt: Date = WatchFixtures.now
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001,
            projectName: "Synthetic Analytics",
            metrics: metrics,
            flags: [],
            capturedAt: capturedAt
        )
    }
}
