import Foundation
import GetHogKit

/// Deterministic, phone-free demo for the watch.
///
/// Fixtures only. Ships in Release like the phone's demo, so App Review can see
/// the whole app without a credential — and, more practically here, so the four
/// pages can be exercised on a simulator that has no paired phone to hand a key
/// across.
///
/// Two spellings of the switch, and both are load-bearing. `-GetHogDemo` is the
/// launch argument the phone already uses, kept so one habit works everywhere.
/// `GETHOG_DEMO=1` is the environment spelling, which is what an XCUITest's
/// `launchEnvironment` and `simctl`'s `SIMCTL_CHILD_` prefix can deliver — a
/// watchOS app launched by the Simulator MCP or by `simctl launch` takes
/// arguments, but a test host and a scheme action pass environment, and the
/// requirement is that demo mode works from either.
enum WatchDemoMode {
    static let launchArgument = "-GetHogDemo"
    static let environmentFlag = "GETHOG_DEMO"

    #if DEBUG
    /// Opt-in synthetic states whose network conditions cannot be reached by
    /// the fixture-backed happy-path demo. They remain DEBUG-only and require
    /// the ordinary demo switch as a second gate, so setting an unrelated
    /// environment value can never replace a live session.
    enum SyntheticScenario: String {
        case rejectedEU = "rejected-eu"
        case rejectedSelfHosted = "rejected-self-hosted"
        case noCredential = "no-credential"
        case flagsLoading = "flags-loading"
        case flagsEmpty = "flags-empty"
        case flagsCarriedFailure = "flags-carried-failure"

        var credential: StoredCredential? {
            switch self {
            case .rejectedEU:
                StoredCredential(
                    key: "synthetic-rejected-key",
                    region: .euCloud,
                    projectID: 1001
                )
            case .rejectedSelfHosted:
                StoredCredential(
                    key: "synthetic-rejected-key",
                    region: .selfHosted(URL(string: "https://watch.example.invalid")!),
                    projectID: 1001
                )
            case .noCredential:
                nil
            case .flagsLoading:
                StoredCredential(
                    key: "synthetic-flags-key",
                    region: .usCloud,
                    projectID: 1002
                )
            case .flagsEmpty:
                StoredCredential(
                    key: "synthetic-flags-key",
                    region: .usCloud,
                    projectID: 42
                )
            case .flagsCarriedFailure:
                StoredCredential(
                    key: "synthetic-flags-key",
                    region: .usCloud,
                    projectID: 77
                )
            }
        }
    }

