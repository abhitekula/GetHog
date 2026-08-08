import Foundation

/// Displays supported by PostHog's `DataVisualizationNode` renderer.
public enum HogQLDisplay: Sendable, Equatable {
    case auto
    case table
    case line
    case area
    case bar
    case stackedBar
    case pie
    case heatmap
    case boldNumber
    case unsupported(String)

    init(apiValue: String?) {
        switch apiValue {
        case nil, "ActionsTable": self = .table
        case "Auto": self = .auto
        case "ActionsLineGraph": self = .line
        case "ActionsAreaGraph": self = .area
        case "ActionsBar": self = .bar
        case "ActionsStackedBar": self = .stackedBar
        case "ActionsPie": self = .pie
        case "TwoDimensionalHeatmap": self = .heatmap
        case "BoldNumber": self = .boldNumber
        case .some(let value): self = .unsupported(value)
        }
    }
}

/// PostHog's friendly classification of a ClickHouse column type.
public enum HogQLColumnScalar: String, Sendable, Equatable {
    case integer
    case float
    case decimal
    case date
    case dateTime
    case boolean
    case string
    case tuple
    case array
    case unknown

    init(typeName: String?) {
        guard let typeName else { self = .unknown; return }
        if typeName.contains("Array") { self = .array }
        else if typeName.contains("Tuple") { self = .tuple }
        else if typeName.contains("Int") { self = .integer }
        else if typeName.contains("Float") { self = .float }
        else if typeName.contains("DateTime") { self = .dateTime }
        else if typeName.contains("Date") { self = .date }
        else if typeName.contains("Boolean") || typeName.contains("Bool") { self = .boolean }
        else if typeName.contains("Decimal") { self = .decimal }
        else if typeName.contains("String") { self = .string }
        else { self = .unknown }
    }

    public var isNumeric: Bool {
        self == .integer || self == .float || self == .decimal
    }

    public var isDate: Bool { self == .date || self == .dateTime }
}

public struct HogQLColumn: Sendable, Equatable, Identifiable {
    public let name: String
    public let typeName: String?
    public let scalar: HogQLColumnScalar
    let sourceIndex: Int

    public var id: String { name }

    init(name: String, typeName: String?, sourceIndex: Int) {
        self.name = name
        self.typeName = typeName
        self.scalar = HogQLColumnScalar(typeName: typeName)
        self.sourceIndex = sourceIndex
    }
}

public struct HogQLHeatmapSettings: Sendable, Equatable, Decodable {
    public let xAxisColumn: String?
    public let yAxisColumn: String?
    public let valueColumn: String?

    public init(xAxisColumn: String? = nil, yAxisColumn: String? = nil, valueColumn: String? = nil) {
        self.xAxisColumn = xAxisColumn
        self.yAxisColumn = yAxisColumn
        self.valueColumn = valueColumn
    }
}

private struct HogQLAxisSettings: Sendable, Equatable, Decodable {
    struct Display: Sendable, Equatable, Decodable { let label: String? }
    let display: Display?
}

private struct HogQLAxis: Sendable, Equatable, Decodable {
    let column: String
    let settings: HogQLAxisSettings?
}

public struct HogQLChartSettings: Sendable, Equatable, Decodable {
    private let decodedXAxis: HogQLAxis?
    private let decodedYAxis: [HogQLAxis]
    public let showNullsAsZero: Bool
    public let heatmap: HogQLHeatmapSettings

    public var xAxis: String? { decodedXAxis?.column }
    public var yAxes: [String] { decodedYAxis.map(\.column) }

    enum CodingKeys: String, CodingKey { case xAxis, yAxis, showNullsAsZero, heatmap }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decodedXAxis = try? c.decodeIfPresent(HogQLAxis.self, forKey: .xAxis)
        decodedYAxis = (try? c.decodeIfPresent([HogQLAxis].self, forKey: .yAxis)) ?? []
        showNullsAsZero = (try? c.decodeIfPresent(Bool.self, forKey: .showNullsAsZero)) ?? false
        heatmap = (try? c.decodeIfPresent(HogQLHeatmapSettings.self, forKey: .heatmap))
            ?? HogQLHeatmapSettings()
    }

    init() {
        decodedXAxis = nil
        decodedYAxis = []
        showNullsAsZero = false
        heatmap = HogQLHeatmapSettings()
    }

    func label(for column: String) -> String? {
        decodedYAxis.first(where: { $0.column == column })?.settings?.display?.label
    }
}

