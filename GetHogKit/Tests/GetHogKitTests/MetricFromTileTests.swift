import Foundation
import Testing

@testable import GetHogKit

/// Reducing one dashboard tile to the single figure every small surface reads.
///
/// The rule lives in the kit because four processes now need it and none of
/// them is the phone app: the widget extension, the Mac menu bar, the watch
/// and the TV all render `SharedSnapshot.Metric` and none can reach
/// `AppModel`. What each branch is *allowed* to fill is the whole subject —
/// `previous` documents nil as "the comparison-period value is not known",
/// which is not "unchanged", and a branch that invents one reaches a Lock
/// Screen notification claiming a change that never happened.
///
/// Tiles are decoded from the shared dashboard fixture rather than built by
/// hand wherever it has the shape: that drives the real decoder, so a change to
/// how PostHog's payloads are read breaks these rather than passing them by
/// coincidence of a hand-written value.
@Suite("Dashboard tile reduced to a snapshot metric")
struct MetricFromTileTests {

    private static func tiles() throws -> [Tile] {
        try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json")).tiles
    }

    private static func tile(_ json: String) throws -> Tile {
        try JSONDecoder().decode(Tile.self, from: Data(json.utf8))
    }

    private static func tile(named name: String) throws -> Tile {
        try #require(try tiles().first { $0.insight?.name == name })
    }

    @Test("a tile with no insight reduces to nothing")
    func emptyTileIsNil() throws {
        let tile = try Self.tile(#"{"id": 1}"#)
        #expect(SharedSnapshot.Metric(tile: tile, dashboardID: 9) == nil)
    }

    @Test("a big number becomes the figure, with no comparison to speak of")
    func bigNumber() throws {
        let tile = try Self.tile("""
            {"id": 2, "insight": {"id": 78, "name": "Example total signups",
              "query": {"source": {"kind": "TrendsQuery",
                        "trendsFilter": {"display": "BoldNumber"}}},
              "result": [{"label": "signups", "aggregated_value": 1234}]}}
            """)
        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))

