import Foundation
import Testing

@testable import GetHogKit

/// The CSV encoder against the deterministic fictional dashboard fixture.
///
/// Its own suite is entirely synthetic, which is right for the RFC 4180 rules but
/// leaves uncommon API shapes untested end to end: a bar-value
/// insight whose `data` is empty and whose figure hides in `aggregated_value`, a
/// funnel arriving as nested arrays, a lifecycle whose dormant counts are
/// negative. Those are decoding facts the encoder inherits, so this walks the
/// synthetic dashboard fixture and checks every tile exports something faithful.
@Suite("Insight CSV over synthetic dashboard data")
struct InsightCSVSyntheticDataTests {

    private func tiles() throws -> [Tile] {
        try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json")).tiles
    }

    @Test("every drawable tile in the synthetic dashboard exports rows")
    func everyDrawableTileExports() throws {
        let drawable = try tiles().filter {
            if case .unsupported = $0.renderModel { return false }
            return true
        }
        #expect(!drawable.isEmpty)

        for tile in drawable {
            let rows = InsightCSV.rows(tile.renderModel)
            #expect(rows != nil, "no rows for \(tile.title)")
            // Header plus at least one record: a header-only export from a tile
            // that visibly draws data means the encoder missed the shape.
            #expect((rows?.count ?? 0) > 1, "only a header for \(tile.title)")
        }
    }

    @Test("rows are rectangular, so columns cannot silently shift")
    func rowsAreRectangular() throws {
        for tile in try tiles() {
            guard let rows = InsightCSV.rows(tile.renderModel), let header = rows.first else { continue }
            for row in rows.dropFirst() {
                #expect(row.count == header.count, "ragged row in \(tile.title)")
            }
        }
    }

    @Test("the bar-value tile exports its aggregated figures, not empty cells")
    func barValueExportsAggregatedValues() throws {
        let tile = try #require(try tiles().first {
            if case .barValue = $0.renderModel { return true }
            return false
        })
        let rows = try #require(InsightCSV.rows(tile.renderModel))
        // `data` is empty on this shape; everything meaningful is in
        // `aggregated_value`, so a value column of blanks is the failure mode.
        let values = rows.dropFirst().map { $0[1] }
        #expect(values.allSatisfy { !$0.isEmpty })
        #expect(values.contains { (Double($0) ?? 0) > 0 })
    }

    @Test("the funnel tile exports one row per step, keeping step order")
    func funnelExportsStepsInOrder() throws {
        let tile = try #require(try tiles().first {
            if case .funnel = $0.renderModel { return true }
            return false
        })
        guard case .funnel(let groups) = tile.renderModel else { return }
        let rows = try #require(InsightCSV.rows(tile.renderModel))
        #expect(rows.count - 1 == groups.reduce(0) { $0 + $1.steps.count })

        // Counts must not increase down a funnel; if they do, breakdown groups
        // have been interleaved and the export is describing a funnel nobody ran.
        let firstGroupSteps = groups[0].steps.count
        let counts = rows.dropFirst().prefix(firstGroupSteps).compactMap { Double($0[3]) }
        #expect(counts == counts.sorted(by: >))
    }

    @Test("lifecycle dormant counts stay negative in the export")
    func lifecycleKeepsDormantNegative() throws {
        let tile = try tiles().first {
            if case .lifecycle = $0.renderModel { return true }
            return false
        }
        guard let tile, let rows = InsightCSV.rows(tile.renderModel) else { return }
        let dormant = rows.dropFirst().filter { $0[1].caseInsensitiveCompare("Dormant") == .orderedSame }
        #expect(!dormant.isEmpty)
        // Churn drawn below the axis has to stay signed in a spreadsheet too,
        // or summing the column reports growth where there was loss.
        #expect(dormant.contains { (Double($0[2]) ?? 0) < 0 })
    }

    @Test("encoded output escapes real labels and round-trips its own field count")
    func encodedOutputIsWellFormed() throws {
        for tile in try tiles() {
            guard let csv = InsightCSV.encode(tile.renderModel),
                  let rows = InsightCSV.rows(tile.renderModel),
                  let header = rows.first
            else { continue }

            #expect(csv.hasPrefix("\u{FEFF}"))
            // Synthetic breakdown labels include URLs with query strings, so any
            // unquoted comma here would split a record on the way into Excel.
            let firstLine = try #require(
                csv.dropFirst().split(separator: "\r\n", maxSplits: 1).first
            )
            #expect(parseFields(String(firstLine)).count == header.count)
        }
    }

    /// Minimal RFC 4180 reader, so the assertion above tests the encoder rather
    /// than agreeing with it.
    private func parseFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
