import Foundation
import GetHogKit
import GetHogUI
import SwiftUI

/// The complete publication scope for one cached insight preview.
/// Insight ids can repeat across projects, hosts, and authentication sessions,
/// so object identity alone is not enough to own a response.
struct InsightPreviewScope: Hashable, Sendable {
    let authority: ResourceRequestAuthority
    let insightID: Int
}

@MainActor
@Observable
final class InsightQuickPreviewStore {
    private struct LoadFlight {
        let id: UInt64
        let scope: InsightPreviewScope
        let task: Task<Void, Never>
    }

    private static let reuseInterval: TimeInterval = 5 * 60

    private(set) var state: QuickPreviewEnrichment<Insight> = .idle
    private let now: @MainActor () -> Date
    private var activeScope: InsightPreviewScope?
    private var operationToken: UInt64 = 0
    private var nextFlightID: UInt64 = 0
    private var loadFlight: LoadFlight?

    init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
    }

    /// A remounted preview joins the store-owned request. A later deliberate
    /// activation reuses a completed response for five minutes, then spends one
    /// replacement cache-only request while retaining the prior value.
    func activate(
        client: PostHogClient?,
        scope: InsightPreviewScope?
    ) async {
        guard let client, let scope, client.region == scope.authority.region else {
            invalidate()
            return
        }

        if let loadFlight, loadFlight.scope == scope {
            await loadFlight.task.value
            return
        }
        if activeScope == scope,
           case .loaded(let insight, let loadedAt) = state,
           insight.id == scope.insightID,
           now().timeIntervalSince(loadedAt) < Self.reuseInterval {
            return
        }

        let retained: (insight: Insight?, loadedAt: Date?)
        if activeScope == scope {
            retained = retainedValue
        } else {
            loadFlight?.task.cancel()
            retained = (nil, nil)
        }

        operationToken &+= 1
        let token = operationToken
        activeScope = scope
        state = .loading(previous: retained.insight, loadedAt: retained.loadedAt)
        nextFlightID &+= 1
        let flightID = nextFlightID
        let task = Task { @MainActor in
            await self.performLoad(
                client: client,
                scope: scope,
                token: token,
                previous: retained.insight,
                previousLoadedAt: retained.loadedAt
            )
        }
        loadFlight = LoadFlight(id: flightID, scope: scope, task: task)
        await task.value
        if loadFlight?.id == flightID {
            loadFlight = nil
        }
    }

    func invalidate() {
        operationToken &+= 1
        loadFlight?.task.cancel()
        loadFlight = nil
        activeScope = nil
        state = .idle
    }

    /// Hides a retained response synchronously when SwiftUI has recomputed with
    /// a replacement authority but its new preview task has not started yet.
    func state(for scope: InsightPreviewScope?) -> QuickPreviewEnrichment<Insight> {
        guard let scope, activeScope == scope else { return .idle }
        return state
    }

    private func performLoad(
        client: PostHogClient,
        scope: InsightPreviewScope,
        token: UInt64,
        previous: Insight?,
        previousLoadedAt: Date?
    ) async {
        do {
            let loaded: Insight = try await client.send(
                PostHogAPI.insight(
                    projectID: scope.authority.projectID,
                    insightID: scope.insightID,
                    refresh: false
                )
            )
            guard owns(scope: scope, token: token), !Task.isCancelled else { return }
            state = .loaded(loaded, loadedAt: now())
        } catch is CancellationError {
            // Closing or replacing a preview is ordinary interaction. Its new
            // owner has already installed the visible state.
        } catch {
            guard owns(scope: scope, token: token), !Task.isCancelled else { return }
            if let previous, let previousLoadedAt {
                state = .stale(previous, loadedAt: previousLoadedAt)
            } else {
                state = .unavailable
            }
        }
    }

    private var retainedValue: (insight: Insight?, loadedAt: Date?) {
        switch state {
        case .loaded(let insight, let loadedAt),
             .stale(let insight, let loadedAt):
            (insight, loadedAt)
        case .loading(let insight, let loadedAt):
            (insight, loadedAt)
        case .idle, .unavailable:
            (nil, nil)
        }
    }

    private func owns(scope: InsightPreviewScope, token: UInt64) -> Bool {
        activeScope == scope && operationToken == token
    }
}

enum InsightQuickPreviewResult: Equatable {
    case headline(String)
    case chart(display: String, seriesCount: Int)
    case table(rows: Int, columns: Int)
    case empty
    case pending
    case unsupported