private struct HogQLTableColumnSetting: Sendable, Equatable, Decodable {
    let column: String
}

public struct HogQLTableSettings: Sendable, Equatable, Decodable {
    private let decodedColumns: [HogQLTableColumnSetting]
    public let transpose: Bool

    public var columnOrder: [String] { decodedColumns.map(\.column) }

    enum CodingKeys: String, CodingKey { case columns, transpose }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decodedColumns = (try? c.decodeIfPresent([HogQLTableColumnSetting].self, forKey: .columns)) ?? []
        transpose = (try? c.decodeIfPresent(Bool.self, forKey: .transpose)) ?? false
    }

    init() {
        decodedColumns = []
        transpose = false
    }
}

public struct HogQLDisplayedTable: Sendable, Equatable {
    public let columns: [HogQLColumn]
    public let rows: [[JSONValue]]
}

public enum HogQLAxisValue: Sendable, Equatable, Hashable {
    case category(String)
    case number(Double)
    /// The original ISO date spelling, retained so table and chart agree.
    case date(String)

    public var label: String {
        switch self {
        case .category(let value), .date(let value): value
        case .number(let value): JSONValue.number(value).stringValue ?? ""
        }
    }
}

public struct HogQLChartPoint: Sendable, Equatable, Identifiable {
    public let row: Int
    public let x: HogQLAxisValue
    public let value: Double
    public var id: Int { row }
}

public struct HogQLChartSeries: Sendable, Equatable, Identifiable {
    public let column: HogQLColumn
    public let label: String
    public let points: [HogQLChartPoint]
    public var id: String { column.name }
}

public struct HogQLChartData: Sendable, Equatable {
    public let xColumn: HogQLColumn
    public let series: [HogQLChartSeries]
}

public struct HogQLPieSlice: Sendable, Equatable, Identifiable {
    public let label: String
    public let value: Double
    public var id: String { label }
}

public struct HogQLHeatmapCell: Sendable, Equatable, Identifiable {
    public let x: String
    public let y: String
    public let value: Double
    public var id: String { "\(x)\u{1F}\(y)" }
}

public struct HogQLHeatmapData: Sendable, Equatable {
    public let xLabels: [String]
    public let yLabels: [String]
    public let cells: [HogQLHeatmapCell]
    public let wasTruncated: Bool
}

/// The query result needed to draw a PostHog `DataVisualizationNode`.
public struct HogQLVisualization: Sendable, Equatable {
    public let display: HogQLDisplay
    public let columns: [HogQLColumn]
    /// `nil` is uncomputed; `[]` is a successful result with no matching rows.
    public let rows: [[JSONValue]]?
    public let hasMore: Bool
    public let chart: HogQLChartSettings
    public let table: HogQLTableSettings

    public var isComputed: Bool { rows != nil }

    init(
        display: String?,
        columnNames: [String],
        types: [[String]]?,
        rows: [[JSONValue]]?,
        hasMore: Bool,
        chart: HogQLChartSettings?,
        table: HogQLTableSettings?
    ) {
        self.display = HogQLDisplay(apiValue: display)
        let observedWidth = rows?.map(\.count).max() ?? 0
        let columnCount = max(columnNames.count, types?.count ?? 0, observedWidth)
        self.columns = (0..<columnCount).map { index in
            let suppliedName = columnNames.indices.contains(index) ? columnNames[index] : nil
            let name = suppliedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Column \(index + 1)"
            let typeName = types.flatMap { $0.indices.contains(index) ? $0[index].dropFirst().first : nil }
            return HogQLColumn(name: name, typeName: typeName, sourceIndex: index)
        }
        self.rows = rows
        self.hasMore = hasMore
        self.chart = chart ?? HogQLChartSettings()
        self.table = table ?? HogQLTableSettings()
    }

