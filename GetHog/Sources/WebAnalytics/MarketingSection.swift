import GetHogKit
import SwiftUI

/// One row of the marketing table, already flattened to display strings.
///
/// Kept generic on purpose. `MarketingAnalyticsTableQuery` returns whatever
/// columns the project's connected ad sources produce, and this project has
/// none connected — so there is no verified column list to model against.
/// Naming columns that were never observed would be a guess dressed up as a
/// schema; rendering the response's own `columns` array is the honest option
/// and cannot silently mislabel a figure.
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
/// Verified against project [REMOVED PRIVATE DATA]: the marketing cost table holds zero rows and
/// no advertising source is connected, so this renders its empty state there.
/// That state names the actual precondition rather than saying "no data" — the
/// difference between "you have no campaigns" and "you have not connected an ad
/// account" is the difference between a shrug and a next step.
struct MarketingSection: View {
    let columns: [String]
    let rows: [MarketingRow]
    let isLoading: Bool
    let error: WebLoadFailure?
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
            SectionEmptyState(
                text: """
                    PostHog builds this from ad spend synced by a connected advertising source. \
                    Connect one in Data pipelines to see campaigns, cost and return here.
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
