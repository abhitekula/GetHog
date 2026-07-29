import GetHogKit
import SwiftUI

/// Date windows offered by the analytics surfaces.
///
/// Shared with error tracking so "this period" means the same thing on both
/// screens; the raw values are PostHog's relative-date shorthand.
enum AnalyticsWindow: String, CaseIterable, Identifiable, Hashable {
    case day = "-24h"
    case week = "-7d"
    case month = "-30d"
    case quarter = "-90d"

    var id: String { rawValue }

    /// Compact enough for a segmented control.
    var title: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        }
    }

    /// "7d" is unintelligible read aloud, so VoiceOver gets the long form.
    var spokenTitle: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 90 days"
        }
    }
}

/// Dimensions PostHog's `WebStatsTableQuery` can break down by.
enum WebStatsDimension: String, CaseIterable, Identifiable, Hashable {
    case page = "Page"
    case referrer = "InitialReferringDomain"
    case device = "DeviceType"
    case browser = "Browser"
    case country = "Country"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .page: "Page"
        case .referrer: "Referrer"
        case .device: "Device"
        case .browser: "Browser"
        case .country: "Country"
        }
    }

    var pluralTitle: String {
        switch self {
        case .page: "pages"
        case .referrer: "referrers"
        case .device: "devices"
        case .browser: "browsers"
        case .country: "countries"
        }
    }
}

@MainActor
@Observable
final class WebAnalyticsStore {
    var metrics: [WebOverviewMetric] = []
    var rows: [WebStatsRow] = []
    var isLoadingOverview = false
    var isLoadingRows = false
    var overviewError: String?
    var rowsError: String?
    var loadedAt: Date?

    var isLoading: Bool { isLoadingOverview || isLoadingRows }
    var isEmpty: Bool { metrics.isEmpty && rows.isEmpty }

    func loadOverview(client: PostHogClient, projectID: Int, window: AnalyticsWindow) async {
        isLoadingOverview = true
        defer { isLoadingOverview = false }
        do {
            let response: WebOverviewResponse = try await client.send(
                PostHogAPI.webOverview(projectID: projectID, dateFrom: window.rawValue)
            )
            metrics = response.metrics
            loadedAt = Date()
            overviewError = nil
        } catch {
            overviewError = Self.message(for: error)
        }
    }

    func loadBreakdown(
        client: PostHogClient,
        projectID: Int,
        window: AnalyticsWindow,
        dimension: WebStatsDimension
    ) async {
        isLoadingRows = true
        defer { isLoadingRows = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.webStats(
                    projectID: projectID,
                    breakdownBy: dimension.rawValue,
                    dateFrom: window.rawValue
                )
            )
            rows = WebStatsRow.rows(from: response)
            loadedAt = Date()
            rowsError = nil
        } catch {
            rowsError = Self.message(for: error)
        }
    }

    /// The bar scale is pinned to the whole result set, not the visible subset,
    /// so searching narrows the list without silently re-scaling every bar.
    var peakVisitors: Double { rows.map(\.visitors).max() ?? 0 }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

