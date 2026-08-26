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
        case longIdentities = "long-identities"

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
            case .longIdentities:
                StoredCredential(
                    key: "synthetic-long-identities-key",
                    region: .usCloud,
                    projectID: 1002
                )
            }
        }

        var projectName: String {
            switch self {
            case .longIdentities:
                "Synthetic observatory routing — Candidate scope"
            default:
                "Synthetic rejected project"
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
        if scenario == .longIdentities {
            // Every page relaunch must consume this scenario's current
            // authored identities rather than a still-fresh snapshot from a
            // previous verification run.
            store.clearSnapshot()
            WatchActivity.clear(from: store)
            WatchFlagsReceipt.clear(from: store)
            return
        }

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

    static func transport() -> WatchDemoTransport { WatchDemoTransport() }

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
        case .longIdentities:
            if request.httpMethod == "GET", path.contains("/feature_flags/") {
                return reply(Self.longIdentityFlags, status: 200, request: request)
            }
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if path.hasSuffix("/query/"), body.contains("HogQLQuery") {
                return reply(Self.longIdentityActivity, status: 200, request: request)
            }
            return try await WatchDemoTransport().send(request)
        case .noCredential, .flagsLoading, .flagsEmpty:
            return try await WatchDemoTransport().send(request)
        }
    }

    private static let longIdentityFlags = Data(
        #"{"count":2,"next":null,"previous":null,"results":[{"id":720110,"key":"observatory-routing-control","active":true,"archived":false,"deleted":false},{"id":720111,"key":"observatory-routing-candidate","active":false,"archived":false,"deleted":false}]}"#.utf8
    )

    private static let longIdentityActivity: Data = {
        let sharedPrefix = "observatory-event"
        let object: [String: Any] = [
            "columns": ["uuid", "event", "timestamp", "distinct_id"],
            "results": [
                [
                    "synthetic-activity-001",
                    "\(sharedPrefix)_authorized",
                    "2026-01-18T12:03:00.000Z",
                    "synthetic-person-001",
                ],
                [
                    "synthetic-activity-002",
                    "\(sharedPrefix)_declined",
                    "2026-01-18T12:02:00.000Z",
                    "synthetic-person-002",
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }()

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
