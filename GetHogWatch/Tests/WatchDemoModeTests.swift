import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch demo mode")
struct WatchDemoModeTests {

    @Test("either spelling of the switch enables the demo, and neither is the default")
    func enablementHonoursBothSpellings() {
        #expect(WatchDemoMode.isEnabled(arguments: ["GetHogWatch"], environment: [:]) == false)
        #expect(
            WatchDemoMode.isEnabled(
                arguments: ["GetHogWatch", WatchDemoMode.launchArgument], environment: [:]
            )
        )
        #expect(
            WatchDemoMode.isEnabled(
                arguments: ["GetHogWatch"],
                environment: [WatchDemoMode.environmentFlag: "1"]
            )
        )
        // Present but not "1" is not enabled: an empty or "0" value in an
        // inherited environment must not put a shipped app into demo mode.
        #expect(
            WatchDemoMode.isEnabled(
                arguments: ["GetHogWatch"],
                environment: [WatchDemoMode.environmentFlag: "0"]
            ) == false
        )
    }

    @Test("a demo session rejects live hand-off reconciliation")
    func demoOwnsItsSyntheticSession() {
        #expect(
            WatchDemoMode.allowsLiveHandoffs(
                arguments: ["GetHogWatch", WatchDemoMode.launchArgument],
                environment: [:]
            ) == false
        )
        #expect(
            WatchDemoMode.allowsLiveHandoffs(
                arguments: ["GetHogWatch"],
                environment: [WatchDemoMode.environmentFlag: "1"]
            ) == false
        )
        #expect(
            WatchDemoMode.allowsLiveHandoffs(
                arguments: ["GetHogWatch"], environment: [:]
            )
        )
    }

    @Test("the dashboards route answers with a page the kit can decode")
    func dashboardsRouteDecodes() throws {
        let reply = WatchDemoTransport.route(
            method: "GET", path: "/api/projects/1001/dashboards/", body: ""
        )

        #expect(reply.status == 200)
        let page = try Page<DashboardSummary>.decode(from: reply.data)
        #expect(page.results.contains { $0.pinned })
    }

    @Test("the dashboard detail route answers with tiles the watch can reduce")
    func dashboardDetailRouteReduces() throws {
        let reply = WatchDemoTransport.route(
            method: "GET", path: "/api/projects/1001/dashboards/725101/", body: ""
        )

        #expect(reply.status == 200)
        let dashboard = try JSONDecoder().decode(Dashboard.self, from: reply.data)
        let metrics = dashboard.tiles.compactMap {
            SharedSnapshot.Metric(tile: $0, dashboardID: dashboard.id)
        }
        // The two watches `WatchDemoMode.seededWatches` names must both find
        // their metric, or the Health page's demo is a pair of empty rows.
        let ids = Set(metrics.map(\.id))
        for watch in WatchDemoMode.seededWatches {
            #expect(ids.contains(watch.metricID))
        }
    }

    @Test("a flag write answers with the flag it claims to have changed")
    func flagWriteEchoesTheFlip() throws {
        let reply = WatchDemoTransport.route(
            method: "PATCH",
            path: "/api/projects/1001/feature_flags/710301/",
            body: #"{"active":false}"#
        )

        #expect(reply.status == 200)
        let flag = try JSONDecoder().decode(FeatureFlag.self, from: reply.data)
        #expect(flag.id == 710_301)
        #expect(flag.active == false)
    }

    @Test("an unrouted path is a stated gap, not a plausible blank")
    func unroutedPathIsStated() throws {
        let reply = WatchDemoTransport.route(
            method: "GET", path: "/api/projects/1001/experiments/", body: ""
        )

        #expect(reply.status == 501)
        let envelope = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
        #expect(envelope?["code"] as? String == "demo_fixture_missing")
    }

    @Test("the demo's own fixtures are in the bundle it will read them from")
    func fixturesAreBundled() {
        for name in [
            "users_me", "dashboards_list", "dashboard_detail_raw",
            "feature_flags", "error_tracking", "query_hogql",
        ] {
            #expect(WatchDemoTransport.loadData(name) != nil, "\(name).json is not bundled")
        }
    }

    @Test("the demo runs against a marker credential and a named synthetic project")
    func demoCredentialIsAMarker() {
        #expect(WatchDemoMode.credential.projectID == 1001)
        #expect(WatchDemoMode.projectName == "Starling Metrics Lab")
        #expect(WatchDemoMode.seededWatches.count == 2)
    }
}