    static var syntheticScenario: SyntheticScenario? {
        syntheticScenario(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func syntheticScenario(
        arguments: [String], environment: [String: String]
    ) -> SyntheticScenario? {
        guard isEnabled(arguments: arguments, environment: environment),
              let raw = environment["GETHOG_WATCH_SCENARIO"]
        else { return nil }
        return SyntheticScenario(rawValue: raw)
    }

    static func syntheticScenarioTransport(
        for scenario: SyntheticScenario
    ) -> any HTTPTransport {
        WatchSyntheticScenarioTransport(scenario: scenario)
    }

    /// Seeds the same-scope fallback required by the carried-failure render
    /// scenario before `WatchModel` reads the shared container. The fixed
    /// identity and timestamp are fictional and DEBUG-only.
    static func prepareSyntheticScenario(
        _ scenario: SyntheticScenario,
        in store: SharedSnapshotStore
    ) {
        guard scenario == .flagsCarriedFailure,
              let credential = scenario.credential,
              let projectID = credential.projectID
        else { return }

        let capturedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let snapshot = SharedSnapshot(
            projectID: projectID,
            projectName: "Synthetic retry project",
            metrics: [],
            flags: [
                SharedSnapshot.Flag(
                    id: 720_004,
                    key: "carried-navigation",
                    active: true,
                    quickToggleAllowed: false
                ),
            ],
            projectRegion: credential.region,
            capturedAt: capturedAt
        )
        try? store.write(snapshot)
        try? WatchFlagsReceipt(
            projectID: projectID,
            projectRegion: credential.region,
            capturedAt: capturedAt
        ).write(to: store)
    }
    #endif

    static var isEnabled: Bool {
        isEnabled(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// The rule, split from the process it usually reads, so both spellings and
    /// the default-off case are pinned without launching anything.
    static func isEnabled(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains(launchArgument) || environment[environmentFlag] == "1"
    }

    /// Demo state is a complete, synthetic session. A queued phone hand-off
    /// must not replace it with the live keychain/defaults state while App
    /// Review, a screenshot sweep, or an XCUITest is using it.
    static var allowsLiveHandoffs: Bool {
        allowsLiveHandoffs(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func allowsLiveHandoffs(
        arguments: [String], environment: [String: String]
    ) -> Bool {
        !isEnabled(arguments: arguments, environment: environment)
    }

    /// The synthetic identity `users_me.json` describes. The key is a marker,
    /// never sent anywhere real — `WatchDemoTransport` answers every request
    /// before a socket is opened.
    static let credential = StoredCredential(
        key: "demo", region: .usCloud, projectID: 1001
    )
    static let projectName = "Starling Metrics Lab"

    /// Two watches over the demo dashboard, chosen so the Health page shows
    /// both states deterministically: the daily-engagement tile's latest point
    /// is 55, so "above 40" fires, and the reach tile aggregates to 393, so
    /// "above 1000" stays quiet. Both ids name tiles on the pinned board in
    /// `dashboard_detail_raw.json`.
    static let seededWatches: [MetricWatch] = [
        MetricWatch(
            id: "demo-watch-engagement",
            metricID: "700010",
            title: "Example daily engagement",
            condition: .above(40)
        ),
        MetricWatch(
            id: "demo-watch-reach",
            metricID: "700018",
            title: "Example App metric 79",
            condition: .above(1000)
        ),
    ]

    static func transport() -> WatchDemoTransport { WatchDemoTransport() }

    // MARK: - Seeding the file the complications read

    /// The demo's thresholds, put where a *different process* can see them.
    ///
    /// Without this the demo is a demo of half the product. `seededWatches`
    /// reaches `WatchModel` in memory, so the app's Health page shows two
    /// thresholds and one of them firing — while every complication beside it
    /// reads `metric-watches.json` in the widget process, finds nothing, and
    /// says "No metric watches on this watch". The firing glyph, the alert
    /// card and the Smart Stack promotion are the entire reason those widgets
    /// exist, and nothing outside a unit test could show them.
    ///
    /// The obvious objection is the right one and is what the marker answers:
    /// synthetic thresholds must never survive into a real session, where they
    /// would sit in the user's own watch list, evaluate against their own
    /// numbers, and be indistinguishable from something they typed. So the
    /// demo *declares* what it wrote, and a live launch drops exactly that and
    /// nothing else — a watch list from a genuine phone hand-off carries no
    /// marker and is never touched.
    static func seedMarkerURL(in store: SharedSnapshotStore) -> URL {
        store.directory.appendingPathComponent("watch-demo-seeded-watches.json")
    }

    /// Called once per launch, before anything reads the watch list.
    ///
    /// One function rather than two call sites, so the demo branch and the
    /// live branch cannot drift apart: whichever launch this is, the container
    /// afterwards holds either the demo's thresholds or none of them.
    static func reconcileSeededWatches(
        in store: SharedSnapshotStore,
        demoEnabled: Bool = WatchDemoMode.isEnabled
    ) {
        demoEnabled ? seedWatches(into: store) : clearSeededWatches(from: store)
    }

    static func seedWatches(into store: SharedSnapshotStore) {
        // Best-effort, like every other write on this path: a demo that cannot
        // seed still runs, it just shows the quiet complication.
        try? store.writeMetricWatches(seededWatches)
        try? Data(seededWatchIDs.joined(separator: "\n").utf8)
            .write(to: seedMarkerURL(in: store), options: [.atomic])
    }

    /// Removes what a previous demo launch seeded, and only that.
    ///
    /// The marker alone is not enough to justify deleting the file: a phone
    /// hand-off may have landed since and replaced the list with the user's
    /// real thresholds, at which point the marker is stale and the file is
    /// theirs. So the ids are compared before anything is removed — a demo
    /// list is dropped, a real one is left exactly where it is, and the stale
    /// marker goes either way.
    static func clearSeededWatches(from store: SharedSnapshotStore) {
        let marker = seedMarkerURL(in: store)
        guard let data = try? Data(contentsOf: marker) else { return }
        let seeded = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        if store.metricWatches().map(\.id) == seeded {
            try? FileManager.default.removeItem(at: store.metricWatchesURL)
        }
        try? FileManager.default.removeItem(at: marker)
    }

    private static var seededWatchIDs: [String] { seededWatches.map(\.id) }

    #if DEBUG
    /// `GETHOG_WATCH_PAGE=metrics|health|flags|activity` opens the demo on one
    /// page, so all four can be screenshotted phone-free without driving the
    /// crown. DEBUG only: it is a verification affordance, not a feature.
    static var initialPage: String? {
        ProcessInfo.processInfo.environment["GETHOG_WATCH_PAGE"]
    }
    #endif
}

#if DEBUG
/// A complete transport boundary for otherwise unreachable render states.
/// Every branch is fixture-only and delegates ordinary routes to the authored
/// demo transport; no scenario can open a socket or consume a live budget.
private actor WatchSyntheticScenarioTransport: HTTPTransport {
    let scenario: WatchDemoMode.SyntheticScenario
    private var requestCount = 0
    private var flagsRequestCount = 0

    init(scenario: WatchDemoMode.SyntheticScenario) {
        self.scenario = scenario
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let path = request.url?.path(percentEncoded: false) ?? ""
        switch scenario {
        case .rejectedEU, .rejectedSelfHosted:
            try? await Task.sleep(for: .milliseconds(80))
            return reply(
                Data(#"{"detail":"Synthetic rejected credential."}"#.utf8),
                status: 401,
                request: request
            )
        case .flagsLoading where path.contains("/feature_flags/"):
            // Long enough for XCUITest to observe the first-load state before
            // this authored response releases the deterministic flag rows.
            try? await Task.sleep(for: .seconds(4))
            return try await WatchDemoTransport().send(request)
        case .flagsEmpty where path.contains("/feature_flags/"):
            try? await Task.sleep(for: .milliseconds(80))
            return reply(
                Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8),
                status: 200,
                request: request
            )
        case .flagsCarriedFailure:
            if path.contains("/feature_flags/") {
                flagsRequestCount += 1
                if flagsRequestCount == 1 {
                    return reply(
                        Data(#"{"detail":"Synthetic retryable failure."}"#.utf8),
                        status: 503,
                        request: request
                    )
                }
                if flagsRequestCount > 2 {
                    return reply(
                        Data(
                            #"{"count":1,"next":null,"previous":null,"results":[{"id":720099,"key":"unexpected-second-retry-generation","active":true,"archived":false,"deleted":false}]}"#.utf8
                        ),
                        status: 200,
                        request: request
                    )
                }
            }
            if requestCount == 6 {
                // Hold request one of the first retry generation long enough
                // for XCUITest to inspect stable failure, rows, and progress.
                try? await Task.sleep(for: .seconds(4))
            }
            return try await WatchDemoTransport().send(request)
        case .noCredential, .flagsLoading, .flagsEmpty:
            return try await WatchDemoTransport().send(request)
        }
    }

    private func reply(
        _ data: Data, status: Int, request: URLRequest
    ) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://watch.example.invalid")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}
#endif

/// Answers the five endpoints the watch calls, from the synthetic fixtures
/// bundled in the watch app.
///
/// Everything else is a 501 in an error shape that names the missing route, so
/// a gap in the demo is a *stated* gap rather than a plausible blank — the
/// failure mode a fixture-backed demo is otherwise very good at hiding.
struct WatchDemoTransport: HTTPTransport {

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // `path(percentEncoded: false)`, never `url.path`: `URL.path`
        // normalises the trailing slash away and every PostHog collection
        // endpoint ends in one, so `/feature_flags/` would arrive here as
        // `/feature_flags` and miss its route while detail paths still matched.
        // The phone's `DemoTransport` documents the same bug at its top.
        let path = request.url?.path(percentEncoded: false) ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let method = request.httpMethod ?? "GET"

        // A touch of latency so loading states render rather than flash.
        try? await Task.sleep(for: .milliseconds(80))

        return reply(Self.route(method: method, path: path, body: body), for: request)
    }

    /// Routing as a pure function of the three things a request is, so a test
    /// can ask what a path answers without building a `URLRequest`.
    static func route(method: String, path: String, body: String) -> Reply {
        // Writes route by method first: a PATCH and a GET share the flag's
        // path, and answering the write with the collection envelope would
        // fail to decode as one flag.
        if method == "PATCH", path.contains("/feature_flags/") {
            return flagAfterWrite(path: path, body: body) ?? unrouted(path)
        }
        if path.hasSuffix("/users/@me/") { return load("users_me") }
        if path.hasSuffix("/dashboards/") { return load("dashboards_list") }
        if path.contains("/dashboards/") { return load("dashboard_detail_raw") }
        if path.contains("/feature_flags/") { return load("feature_flags") }
        if path.hasSuffix("/query/") {
            if body.contains("ErrorTrackingQuery") { return load("error_tracking") }
            if body.contains("HogQLQuery") { return load("query_hogql") }
        }
        return unrouted(path)
    }

    struct Reply: Sendable {
        let data: Data
        let status: Int

        init(_ data: Data, status: Int = 200) {
            self.data = data
            self.status = status
        }
    }

    private func reply(_ reply: Reply, for request: URLRequest) -> (Data, HTTPURLResponse) {
        (
            reply.data,
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://us.posthog.com/")!,
                statusCode: reply.status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    /// The flag named in the path, with `active` moved to what the PATCH asked
    /// for — so a demo toggle answers with the flag it claims to have changed
    /// rather than with the stale fixture row.
    static func flagAfterWrite(path: String, body: String) -> Reply? {
        guard let page = loadData("feature_flags"),
              let object = try? JSONSerialization.jsonObject(with: page) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              var row = results.first(where: { row in
                  guard let id = row["id"] as? Int else { return false }
                  return path.contains("/feature_flags/\(id)/")
              }),
              let submitted = try? JSONSerialization.jsonObject(with: Data(body.utf8))
                  as? [String: Any],
              let active = submitted["active"] as? Bool
        else { return nil }
        row["active"] = active
        return (try? JSONSerialization.data(withJSONObject: row)).map { Reply($0) }
    }

    static func load(_ name: String) -> Reply {
        guard let data = loadData(name) else {
            return Reply(
                envelope(
                    "demo_fixture_unreadable",
                    "\(name).json is routed by WatchDemoTransport but is not in the app bundle."
                ),
                status: 500
            )
        }
        return Reply(data)
    }

    /// The same two-spellings lookup the phone's `DemoTransport` performs: the
    /// fixture set may land at the bundle root or under `DemoData/` depending
    /// on how the resource phase was wired, and neither is worth a build-time
    /// assumption.
    static func loadData(_ name: String, in bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: "DemoData/\(name)", withExtension: "json")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    static func unrouted(_ path: String) -> Reply {
        Reply(
            envelope("demo_fixture_missing", "The watch demo has no fixture for \(path)."),
            status: 501
        )
    }

    private static func envelope(_ code: String, _ detail: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "type": "demo_transport_error", "code": code, "detail": detail,
        ])) ?? Data(#"{"detail":"The watch demo has no fixture for this request."}"#.utf8)
    }
}
