import Foundation

/// Turns a drawable insight into RFC 4180 CSV.
///
/// Export is a trust surface: a number that disagrees with the chart, or a
/// column that silently shifts because a breakdown value contained a comma, is
/// worse than no export button. Everything here is written to survive a
/// round-trip through Excel and Numbers unchanged.
public enum InsightCSV {

    /// The whole file, or `nil` when the model has nothing truthful to say.
    public static func encode(_ model: InsightRenderModel) -> String? {
        rows(model).map { encode(rows: $0) }
    }

    /// Header row followed by data rows, unescaped.
    ///
    /// Exposed alongside `encode` because the interesting behaviour is the row
    /// shape, and asserting on it directly beats parsing CSV back apart.
    public static func rows(_ model: InsightRenderModel) -> [[String]]? {
        switch model {
        case .timeSeries(let series, _):
            timeSeriesRows(series)

        case .barValue(let bars):
            [["Label", "Value"]] + bars.map { [$0.label, number($0.value)] }

        case .bigNumber(let big):
            [["Label", "Value"], [big.label, number(big.value)]]

        case .funnel(let groups):
            [["Breakdown", "Step", "Order", "Count", "Average conversion time (s)"]]
                + groups.flatMap { group in
                    group.steps.map { step in
                        [
                            group.breakdownValue ?? "",
                            step.name,
                            String(step.order),
                            number(step.count),
                            step.averageConversionTime.map(number) ?? "",
                        ]
                    }
                }

        case .lifecycle(let series):
            // Dormant counts stay negative: that is what the API returned and
            // what the chart draws below the axis. Taking the absolute value
            // here would turn churn into growth in a spreadsheet.
            [["Date", "Status", "Count"]]
                + series.flatMap { s in
                    s.points.map { [$0.day, s.status.title, number($0.value)] }
                }

        case .retention(let grid):
            [["Cohort", "Interval", "Count", "Rate"]]
                + grid.cohorts.flatMap { cohort in
                    cohort.counts.indices.map { index in
                        [
                            cohort.label,
                            String(index),
                            number(cohort.counts[index]),
                            number(rounded(cohort.rate(at: index))),
                        ]
                    }
                }

        case .stickiness(let series):
            [["Series", "Intervals", "Count"]]
                + series.flatMap { s in
                    s.buckets.map { [s.label, String($0.intervals), number($0.count)] }
                }

        case .paths(let graph):
            [["Source", "Target", "Value", "Average conversion time (s)"]]
                + graph.edges.map { edge in
                    [
                        edge.source,
                        edge.target,
                        number(edge.value),
                        edge.averageConversionTime.map(number) ?? "",
                    ]
                }

        case .unsupported:
            nil
        }
    }

    /// HogQL results, whose rows are positional arrays of mixed JSON types.
    public static func encode(columns: [String], rows: [[JSONValue]]) -> String {
        let body = rows.map { row in
            (0..<columns.count).map { index in
                index < row.count ? scalar(row[index]) : ""
            }
        }
        return encode(rows: [columns] + body)
    }

    // MARK: - Layout

    /// Wide format: one row per day, one column per series.
    ///
    /// Series can disagree about which days they cover — a breakdown value that
    /// only appeared mid-period has no reading for the earlier days. Those cells
    /// stay empty rather than becoming `0`, because a missing measurement and a
    /// measured zero are different facts and averaging over them differs.
    private static func timeSeriesRows(_ series: [Series]) -> [[String]] {
        var days: [String] = []
        var rowOfDay: [String: Int] = [:]
        var cells: [[String?]] = []

        for (column, one) in series.enumerated() {
            for point in one.points {
                let row: Int
                if let existing = rowOfDay[point.day] {
                    row = existing
                } else {
                    row = days.count
                    rowOfDay[point.day] = row
                    days.append(point.day)
                    cells.append(Array(repeating: nil, count: series.count))
                }
                cells[row][column] = number(point.value)
            }
        }

        return [["Date"] + series.map(\.label)]
            + zip(days, cells).map { day, row in [day] + row.map { $0 ?? "" } }
    }

    // MARK: - Encoding

    private static func encode(rows: [[String]]) -> String {
        // Excel guesses the encoding of a .csv and gets UTF-8 wrong without a
        // BOM, which mojibakes every non-ASCII breakdown value. Costs three
        // bytes; saves every export that isn't pure ASCII.
        "\u{FEFF}" + rows.map { $0.map(field).joined(separator: ",") }
            .joined(separator: "\r\n")
    }

    /// Scalars that force a field to be quoted, per RFC 4180.
    private static let reserved: Set<Unicode.Scalar> = [",", "\"", "\r", "\n"]

    static func field(_ value: String) -> String {
        // Scanned as scalars, not Characters: Swift folds "\r\n" into a single
        // Character, so a Character-level search for "\r" or "\n" misses a
        // field that would otherwise split the record in two.
        guard value.unicodeScalars.contains(where: reserved.contains) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Values

    /// Renders a measurement without locale interference.
    ///
    /// Deliberately not `formatted()`: a grouping separator would put a comma
    /// inside a numeric field, and a decimal comma in most of Europe would do
    /// the same. CSV numbers have to be machine-readable, not presentable.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 9e15 {
            return String(Int(value))
        }
        return String(value)
    }

    /// Retention rate is derived from counts that are already in the same row,
    /// so trimming its binary-float tail loses nothing and spares the reader
    /// sixteen digits of noise.
    private static func rounded(_ rate: Double) -> Double {
        (rate * 10_000).rounded() / 10_000
    }

    private static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .null: ""
        case .string(let s): s
        case .bool(let b): String(b)
        case .number(let d): number(d)
        case .array, .object: serialized(value)
        }
    }

    /// Nested columns (`properties`, arrays from `groupArray`) are often the
    /// point of a HogQL export, so they go out as JSON text rather than being
    /// flattened away to an empty cell.
    private static func serialized(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