    public var resolvedDisplay: HogQLDisplay {
        guard display == .auto else { return display }
        let hasDate = columns.contains(where: { $0.scalar.isDate })
        let hasNumeric = columns.contains(where: { $0.scalar.isNumeric })
        if hasDate, hasNumeric, (rows?.count ?? 0) > 1 { return .line }
        let stringCount = columns.count(where: { $0.scalar == .string })
        let numericCount = columns.count(where: { $0.scalar.isNumeric })
        if stringCount >= 2, numericCount >= 1 { return .heatmap }
        if numericCount == 1, columns.count == 1 { return .boldNumber }
        if numericCount > 0 { return .bar }
        return .table
    }

    public var displayedTable: HogQLDisplayedTable {
        let selected: [HogQLColumn]
        if table.columnOrder.isEmpty {
            selected = columns
        } else {
            selected = table.columnOrder.compactMap { name in columns.first(where: { $0.name == name }) }
        }
        let effectiveColumns = selected.isEmpty ? columns : selected
        let sourceRows = (rows ?? []).map { row in
            effectiveColumns.map { column in
                row.indices.contains(column.sourceIndex) ? row[column.sourceIndex] : .null
            }
        }
        guard table.transpose, !sourceRows.isEmpty else {
            return HogQLDisplayedTable(columns: effectiveColumns, rows: sourceRows)
        }

        let transposedColumns = [
            HogQLColumn(name: "Field", typeName: "String", sourceIndex: 0)
        ] + sourceRows.indices.map {
            HogQLColumn(name: "Row \($0 + 1)", typeName: "String", sourceIndex: $0 + 1)
        }
        let transposedRows = effectiveColumns.indices.map { columnIndex in
            [.string(effectiveColumns[columnIndex].name)] + sourceRows.map { $0[columnIndex] }
        }
        return HogQLDisplayedTable(columns: transposedColumns, rows: transposedRows)
    }

    public var configurationIssue: String? {
        switch resolvedDisplay {
        case .line, .area, .bar, .stackedBar, .pie:
            let selection = chartSelection
            if let issue = selection.issue { return issue }
            guard let rows, !rows.isEmpty else { return nil }
            let values = plottedValues(in: rows, columns: selection.y)
            guard !values.isEmpty else {
                return "The selected series has no plottable numeric values; showing the table instead."
            }
            if resolvedDisplay == .pie, values.contains(where: { $0 < 0 }) {
                return "Pie charts cannot represent negative values; showing the table instead."
            }
            return nil
        case .heatmap:
            return heatmapSelection.issue
        case .unsupported(let value):
            return "Unsupported HogQL display: \(value)"
        default:
            return nil
        }
    }

    public var chartData: HogQLChartData? {
        guard configurationIssue == nil,
              let xColumn = chartSelection.x,
              !chartSelection.y.isEmpty
        else { return nil }

        let sourceRows = rows ?? []
        let series = chartSelection.y.map { yColumn in
            let points = sourceRows.enumerated().compactMap { rowIndex, row -> HogQLChartPoint? in
                guard row.indices.contains(xColumn.sourceIndex), row.indices.contains(yColumn.sourceIndex) else {
                    return nil
                }
                let rawY = row[yColumn.sourceIndex]
                let value: Double
                if rawY.isNull, chart.showNullsAsZero { value = 0 }
                else if let decoded = rawY.doubleValue { value = decoded }
                else { return nil }
                return HogQLChartPoint(row: rowIndex, x: axisValue(row[xColumn.sourceIndex], column: xColumn), value: value)
            }
            return HogQLChartSeries(
                column: yColumn,
                label: chart.label(for: yColumn.name) ?? yColumn.name,
                points: points
            )
        }
        return HogQLChartData(xColumn: xColumn, series: series)
    }

    public var pieSlices: [HogQLPieSlice] {
        guard let data = chartData else { return [] }
        let multipleSeries = data.series.count > 1
        return data.series.flatMap { series in
            series.points.map { point in
                let base = point.x.label.isEmpty ? "(no value)" : point.x.label
                return HogQLPieSlice(
                    label: multipleSeries ? "\(base) · \(series.label)" : base,
                    value: point.value
                )
            }
        }
    }

    public var boldNumber: JSONValue? { displayedTable.rows.first?.first }

