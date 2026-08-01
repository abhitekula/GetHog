import Foundation
import Testing

@testable import GetHogKit

/// The dashboard list row carries more than a name.
///
/// These fields exist to make a list row worth its height. The list endpoint
/// does **not** include a tile count, so freshness and provenance are what the
/// row can honestly show instead.
@Suite("Dashboard summary rows")
struct DashboardSummaryTests {

    private func summaries() throws -> [DashboardSummary] {
        try Page<DashboardSummary>.decode(from: Fixture.data("dashboards_list.json")).results
    }

    @Test("decodes the freshness stamp, and leaves it absent when never computed")
    func decodesLastRefresh() throws {
        let all = try summaries()
        #expect(all.count == 11)
        #expect(all.map(\.id) == [
            725_101, 725_102, 725_103, 725_104, 725_105, 725_106,
            725_107, 725_108, 725_109, 725_110, 725_111,
        ])

        let pinned = try #require(all.first { $0.id == 725_101 })
        #expect(pinned.lastRefresh != nil)

        // The synthetic page deliberately carries both freshness states.
        let neverRefreshed = try #require(all.first { $0.id == 725_102 })
        #expect(neverRefreshed.lastRefresh == nil)
    }

    @Test("distinguishes generated dashboards from hand-made ones")
    func decodesCreationMode() throws {
        let all = try summaries()

        let handMade = try #require(all.first { $0.id == 725_101 })
        #expect(handMade.creationMode == .default)

        // Half the synthetic page is template-generated so provenance stays
        // visible without depending on a captured tenant.
        let generated = try #require(all.first { $0.id == 725_106 })
        #expect(generated.creationMode == .template)
    }

    @Test("survives a creation mode this client has never heard of")
    func unknownCreationMode() throws {
        let json = """
        {"id": 1, "name": "New", "pinned": false, "creation_mode": "teleported"}
        """
        let summary = try JSONDecoder().decode(DashboardSummary.self, from: Data(json.utf8))
        // PostHog ships new modes without asking us. An unrecognised one must
        // degrade to a plain row, never fail the whole page decode.
        #expect(summary.creationMode == .unknown)
    }

    @Test("decodes the shared flag")
    func decodesShared() throws {
        let all = try summaries()
        #expect(all.allSatisfy { !$0.isShared })
    }
}
