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
    ///
    /// This is the shape every `/query/` response has — the console's, the
    /// events feed's, web analytics' — so it is the one entry point those
    /// screens need. Prefer `data(columns:rows:)` when the result may be large;
    /// this convenience adds a second full copy of the file.
    public static func encode(columns: [String], rows: [[JSONValue]]) -> String {
        String(decoding: data(columns: columns, rows: rows), as: UTF8.self)
    }

    /// The same file as bytes, without ever materialising it as a `String`.
    ///
    /// A HogQL result is unbounded and a `String` round-trip doubles it — see
    /// the note above `appendRow` for the measurements that made this the
    /// primary entry point rather than a variant of one.
    public static func data(columns: [String], rows: [[JSONValue]]) -> Data {
        var out = Data(bom)
        // A reserve, not a bound. `Data` already grows geometrically, so this
        // only changes how many times a large buffer is reallocated and copied
        // — never what is written, and never whether it fits. 24 bytes a cell
        // is a guess, stated as one: it is roughly a short id or a formatted
        // number, and a result full of serialised `properties` objects will
        // exceed it and simply grow.
        out.reserveCapacity(min((rows.count + 1) * columns.count * 24 + 1024, 256 << 20))
        appendRow(columns, to: &out, isFirst: true)

        // Exactly one row's worth of `String`s exists at a time, reused. That is
        // the whole point: the alternative builds a `[[String]]` of the entire
        // result and holds it alongside the bytes it was rendered into.
        var fields = [String](repeating: "", count: columns.count)
        for row in rows {
            for index in 0..<columns.count {
                fields[index] = index < row.count ? scalar(row[index]) : ""
            }
            appendRow(fields, to: &out, isFirst: false)
        }
        return out
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

    /// A table whose cells are already text — a screen that decoded its rows
    /// into structs and has no `JSONValue` left to offer.
    public static func encode(rows: [[String]]) -> String {
        String(decoding: data(rows: rows), as: UTF8.self)
    }

    public static func data(rows: [[String]]) -> Data {
        var out = Data(bom)
        for (index, row) in rows.enumerated() {
            appendRow(row, to: &out, isFirst: index == 0)
        }
        return out
    }

    /// UTF-8 BOM.
    ///
    /// Excel guesses the encoding of a .csv and gets UTF-8 wrong without one,
    /// which mojibakes every non-ASCII breakdown value. Costs three bytes; saves
    /// every export that isn't pure ASCII.
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static let crlf: [UInt8] = [0x0D, 0x0A]
    private static let comma: UInt8 = 0x2C

    /// The one place a record is written.
    ///
    /// **Why the bytes are assembled here rather than `joined` into a `String`.**
    /// An insight's CSV is a few hundred cells and either approach is fine. A
    /// HogQL result is not bounded at all: measured 2026-07-30 against project
    /// [REMOVED PRIVATE DATA], `POST /query/` applies **no row cap of its own** — `SELECT number
    /// FROM numbers(50000)` returns all 50,000 rows — and a realistic
    /// `SELECT uuid, event, timestamp, distinct_id, properties FROM events`
    /// measured **6,764 bytes per row**, 13.5 MB at 2,000 rows. Building that as
    /// a `String` and then copying it with `Data(csv.utf8)` holds two full
    /// copies at once, on top of the decoded rows the screen is still showing.
    ///
    /// The separator is written *before* each record but the first, so the file
    /// ends without a trailing CRLF. That is the shape the existing tests pin,
    /// and RFC 4180 permits either.
    private static func appendRow(_ fields: [String], to out: inout Data, isFirst: Bool) {
        if !isFirst { out.append(contentsOf: crlf) }
        for (index, value) in fields.enumerated() {
            if index > 0 { out.append(comma) }
            out.append(contentsOf: field(value).utf8)
        }
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
    ///
    /// Public because a screen that decoded its rows into structs has to flatten
    /// them itself, and every such screen writing its own number formatting is
    /// how two exports from one app come to disagree about what `41.2` means.
    /// Web analytics is the case in point: it formats for reading — `41.2%`,
    /// `2m 13s`, compact notation — and none of those belong in a CSV cell.
    public static func number(_ value: Double) -> String {
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
