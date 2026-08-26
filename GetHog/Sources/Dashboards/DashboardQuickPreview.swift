import Foundation
import GetHogKit
import GetHogUI
import SwiftUI

struct DashboardQuickPreviewPresentation: Equatable {
    struct TileSummary: Equatable {
        let title: String
        let detail: String
    }

    let title: String
    let description: String?
    let stateText: String
    let lastRefresh: Date?
    let tileCount: Int?
    let tiles: [TileSummary]

    init(
        title: String,
        description: String?,
        stateText: String,
        lastRefresh: Date?,
        tileCount: Int?,
        tiles: [TileSummary]
    ) {
        self.title = title
        self.description = description
        self.stateText = stateText
        self.lastRefresh = lastRefresh
        self.tileCount = tileCount
        self.tiles = tiles
    }

    init(summary: DashboardSummary, enriched dashboard: Dashboard?) {
        title = summary.title
        description = summary.description
        stateText = Self.stateText(for: summary)
        lastRefresh = summary.lastRefresh

        // A dashboard from an outgoing preview activation cannot enrich this
        // summary, even for the first frame before the new task starts.
        guard let dashboard, dashboard.id == summary.id else {
            tileCount = nil
            tiles = []
            return
        }

        tileCount = dashboard.tiles.count
        tiles = dashboard.tiles
            .sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            .compactMap(Self.tileSummary)
            .prefix(3)
            .map { $0 }
    }

    var accessibilitySummary: String {
        var parts = [Self.sentence(title)]
        if let description, !description.isEmpty {
            parts.append(Self.sentence(description))
        }

        let stateParts = stateText.components(separatedBy: " · ")
        let spokenState = stateParts.enumerated().map { index, part in
            index == 0 ? part : part.lowercased()
        }.joined(separator: ", ")
        parts.append(Self.sentence(spokenState))

        if let lastRefresh {
            let style = Date.FormatStyle(
                date: .abbreviated,
                time: .omitted,
                locale: Locale(identifier: "en_US_POSIX"),
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
            parts.append("Updated \(lastRefresh.formatted(style)).")
        } else {
            parts.append("Not yet updated.")
        }

        if let tileCount {
            parts.append("\(tileCount) \(tileCount == 1 ? "tile" : "tiles").")
        }
        parts.append(contentsOf: tiles.map { Self.sentence("\($0.title), \($0.detail)") })
        return parts.joined(separator: " ")
    }

    private static func stateText(for summary: DashboardSummary) -> String {
        var parts: [String] = []
        if summary.pinned { parts.append("Pinned") }
        switch summary.creationMode {
        case .template:
            parts.append("Template")
        case .duplicate:
            parts.append("Duplicate")
        case .default, .unknown:
            break
        }
        if summary.isShared { parts.append("Shared") }
        return parts.isEmpty ? "Dashboard" : parts.joined(separator: " · ")
    }

    private static func tileSummary(_ tile: Tile) -> TileSummary? {
        guard case .insight(let insight) = tile.content else { return nil }
        let detail: String
        if let metric = SharedSnapshot.Metric(tile: tile, dashboardID: nil) {
            detail = metric.value.compactFormatted
        } else {
            detail = insight.kind?.title
                ?? insight.sourceKind.replacingOccurrences(of: "Query", with: "")
        }
        return TileSummary(title: insight.title, detail: detail)
    }

    fileprivate static func sentence(_ value: String) -> String {
        guard let last = value.last, !".!?".contains(last) else { return value }
        return value + "."
    }
}

struct DashboardQuickPreview: View {
    let summary: DashboardSummary
    let state: QuickPreviewEnrichment<Dashboard>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: DashboardQuickPreviewPresentation {
        DashboardQuickPreviewPresentation(summary: summary, enriched: state.value)
    }

    var body: some View {
        QuickPreviewCard(
            title: presentation.title,
            subtitle: presentation.description,
            systemImage: summary.creationMode == .template ? "wand.and.stars" : "square.grid.2x2",
            accessibilitySummary: accessibilitySummary
        ) {
            baseFacts
            enrichment
        }
        .accessibilityIdentifier("gethog.quick-preview.dashboard.\(summary.id)")
    }

    private var baseFacts: some View {
        let layout = if QuickPreviewLayout.factsAxis(for: dynamicTypeSize) == .vertical {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.m))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.m))
        }
        return layout {
            Label(presentation.stateText, systemImage: summary.pinned ? "pin.fill" : "square.grid.2x2")
                .font(.caption.weight(.semibold))
            FreshnessLabel(date: presentation.lastRefresh)
        }
    }

    @ViewBuilder
    private var enrichment: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading(let previous, _):
            if previous != nil { tileDetails }
            status("Loading cached details…", systemImage: "clock.arrow.circlepath")
        case .loaded:
            tileDetails
        case .unavailable:
            status("More details unavailable", systemImage: "exclamationmark.triangle")
        case .stale:
            tileDetails
            status("Refresh failed", systemImage: "exclamationmark.triangle")
        }
    }

    private var tileDetails: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let tileCount = presentation.tileCount {
                Text("\(tileCount) \(tileCount == 1 ? "tile" : "tiles")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Ink.secondary)
            }
            ForEach(Array(presentation.tiles.enumerated()), id: \.offset) { _, tile in
                LabeledContent(tile.title) {
                    Text(tile.detail)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func status(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
    }

    private var accessibilitySummary: String {
        guard let statusText = state.statusText else {
            return presentation.accessibilitySummary
        }
        return presentation.accessibilitySummary + " " + DashboardQuickPreviewPresentation
            .sentence(statusText)
    }
}