    public var heatmap: HogQLHeatmapData? {
        guard configurationIssue == nil,
              let xColumn = heatmapSelection.x,
              let yColumn = heatmapSelection.y,
              let valueColumn = heatmapSelection.value
        else { return nil }

        struct Key: Hashable { let x: String; let y: String }
        var values: [Key: Double] = [:]
        var xLabels: [String] = []
        var yLabels: [String] = []
        for row in rows ?? [] where row.indices.contains(xColumn.sourceIndex)
            && row.indices.contains(yColumn.sourceIndex)
            && row.indices.contains(valueColumn.sourceIndex) {
            let x = row[xColumn.sourceIndex].tabularDescription
            let y = row[yColumn.sourceIndex].tabularDescription
            guard let value = row[valueColumn.sourceIndex].doubleValue else { continue }
            if !xLabels.contains(x) { xLabels.append(x) }
            if !yLabels.contains(y) { yLabels.append(y) }
            values[Key(x: x, y: y), default: 0] += value
        }
        let allCells = xLabels.flatMap { x in
            yLabels.compactMap { y -> HogQLHeatmapCell? in
                guard let value = values[Key(x: x, y: y)] else { return nil }
                return HogQLHeatmapCell(x: x, y: y, value: value)
            }
        }
        let limit = 400
        return HogQLHeatmapData(
            xLabels: xLabels,
            yLabels: yLabels,
            cells: Array(allCells.prefix(limit)),
            wasTruncated: allCells.count > limit
        )
    }

    private var chartSelection: (x: HogQLColumn?, y: [HogQLColumn], issue: String?) {
        let numeric = columns.filter { $0.scalar.isNumeric }
        let x: HogQLColumn?
        if let explicitX = chart.xAxis {
            guard let match = columns.first(where: { $0.name == explicitX }) else {
                return (nil, [], "The saved X-axis column is unavailable; showing the table instead.")
            }
            x = match
        } else {
            x = columns.first(where: { $0.scalar.isDate })
                ?? columns.first(where: { !$0.scalar.isNumeric })
        }

        let y: [HogQLColumn]
        if chart.yAxes.isEmpty {
            y = numeric
        } else {
            let selected = chart.yAxes.compactMap { name in
                columns.first(where: { $0.name == name && $0.scalar.isNumeric })
            }
            guard selected.count == chart.yAxes.count else {
                return (x, [], "A saved Y-axis column is unavailable or nonnumeric; showing the table instead.")
            }
            y = selected
        }
        guard x != nil else { return (nil, y, "No usable X-axis column is available; showing the table instead.") }
        guard !y.isEmpty else { return (x, [], "No numeric Y-axis column is available; showing the table instead.") }
        return (x, y, nil)
    }

    private func plottedValues(in rows: [[JSONValue]], columns: [HogQLColumn]) -> [Double] {
        rows.flatMap { row in
            columns.compactMap { column in
                guard row.indices.contains(column.sourceIndex) else { return nil }
                let value = row[column.sourceIndex]
                if value.isNull, chart.showNullsAsZero { return 0 }
                return value.doubleValue
            }
        }
    }

    private var heatmapSelection: (x: HogQLColumn?, y: HogQLColumn?, value: HogQLColumn?, issue: String?) {
        let strings = columns.filter { $0.scalar == .string }
        let numeric = columns.filter { $0.scalar.isNumeric }
        func selected(_ name: String?, fallback: HogQLColumn?) -> HogQLColumn? {
            guard let name else { return fallback }
            return columns.first(where: { $0.name == name })
        }
        let x = selected(chart.heatmap.xAxisColumn, fallback: strings.first)
        let y = selected(chart.heatmap.yAxisColumn, fallback: strings.dropFirst().first)
        let value = selected(chart.heatmap.valueColumn, fallback: numeric.first)
        guard let x, let y, let value,
              x.scalar == .string, y.scalar == .string, value.scalar.isNumeric
        else {
            return (x, y, value, "The saved heatmap axes are unavailable or incompatible; showing the table instead.")
        }
        return (x, y, value, nil)
    }

    private func axisValue(_ value: JSONValue, column: HogQLColumn) -> HogQLAxisValue {
        if column.scalar.isDate { return .date(value.stringValue ?? value.tabularDescription) }
        if column.scalar.isNumeric, let number = value.doubleValue { return .number(number) }
        return .category(value.tabularDescription)
    }
}

public extension JSONValue {
    /// Stable, lossless cell text for tables and categorical axes.
    var tabularDescription: String {
        if let scalar = stringValue { return scalar }
        if isNull { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }
}