        // The id is the *insight's*, stringified, because that is what widget
        // configuration and `MetricWatch.metricID` round-trip.
        #expect(metric.id == "78")
        #expect(metric.title == tile.title)
        #expect(metric.value == 1234)
        #expect(metric.unit == nil)
        // An aggregate has no time axis and therefore no previous period. A
        // baseline invented here fires a change alert on the first wake.
        #expect(metric.previous == nil)
        #expect(metric.direction == .unknown)
        #expect(metric.sparkline.isEmpty)
        #expect(metric.dashboardID == 9)
    }

    @Test("a time series is the one shape entitled to a comparison")
    func timeSeries() throws {
        let tile = try Self.tile(named: "Example daily engagement")
        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))

        guard case .timeSeries(let series, _) = tile.renderModel,
              let first = series.first
        else {
            Issue.record("expected a time series")
            return
        }
        let values = first.points.map(\.value)

        // A trends series *is* a time axis, so its second-to-last point really
        // is the comparison period.
        #expect(metric.value == values.last)
        #expect(metric.previous == values[values.count - 2])
        // Oldest to newest, and capped: a widget draws a sparkline, not a year.
        #expect(metric.sparkline == Array(values.suffix(24)))
        #expect(metric.sparkline.count <= 24)
        #expect(metric.unit == nil)
    }

    @Test("a single-point series has a value but still no baseline")
    func singlePointTimeSeries() throws {
        let tile = try Self.tile("""
            {"id": 3, "insight": {"id": 79, "name": "Example one point",
              "query": {"source": {"kind": "TrendsQuery"}},
              "result": [{"label": "views", "data": [7], "days": ["2024-01-01"]}]}}
            """)
        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))

        #expect(metric.value == 7)
        #expect(metric.previous == nil)
        #expect(metric.direction == .unknown)
        #expect(metric.sparkline == [7])
    }

    @Test("an empty time series reduces to nothing rather than to zero")
    func emptyTimeSeriesIsNil() throws {
        // Zero is a measurement. "No points came back" is not, and a widget
        // showing a confident 0 for a tile that returned nothing is a lie the
        // freshness footer cannot correct.
        let tile = try Self.tile("""
            {"id": 4, "insight": {"id": 80, "name": "Example empty",
              "query": {"source": {"kind": "TrendsQuery"}},
              "result": [{"label": "views", "data": [], "days": []}]}}
            """)
        #expect(SharedSnapshot.Metric(tile: tile, dashboardID: 9) == nil)
    }

    @Test("a bar value takes the top bar, and its label is the unit")
    func barValue() throws {
        let tile = try Self.tile(named: "Example App metric 79")
        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))

        guard case .barValue(let bars) = tile.renderModel, let top = bars.first else {
            Issue.record("expected bar values")
            return
        }
        #expect(metric.value == top.value)
        // The breakdown value the figure belongs to — "Chrome", a country code
        // — which is the only honest thing to put beside the number.
        #expect(metric.unit == top.label)
        #expect(metric.previous == nil)
        #expect(metric.sparkline == bars.map(\.value))
    }

    @Test("a funnel headline carries no comparison, because a funnel has none")
    func funnel() throws {
        let tile = try Self.tile(named: "Example signup funnel by browser")
        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))

        guard case .funnel(let groups) = tile.renderModel,
              let last = groups.first?.steps.last
        else {
            Issue.record("expected a funnel")
            return
        }
        #expect(metric.value == last.count)

        // The defect this rule was written around. `previous` was once step 1
        // of the same funnel — a different axis entirely. A funnel is
        // monotonically non-increasing and its steps arrive step-1-first, so
        // the derived delta was negative with a guaranteed sign and a large
        // magnitude, forever, on every funnel tile.
        #expect(metric.previous == nil)
        #expect(metric.delta == nil)
        #expect(metric.deltaFraction == nil)
        #expect(metric.direction == .unknown)
        // "Oldest to newest" is the contract; a step profile is not a time axis.
        #expect(metric.sparkline.isEmpty)
    }

    @Test("a funnel cannot fire a percentage-change notification")
    func funnelNeverFiresAChangeAlert() throws {
        // The end of the chain, and the one that reached the Lock Screen.
        // `MetricWatchEvaluator` refuses to invent a baseline for exactly this
        // reason, and was being handed one from a layer up — so this pins the
        // seam rather than either side of it.
        let tile = try Self.tile(named: "Example signup funnel by browser")
        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: 9))
        let evaluation = MetricWatchEvaluator.evaluate(
            snapshot: SharedSnapshot(
                projectID: 42,
                projectName: "Example Analytics",
                metrics: [metric],
                flags: [],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            watches: [
                MetricWatch(
                    id: "w1",
                    metricID: metric.id,
                    title: metric.title,
                    condition: .changesByPercent(10)
                )
            ],
            breaching: []
        )

        #expect(evaluation.alerts.isEmpty)
        #expect(evaluation.breaching.isEmpty)
    }

    @Test("the shapes with no single headline figure are simply not offered")
    func gridsAndGraphsAreNil() throws {
        // Retention grids, lifecycle bands, stickiness curves and path graphs
        // have no one number, and picking one would be an invention rather
        // than a reduction.
        for name in ["Example App metric 58", "Example App metric 64"] {
            let tile = try Self.tile(named: name)
            #expect(SharedSnapshot.Metric(tile: tile, dashboardID: 9) == nil, "\(name)")
        }

        let unknown = try Self.tile("""
            {"id": 5, "insight": {"id": 81, "name": "Example unknown",
              "query": {"source": {"kind": "SomeFutureQuery"}}, "result": []}}
            """)
        #expect(SharedSnapshot.Metric(tile: unknown, dashboardID: 9) == nil)
    }

    @Test("an unknown dashboard is recorded as unknown, not as a destination")
    func dashboardIDMayBeAbsent() throws {
        // `nil` means "which dashboard this came from is not known", which
        // routes to the dashboards home. It must stay expressible: a caller
        // reducing a lone insight has no dashboard to name.
        let tile = try Self.tile(named: "Example daily engagement")
        let metric = try #require(SharedSnapshot.Metric(tile: tile, dashboardID: nil))
        #expect(metric.dashboardID == nil)
    }
}
