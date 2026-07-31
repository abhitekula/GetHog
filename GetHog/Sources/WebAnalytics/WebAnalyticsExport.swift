import GetHogKit
import SwiftUI

// CSV export for the web-analytics report.
//
// **In its own file rather than inside `WebAnalyticsRoot`** because the report's
// six sections are six independent tables, and gathering their flattening in one
// place is the only way to see that they agree on how a number is written. The
// screen itself formats for reading — compact notation, `41.2%`, `2m 13s`; a CSV
// has to carry the figure a spreadsheet can sum.
//
// **Six exports, not one.** A single file would have to either concatenate six
// different column layouts into one sheet, which no spreadsheet reads back, or
// pick one section and silently drop five. The menu names each table and its row
// count, so what is being taken is stated before it is taken.
//
// # What these exports cannot carry, and why
//
// The previous period's figure is gone before this code runs. `WebStatsRow`,
// `WebExternalClickRow` and `MarketingTable` each collapse the API's
// `[current, previous]` pair to its leading element at decode time, in three
// separate places, and the store keeps only the result. So the breakdown,
// external-clicks and marketing exports carry the current period only.
//
// That is a limitation reported rather than worked around: restoring it means
// changing what those decoders keep, and this pass owns export, not the
// decoding. The Overview export *does* carry the previous period, because
// `WebOverviewMetric` keeps it.

extension WebAnalyticsStore {

    /// Every table currently on screen that has anything in it, in the order the
    /// report draws them.
    ///
    /// Empty tables are absent rather than offered-and-empty: a CSV holding a
    /// header and nothing else reads as an export that failed.
    ///
    /// **Nothing is flattened here.** This is called from a `View` body, and the
    /// toolbar re-renders every time any of the report's six loaders finishes or
    /// the search field changes — so building six `[[String]]` tables eagerly
    /// would rebuild all of them on each of those. Each entry captures the
    /// decoded rows it needs, which are `Sendable` value types, and turns them
    /// into text inside the closure. The row counts the menu displays are the
    /// only thing computed up front, and each is an array count.
    func csvExports(dimension: WebStatsDimension) -> [(name: String, export: CSVExport)] {
        var all: [(name: String, export: CSVExport)] = []

        if !metrics.isEmpty {
            let metrics = self.metrics
            all.append((
                "Overview",
                CSVExport(title: "Web overview", rowCount: metrics.count) {
                    InsightCSV.data(rows: WebAnalyticsCSV.overviewRows(metrics))
                }
            ))
        }
        if !rows.isEmpty {
            let rows = self.rows
            all.append((
                dimension.title,
                CSVExport(title: "Web \(dimension.pluralTitle)", rowCount: rows.count) {
                    InsightCSV.data(rows: WebAnalyticsCSV.breakdownRows(rows, dimension: dimension))
                }
            ))
        }
        if let vitals, !vitals.isEmpty {
            let entries = vitals.allEntries
            all.append((
                "Web vitals",
                CSVExport(title: "Web vitals", rowCount: entries.count) {
                    InsightCSV.data(rows: WebAnalyticsCSV.vitalsRows(entries))
                }
            ))
        }
        if !externalClicks.isEmpty {
            let clicks = externalClicks
            all.append((
                "Outbound clicks",
                CSVExport(title: "Outbound clicks", rowCount: clicks.count) {
                    InsightCSV.data(rows: WebAnalyticsCSV.clickRows(clicks))
                }
            ))
        }
        if !notableChanges.isEmpty {
            let changes = notableChanges
            all.append((
                "Notable changes",
                CSVExport(title: "Notable changes", rowCount: changes.count) {
                    InsightCSV.data(rows: WebAnalyticsCSV.changeRows(changes))
                }
            ))
        }
        if !marketingRows.isEmpty {
            let columns = marketingColumns
            let rows = marketingRows
            all.append((
                "Marketing",
                CSVExport(title: "Marketing", rowCount: rows.count) {
                    InsightCSV.data(rows: [columns] + rows.map(\.cells))
                }
            ))
        }

        return all
    }

}