struct WebAnalyticsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var store = WebAnalyticsStore()
    @State private var window: AnalyticsWindow = .week
    @State private var dimension: WebStatsDimension = .page
    @State private var search = ""

    /// A flat report with nothing to select — a split view would owe iPad a
    /// detail pane it does not have, so this screen is a plain stack.
    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Web")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Filter \(dimension.pluralTitle)")
                .refreshable { await reloadAll() }
                // Two keys, not one: changing the breakdown dimension must not
                // spend a second /query/ call re-fetching identical KPIs.
                .task(id: OverviewKey(projectID: model.projectID, window: window)) {
                    await loadOverview()
                }
                .task(id: BreakdownKey(projectID: model.projectID, window: window, dimension: dimension)) {
                    await loadBreakdown()
                }
        }
    }

    private struct OverviewKey: Hashable {
        let projectID: Int?
        let window: AnalyticsWindow
    }

    private struct BreakdownKey: Hashable {
        let projectID: Int?
        let window: AnalyticsWindow
        let dimension: WebStatsDimension
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Web analytics rides the same `/query/` endpoint as the events feed,
            // so it is gated by the identical scope.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.overviewError ?? store.rowsError, store.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load web analytics", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await reloadAll() } }
            }
        } else if store.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No web traffic",
                systemImage: "globe",
                description: Text("Nothing was recorded in the \(window.spokenTitle.lowercased()).")
            )
        } else {
            report
        }
    }

    private var report: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                windowPicker
                overviewSection
                breakdownSection
                FreshnessLabel(date: store.loadedAt)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
    }

    // MARK: - Controls

    private var windowPicker: some View {
        adaptivelyStyled(
            Picker("Date range", selection: $window) {
                ForEach(AnalyticsWindow.allCases) { option in
                    Text(option.title)
                        .accessibilityLabel(option.spokenTitle)
                        .tag(option)
                }
            }
        )
    }

    private var dimensionPicker: some View {
        adaptivelyStyled(
            Picker("Breakdown", selection: $dimension) {
                ForEach(WebStatsDimension.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        )
    }

    /// Segmented controls shrink their labels to slivers at accessibility text
    /// sizes, so past that threshold the same choice becomes a menu.
    @ViewBuilder
    private func adaptivelyStyled(_ picker: some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    // MARK: - Sections

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overview")
                .font(.headline)

            // An adaptive grid rather than a fixed row: at large text sizes the
            // tiles reflow to one column instead of clipping their figures.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 165), spacing: 12)],
                spacing: 12
            ) {
                ForEach(store.metrics) { metric in
                    WebKPITile(metric: metric)
                }
            }
            .skeleton(store.isLoadingOverview && store.metrics.isEmpty)

            if let error = store.overviewError, !store.metrics.isEmpty {
                staleNote("These figures are from an earlier load. \(error)")
            }
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Breakdown")
                .font(.headline)

            dimensionPicker

            if filteredRows.isEmpty && !store.isLoadingRows {
                ContentUnavailableView(
                    search.isEmpty ? "No \(dimension.pluralTitle)" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(
                        search.isEmpty
                            ? "PostHog returned no \(dimension.pluralTitle) for this period."
                            : "No \(dimension.pluralTitle) matched “\(search)”."
                    )
                )
                .frame(maxWidth: .infinity)
            } else {
                breakdownTable
            }

            if let error = store.rowsError, !store.rows.isEmpty {
                staleNote("This table is from an earlier load. \(error)")
            }
        }
    }

    /// Hand-rolled container rather than `Card`: the proportional bars need to
    /// reach the container's edges, which a card's inner padding would inset.
    private var breakdownTable: some View {
        VStack(spacing: 0) {
            ForEach(Array(filteredRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().padding(.leading, 12)
                }
                WebStatsRowView(
                    row: row,
                    rank: index + 1,
                    fraction: store.peakVisitors > 0 ? row.visitors / store.peakVisitors : 0
                )
            }
        }
        .background(Theme.cardBackground, in: .rect(cornerRadius: 14))
        .skeleton(store.isLoadingRows && store.rows.isEmpty)
    }

    private func staleNote(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Data

    private var filteredRows: [WebStatsRow] {
        guard !search.isEmpty else { return store.rows }
        return store.rows.filter { $0.breakdownValue.localizedCaseInsensitiveContains(search) }
    }

    private func loadOverview() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadOverview(client: client, projectID: projectID, window: window)
    }

    private func loadBreakdown() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadBreakdown(
            client: client, projectID: projectID, window: window, dimension: dimension
        )
    }

    private func reloadAll() async {
        await loadOverview()
        await loadBreakdown()
    }
}

/// A single web-overview figure with its period-over-period change.
struct WebKPITile: View {
    let metric: WebOverviewMetric

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(metric.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(metric.formattedValue)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                changeIndicator
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// The arrow always points the way the number actually moved; the colour
    /// says whether that movement was good. Splitting the two is the only way to
    /// stay honest about metrics like bounce rate, where falling is a win — and
    /// it keeps direction legible without relying on colour.
    @ViewBuilder
    private var changeIndicator: some View {
        if let change = metric.changeFromPreviousPct, change != 0 {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(abs(change) / 100, format: .percent.precision(.fractionLength(0...1)))
                } icon: {
                    Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(verdictTint)

                // Without this, a green downward arrow just looks like a bug.
                if metric.isIncreaseBad == true {
                    Text("Lower is better")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("No prior period")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var verdictTint: Color {
        guard let improvement = metric.isImprovement else { return .secondary }
        return improvement ? Theme.Status.good : Theme.Status.critical
    }

    private var spokenSummary: String {
        var parts = ["\(metric.title), \(metric.formattedValue)"]
        if let change = metric.changeFromPreviousPct, change != 0 {
            let magnitude = (abs(change) / 100)
                .formatted(.percent.precision(.fractionLength(0...1)))
            var phrase = "\(change > 0 ? "up" : "down") \(magnitude) versus the previous period"
            if let improvement = metric.isImprovement {
                phrase += improvement ? ", an improvement" : ", a regression"
            }
            parts.append(phrase)
        } else {
            parts.append("no comparison with a previous period")
        }
        return parts.joined(separator: ", ")
    }
}

/// One ranked breakdown row, with a bar showing its share of the busiest entry.
struct WebStatsRowView: View {
    let row: WebStatsRow
    let rank: Int
    let fraction: Double

    private var label: String {
        row.breakdownValue.isEmpty ? "(not set)" : row.breakdownValue
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .trailing)

            Text(label)
                .font(.subheadline)
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            // Direct labels: the figures never depend on a column header that
            // may have scrolled out of view.
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(row.visitors.compactFormatted) visitors")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("\(row.views.compactFormatted) views")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(alignment: .leading) { proportionBar }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            """
            Rank \(rank), \(label), \
            \(row.visitors.formatted(.number.precision(.fractionLength(0)))) visitors, \
            \(row.views.formatted(.number.precision(.fractionLength(0)))) views
            """
        )
    }

    private var proportionBar: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.accent.opacity(0.16))
                .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
}
