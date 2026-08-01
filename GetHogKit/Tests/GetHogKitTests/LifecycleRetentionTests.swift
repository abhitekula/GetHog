import Foundation
import Testing

@testable import GetHogKit

@Suite("Lifecycle insights")
struct LifecycleTests {

    @Test("decodes the four lifecycle statuses")
    func decodesLifecycle() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))

        guard case .lifecycle(let series) = dashboard.tiles[2].renderModel else {
            Issue.record("expected .lifecycle, got \(dashboard.tiles[2].renderModel)")
            return
        }

        #expect(series.count == 4)
        #expect(series.map(\.status) == [.new, .returning, .resurrecting, .dormant])
        #expect(series[0].points.count == 5)
    }

    @Test("keeps dormant counts negative so the chart renders below the axis")
    func dormantIsNegative() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        guard case .lifecycle(let series) = dashboard.tiles[2].renderModel else { return }

        let dormant = try #require(series.first { $0.status == .dormant })
        #expect(dormant.total == -52.7)
        #expect(dormant.points.allSatisfy { $0.value <= 0 })

        // Churn is a loss, so it must not be summed with growth as though positive.
        let returning = try #require(series.first { $0.status == .returning })
        #expect(returning.total == 52.7)
    }

    @Test("maps an unrecognised status without dropping the series")
    func unknownStatus() {
        let dto = TrendsSeriesDTO(
            label: "x - wat", count: 1, data: [1], days: ["2025-06-18"],
            aggregatedValue: nil, status: "wat"
        )
        #expect(dto.lifecycleStatus == .other)
    }
}

@Suite("Retention insights")
struct RetentionTests {

    @Test("decodes cohorts and their interval counts")
    func decodesRetention() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))

        guard case .retention(let grid) = dashboard.tiles[3].renderModel else {
            Issue.record("expected .retention, got \(dashboard.tiles[3].renderModel)")
            return
        }

        #expect(grid.cohorts.count == 2)
        #expect(grid.cohorts[0].label == "Example App segment 67")
        #expect(grid.cohorts[0].counts.count == 11)
        #expect(grid.cohorts[0].counts[0] == 372.7)
        #expect(grid.cohorts[0].counts[1] == 4.7)
        #expect(grid.cohorts[0].date != nil)
    }

    @Test("computes retention rates relative to each cohort's own first interval")
    func retentionRates() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        guard case .retention(let grid) = dashboard.tiles[3].renderModel else { return }

        let first = grid.cohorts[0]
        #expect(first.rate(at: 0) == 1.0)
        #expect(abs(first.rate(at: 1) - (4.7 / 372.7)) < 0.0001)

        // A cohort with a zero base must not divide by zero.
        let empty = RetentionCohort(label: "Empty", date: nil, counts: [0, 0])
        #expect(empty.rate(at: 1) == 0)
    }

    @Test("reports the widest cohort so the grid can size its columns")
    func gridWidth() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        guard case .retention(let grid) = dashboard.tiles[3].renderModel else { return }
        #expect(grid.intervalCount == 11)
    }
}
