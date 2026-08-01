import GetHogKit
import SwiftUI

/// One row of the marketing table, already flattened to display strings.
///
/// Kept generic on purpose. `MarketingAnalyticsTableQuery` returns columns from
/// connected ad sources, so rendering the response's own `columns` array avoids
/// guesses and cannot silently mislabel a figure.
struct MarketingRow: Identifiable, Hashable {
    let id: Int
    let cells: [String]
}

enum MarketingTable {
    static func columns(from response: QueryResponse) -> [String] {
        response.columns.map(displayName)
    }

    static func rows(from response: QueryResponse) -> [MarketingRow] {
        response.rows.enumerated().map { index, row in
            MarketingRow(id: index, cells: row.values.map(cellText))
        }
    }

    /// PostHog labels table columns with dotted paths; the trailing component is
    /// the part a reader recognises.
    private static func displayName(_ column: String) -> String {
        let leaf = column.split(separator: ".").last.map(String.init) ?? column
        return leaf.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func cellText(_ value: JSONValue) -> String {
        // Web-analytics table cells often arrive as [current, previous] pairs.
        if case .array(let pair) = value, let first = pair.first {
            return cellText(first)
        }
        if let string = value.stringValue, !string.isEmpty { return string }
        if let number = value.doubleValue { return number.compactFormatted }
        return "—"
    }
}

/// Campaign performance, when there is any.
///
/// The empty state names the relevant precondition rather than merely saying
/// "no data", giving the reader a useful next step.
struct MarketingSection: View {
    let columns: [String]
    let rows: [MarketingRow]
    let isLoading: Bool
    let error: LoadFailure?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Marketing", systemImage: "megaphone")

            if rows.isEmpty && !isLoading {
                emptyOrError
            } else {
                table
            }
        }
    }

    /// Compact, because this is the last of several sections on one scrolling
    /// screen — a full `ContentUnavailableView` here is a screen's worth of
    /// treatment spent on a section that is legitimately, permanently empty for
    /// any project with no ad source connected.
    @ViewBuilder
    private var emptyOrError: some View {
        if let error {
            SectionEmptyState(
                text: error.summary,
                systemImage: "exclamationmark.triangle",
                detail: error.detail,
                actionTitle: "Try again",
                action: onRetry
            )
        } else {
            // The mildest member of the empty-state family swept in correction
            // 40, and adjusted rather than gutted because — unlike the three
            // that named an SDK capture toggle — its first sentence is
            // unconditionally true: this really is built from synced ad spend.
            //
            // What was wrong is that it never stated the absence at all, and
            // went straight to a remedy phrased as an instruction ("Connect one
            // in Data pipelines"), which asserts that no source *is* connected.
            // This screen does not check. A project with a source connected and
            // simply no spend in the window got sent to connect a second one.
            // The absence now leads and the remedy is conditional.
            SectionEmptyState(
                text: """
                    No campaign spend in this window. PostHog builds this from ad spend synced \
                    by a connected advertising source; if none is connected yet, that is set up \
                    in Data pipelines.
                    """,
                systemImage: "megaphone"
            )
        }
    }

    /// Scrolls horizontally inside its own card: an unknown number of columns
    /// must never be allowed to widen the page itself.
    private var table: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.l) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Text(column)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 90, alignment: .leading)
                    }
                }
                .padding(.bottom, Theme.Space.s)

                ForEach(rows) { row in
                    Divider()
                    HStack(spacing: Theme.Space.l) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                            Text(cell)
                                .font(.caption)
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(minWidth: 90, alignment: .leading)
                                .accessibilityLabel(
                                    index < columns.count ? "\(columns[index]): \(cell)" : cell
                                )
                        }
                    }
                    .padding(.vertical, Theme.Space.s)
                }
            }
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.visible)
        .background(
            Theme.cardBackground,
            in: .rect(cornerRadius: Theme.Radius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .skeleton(isLoading && rows.isEmpty)
    }
}