    init(insight: Insight) {
        switch insight.renderModel {
        case .bigNumber(let number):
            self = .headline(number.value.compactFormatted)

        case .timeSeries(let series, let style):
            guard series.contains(where: { !$0.points.isEmpty }) else {
                self = .empty
                return
            }
            self = .chart(
                display: Self.displayName(insight.displayType, fallback: style),
                seriesCount: series.count
            )

        case .barValue(let bars):
            guard !bars.isEmpty else {
                self = .empty
                return
            }
            self = .chart(
                display: Self.displayName(insight.displayType, fallback: nil),
                seriesCount: bars.count
            )

        case .funnel(let groups):
            let populated = groups.filter { !$0.steps.isEmpty }
            self = populated.isEmpty
                ? .empty
                : .chart(display: "Funnel", seriesCount: populated.count)

        case .lifecycle(let series):
            let populated = series.filter { !$0.points.isEmpty }
            self = populated.isEmpty
                ? .empty
                : .chart(display: "Lifecycle", seriesCount: populated.count)

        case .retention(let grid):
            let populated = grid.cohorts.filter { !$0.counts.isEmpty }
            self = populated.isEmpty
                ? .empty
                : .chart(display: "Retention", seriesCount: populated.count)

        case .stickiness(let series):
            let populated = series.filter { !$0.buckets.isEmpty }
            self = populated.isEmpty
                ? .empty
                : .chart(display: "Stickiness", seriesCount: populated.count)

        case .paths(let graph):
            self = graph.edges.isEmpty
                ? .empty
                : .chart(display: "Paths", seriesCount: graph.edges.count)

        case .unsupported:
            self = .unsupported

        case .hogQL(let visualization):
            self = Self.hogQLResult(visualization)
        }
    }

    private static func hogQLResult(_ visualization: HogQLVisualization) -> Self {
        guard let rows = visualization.rows else { return .pending }
        guard !rows.isEmpty else { return .empty }

        switch visualization.resolvedDisplay {
        case .boldNumber:
            guard let value = visualization.boldNumber else { return .empty }
            return .headline(value.tabularDescription)
        case .table:
            return tableResult(visualization)
        case .unsupported:
            return .unsupported
        case .line, .area, .bar, .stackedBar, .pie:
            guard visualization.configurationIssue == nil,
                  let chart = visualization.chartData,
                  !chart.series.isEmpty
            else { return tableResult(visualization) }
            return .chart(
                display: displayName(visualization.resolvedDisplay),
                seriesCount: chart.series.count
            )
        case .heatmap:
            guard visualization.configurationIssue == nil else {
                return tableResult(visualization)
            }
            return .chart(display: "Heatmap", seriesCount: 1)
        case .auto:
            return tableResult(visualization)
        }
    }

    private static func tableResult(_ visualization: HogQLVisualization) -> Self {
        let table = visualization.displayedTable
        return .table(rows: table.rows.count, columns: table.columns.count)
    }

    fileprivate static func displayName(
        _ raw: String?,
        fallback style: TimeSeriesStyle?
    ) -> String {
        switch raw {
        case "ActionsLineGraph", "ActionsLineGraphCumulative", "Auto", nil:
            if let style { return displayName(style) }
            return "Chart"
        case "ActionsAreaGraph": return "Area"
        case "ActionsBar", "ActionsUnstackedBar": return "Bar"
        case "ActionsStackedBar": return "Stacked bar"
        case "ActionsPie": return "Pie"
        case "ActionsBarValue": return "Bar value"
        case "ActionsTable": return "Table"
        case "WorldMap": return "World map"
        case "BoldNumber": return "Bold number"
        case let value?:
            return value.replacingOccurrences(of: "Actions", with: "")
        }
    }

    private static func displayName(_ style: TimeSeriesStyle) -> String {
        switch style {
        case .line: "Line"
        case .area: "Area"
        case .bar: "Bar"
        case .stackedBar: "Stacked bar"
        }
    }

    private static func displayName(_ display: HogQLDisplay) -> String {
        switch display {
        case .auto: "Auto"
        case .table: "Table"
        case .line: "Line"
        case .area: "Area"
        case .bar: "Bar"
        case .stackedBar: "Stacked bar"
        case .pie: "Pie"
        case .heatmap: "Heatmap"
        case .boldNumber: "Bold number"
        case .unsupported(let value): value
        }
    }
}

struct InsightQuickPreviewPresentation: Equatable {
    let title: String
    let description: String?
    let queryKind: String
    let displayType: String
    let isFavorite: Bool
    let dashboardCount: Int
    let lastModifiedAt: Date?
    let cacheState: String
    let result: InsightQuickPreviewResult?

    init(
        title: String,
        description: String?,
        queryKind: String,
        displayType: String,
        isFavorite: Bool,
        dashboardCount: Int,
        lastModifiedAt: Date?,
        cacheState: String,
        result: InsightQuickPreviewResult?
    ) {
        self.title = title
        self.description = description
        self.queryKind = queryKind
        self.displayType = displayType
        self.isFavorite = isFavorite
        self.dashboardCount = dashboardCount
        self.lastModifiedAt = lastModifiedAt
        self.cacheState = cacheState
        self.result = result
    }

