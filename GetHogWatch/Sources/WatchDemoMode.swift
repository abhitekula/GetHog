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

    #if DEBUG
    /// `GETHOG_WATCH_PAGE=metrics|health|flags|activity` opens the demo on one
    /// page, so all four can be screenshotted phone-free without driving the
    /// crown. DEBUG only: it is a verification affordance, not a feature.
    static var initialPage: String? {
        ProcessInfo.processInfo.environment["GETHOG_WATCH_PAGE"]
    }
    #endif
}

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