/// The report's six tables, flattened to text.
///
/// A free namespace rather than members of `WebAnalyticsStore`, and that is
/// forced rather than stylistic: the store is `@MainActor`, so anything declared
/// in an extension of it inherits that isolation and cannot be called from the
/// `@Sendable` closure a deferred `CSVExport` holds. These take their rows as
/// arguments — all `Sendable` value types — so the closure captures data, never
/// the store.
enum WebAnalyticsCSV {

    /// Both periods and the change, because this is the one section that still
    /// has the previous figure.
    ///
    /// `kind` travels as its own column rather than being baked into the value:
    /// a bounce rate of `41.2` and a session count of `41.2` are different
    /// quantities, and a spreadsheet reading a bare number cannot tell which
    /// it has.
    static func overviewRows(_ metrics: [WebOverviewMetric]) -> [[String]] {
        [["Metric", "Unit", "Value", "Previous", "Change %"]]
            + metrics.map { metric in
                [
                    metric.title,
                    metric.kind.rawValue,
                    metric.value.map(InsightCSV.number) ?? "",
                    metric.previous.map(InsightCSV.number) ?? "",
                    metric.changeFromPreviousPct.map(InsightCSV.number) ?? "",
                ]
            }
    }

    /// The first column is named for the dimension the reader chose, because the
    /// same table means something different under each one — a column headed
    /// "Value" over a list of countries is a file nobody can read back in a week.
    static func breakdownRows(
        _ rows: [WebStatsRow], dimension: WebStatsDimension
    ) -> [[String]] {
        [[dimension.title, "Visitors", "Views"]]
            + rows.map {
                [$0.breakdownValue, InsightCSV.number($0.visitors), InsightCSV.number($0.views)]
            }
    }

    /// Worst band first: the caller passes `allEntries`, which is already sorted
    /// that way, so the file reads in the order the screen does.
    static func vitalsRows(_ entries: [WebVitalEntry]) -> [[String]] {
        [["Path", "Value", "Band"]]
            + entries.map {
                [$0.path, InsightCSV.number($0.value), $0.band?.title ?? ""]
            }
    }

    static func clickRows(_ clicks: [WebExternalClickRow]) -> [[String]] {
        [["URL", "Visitors", "Clicks"]]
            + clicks.map {
                [$0.url, InsightCSV.number($0.visitors), InsightCSV.number($0.clicks)]
            }
    }

    /// `comparablePercentChange`, not the raw field: the model deliberately
    /// keeps `reportedPercentChange` private because it is only meaningful when
    /// a non-zero previous period exists, and an export is exactly where an
    /// uncomparable percentage would be mistaken for a real one.
    static func changeRows(_ changes: [WebNotableChange]) -> [[String]] {
        [["Metric", "Dimension", "Value", "Current", "Previous", "Change %", "Impact"]]
            + changes.map { change in
                [
                    change.metric,
                    change.dimensionType,
                    change.dimensionValue,
                    InsightCSV.number(change.currentValue),
                    change.previousValue.map(InsightCSV.number) ?? "",
                    change.comparablePercentChange.map(InsightCSV.number) ?? "",
                    InsightCSV.number(change.impactScore),
                ]
            }
    }
}

/// The report's exports, as one toolbar menu.
///
/// Submenus rather than eighteen flat entries: choosing *which table* and
/// choosing *where it goes* are two decisions, and on a phone a flat list of
/// eighteen is a scroll. Each submenu names its row count for the same reason
/// `CSVShareMenu` does — the tables here differ by two orders of magnitude in
/// size and that decides which destination the reader wants.
struct WebAnalyticsExportMenu: View {
    let store: WebAnalyticsStore
    let dimension: WebStatsDimension

    var body: some View {
        let tables = store.csvExports(dimension: dimension)

        Menu {
            ForEach(Array(tables.enumerated()), id: \.offset) { _, table in
                Menu {
                    CSVShareMenuItems(export: table.export)
                } label: {
                    Label(
                        "\(table.name) · \(table.export.rowCount.formatted()) \(table.export.rowCount == 1 ? "row" : "rows")",
                        systemImage: "tablecells"
                    )
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Export a table as CSV")
        .disabled(tables.isEmpty)
    }
}