    init(summary: Insight, enriched: Insight?) {
        title = summary.title
        description = summary.description
        queryKind = summary.kind?.title
            ?? summary.sourceKind.replacingOccurrences(of: "Query", with: "")
        displayType = InsightQuickPreviewResult.displayName(
            summary.displayType ?? summary.query?.display,
            fallback: nil
        )
        isFavorite = summary.favorited
        dashboardCount = summary.dashboards.count
        lastModifiedAt = summary.lastModifiedAt
        cacheState = summary.isCached ? "Cached result" : "Not cached"
        result = if let enriched, enriched.id == summary.id {
            InsightQuickPreviewResult(insight: enriched)
        } else {
            nil
        }
    }

    var accessibilitySummary: String {
        var parts = [Self.sentence(title)]
        if let description, !description.isEmpty {
            parts.append(Self.sentence(description))
        }
        parts.append(Self.sentence(queryKind))
        parts.append(Self.sentence(displayType))
        parts.append(Self.sentence(isFavorite ? "Favorite" : "Not favorite"))
        switch dashboardCount {
        case 0: parts.append("Not on a dashboard.")
        case 1: parts.append("On 1 dashboard.")
        case let count: parts.append("On \(count) dashboards.")
        }
        if let lastModifiedAt {
            let style = Date.FormatStyle(
                date: .abbreviated,
                time: .omitted,
                locale: Locale(identifier: "en_US_POSIX"),
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
            parts.append("Edited \(lastModifiedAt.formatted(style)).")
        }
        parts.append(Self.sentence(cacheState))
        switch result {
        case .headline(let value):
            parts.append("Cached headline, \(value).")
        case .chart(let display, let seriesCount):
            parts.append("Cached \(display.lowercased()) chart, \(seriesCount) series.")
        case .table(let rows, let columns):
            parts.append("Cached table, \(rows) rows, \(columns) columns.")
        case .empty:
            parts.append("Cached result is empty.")
        case .pending:
            parts.append("Cached result is pending.")
        case .unsupported:
            parts.append("Cached result is not supported in Quick Preview.")
        case nil:
            break
        }
        return parts.joined(separator: " ")
    }

    fileprivate static func sentence(_ value: String) -> String {
        guard let last = value.last, !".!?".contains(last) else { return value }
        return value + "."
    }
}

struct InsightQuickPreview: View {
    let summary: Insight
    let state: QuickPreviewEnrichment<Insight>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: InsightQuickPreviewPresentation {
        InsightQuickPreviewPresentation(summary: summary, enriched: state.value)
    }

    var body: some View {
        QuickPreviewCard(
            title: presentation.title,
            subtitle: presentation.description,
            systemImage: TileStyle.symbol(for: summary.renderModel),
            accessibilitySummary: accessibilitySummary
        ) {
            baseFacts
            enrichment
        }
        .accessibilityIdentifier("gethog.quick-preview.insight.\(summary.id)")
    }

    private var baseFacts: some View {
        let layout = if QuickPreviewLayout.factsAxis(for: dynamicTypeSize) == .vertical {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.m))
        }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            layout {
                Label(presentation.queryKind, systemImage: "chart.xyaxis.line")
                Text(presentation.displayType)
                Label(
                    presentation.isFavorite ? "Favorite" : "Not favorite",
                    systemImage: presentation.isFavorite ? "star.fill" : "star"
                )
            }
            .font(.caption.weight(.semibold))

            layout {
                Label(
                    dashboardMembership,
                    systemImage: "square.grid.2x2"
                )
                Label(presentation.cacheState, systemImage: "externaldrive")
            }
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)

            if let modified = presentation.lastModifiedAt {
                Text("Edited \(modified.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
    }

    @ViewBuilder
    private var enrichment: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading(let previous, _):
            if previous != nil { resultView }
            status("Loading cached details…", systemImage: "clock.arrow.circlepath")
        case .loaded:
            resultView
        case .unavailable:
            status("More details unavailable", systemImage: "exclamationmark.triangle")
        case .stale:
            resultView
            status("Refresh failed", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch presentation.result {
        case .headline(let value):
            LabeledContent("Cached headline") {
                Text(value).font(.headline.monospacedDigit())
            }
        case .chart(let display, let seriesCount):
            LabeledContent("Cached \(display.lowercased()) chart") {
                Text("\(seriesCount) series")
            }
        case .table(let rows, let columns):
            LabeledContent("Cached table") {
                Text("\(rows) rows · \(columns) columns")
            }
        case .empty:
            status("Cached result is empty", systemImage: "tray")
        case .pending:
            status("Cached result is pending", systemImage: "clock")
        case .unsupported:
            status("Cached result isn't supported in Quick Preview", systemImage: "questionmark.square")
        case nil:
            EmptyView()
        }
    }

    private func status(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
    }

    private var dashboardMembership: String {
        switch presentation.dashboardCount {
        case 0: "Not on a dashboard"
        case 1: "On 1 dashboard"
        case let count: "On \(count) dashboards"
        }
    }

    private var accessibilitySummary: String {
        guard let statusText = state.statusText else {
            return presentation.accessibilitySummary
        }
        return presentation.accessibilitySummary + " "
            + InsightQuickPreviewPresentation.sentence(statusText)
    }
}
