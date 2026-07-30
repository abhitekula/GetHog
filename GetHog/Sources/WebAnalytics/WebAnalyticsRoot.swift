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

    /// Leads every row of the breakdown, so switching dimension is visible
    /// before a single value is read.
    var glyph: String {
        switch self {
        case .page: "doc.text"
        case .referrer: "arrow.turn.down.right"
        case .device: "iphone"
        case .browser: "safari"
        case .country: "globe"
        }
    }
}

@MainActor
@Observable
final class WebAnalyticsStore {
    var metrics: [WebOverviewMetric] = []
    var rows: [WebStatsRow] = []
    var notableChanges: [WebNotableChange] = []
    var externalClicks: [WebExternalClickRow] = []
    var vitals: WebVitalsBreakdown?
    var marketingColumns: [String] = []
    var marketingRows: [MarketingRow] = []
    var isLoadingOverview = false
    var isLoadingRows = false
    var isLoadingChanges = false
    var isLoadingClicks = false
    var isLoadingVitals = false
    var isLoadingMarketing = false
    var overviewError: String?
    var rowsError: String?
    var changesError: String?
    var clicksError: String?
    var vitalsError: String?
    var marketingError: String?
    var loadedAt: Date?

    var isLoading: Bool {
        isLoadingOverview || isLoadingRows || isLoadingChanges
            || isLoadingClicks || isLoadingVitals || isLoadingMarketing
    }

    var isEmpty: Bool {
        metrics.isEmpty && rows.isEmpty && notableChanges.isEmpty && externalClicks.isEmpty
            && (vitals?.isEmpty ?? true) && marketingRows.isEmpty
    }

    /// Any failure at all, for the case where nothing loaded and the screen has
    /// to say why. Per-section errors stay separate so one failing query only
    /// costs its own section.
    var anyError: String? {
        overviewError ?? rowsError ?? changesError ?? clicksError ?? vitalsError ?? marketingError
    }

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

    func loadNotableChanges(client: PostHogClient, projectID: Int, window: AnalyticsWindow) async {
        isLoadingChanges = true
        defer { isLoadingChanges = false }
        do {
            let response: WebNotableChangesResponse = try await client.send(
                PostHogAPI.webNotableChanges(projectID: projectID, dateFrom: window.rawValue)
            )
            notableChanges = response.changes
            loadedAt = Date()
            changesError = nil
        } catch {
            changesError = Self.message(for: error)
        }
    }

    func loadExternalClicks(client: PostHogClient, projectID: Int, window: AnalyticsWindow) async {
        isLoadingClicks = true
        defer { isLoadingClicks = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.webExternalClicks(projectID: projectID, dateFrom: window.rawValue)
            )
            externalClicks = WebExternalClickRow.rows(from: response)
            loadedAt = Date()
            clicksError = nil
        } catch {
            clicksError = Self.message(for: error)
        }
    }

    func loadVitals(
        client: PostHogClient,
        projectID: Int,
        window: AnalyticsWindow,
        metric: WebVitalMetric,
        percentile: WebVitalPercentile
    ) async {
        isLoadingVitals = true
        defer { isLoadingVitals = false }
        do {
            let response: WebVitalsBreakdown = try await client.send(
                PostHogAPI.webVitals(
                    projectID: projectID,
                    metric: metric.rawValue,
                    dateFrom: window.rawValue,
                    percentile: percentile.rawValue
                )
            )
            vitals = response
            loadedAt = Date()
            vitalsError = nil
        } catch {
            vitalsError = Self.message(for: error)
        }
    }

    func loadMarketing(client: PostHogClient, projectID: Int, window: AnalyticsWindow) async {
        isLoadingMarketing = true
        defer { isLoadingMarketing = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.marketingAnalytics(projectID: projectID, dateFrom: window.rawValue)
            )
            marketingColumns = MarketingTable.columns(from: response)
            marketingRows = MarketingTable.rows(from: response)
            loadedAt = Date()
            marketingError = nil
        } catch {
            marketingError = Self.message(for: error)
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
    @State private var vitalMetric: WebVitalMetric = .lcp
    /// p75, because that is where Google defines the bands this screen draws.
    @State private var vitalPercentile: WebVitalPercentile = .p75
    @State private var search = ""

    /// A flat report with nothing to select — a split view would owe iPad a
    /// detail pane it does not have, so this screen is a plain stack.
    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Web")
                .toolbar { ProjectSwitcher() }
                .projectSubtitle()
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
                // Neither of these depends on the breakdown dimension, so they
                // share the overview's key rather than re-firing alongside it.
                .task(id: OverviewKey(projectID: model.projectID, window: window)) {
                    await loadNotableChanges()
                }
                .task(id: OverviewKey(projectID: model.projectID, window: window)) {
                    await loadExternalClicks()
                }
                .task(id: OverviewKey(projectID: model.projectID, window: window)) {
                    await loadMarketing()
                }
                // Vitals carry two extra selectors of their own, so changing the
                // metric refetches only this one query.
                .task(id: VitalsKey(
                    projectID: model.projectID,
                    window: window,
                    metric: vitalMetric,
                    percentile: vitalPercentile
                )) {
                    await loadVitals()
                }
        }
    }

    private struct VitalsKey: Hashable {
        let projectID: Int?
        let window: AnalyticsWindow
        let metric: WebVitalMetric
        let percentile: WebVitalPercentile
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
        } else if let error = store.anyError, store.isEmpty {
            EmptyStateView(
                title: "Couldn't load web analytics",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await reloadAll() } }
            )
        } else if store.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No web traffic",
                systemImage: "globe",
                message: "Nothing was recorded in the \(window.spokenTitle.lowercased())."
            )
        } else {
            report
        }
    }

    /// Each section owns its horizontal inset rather than inheriting one from
    /// the stack, so the KPI strip can scroll edge to edge while everything else
    /// stays on the page margin.
    private var report: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                GlassFilterBar { windowPicker }
                overviewSection
                // Between the totals and the detail: the headline figures give
                // it context, and it names what to open in the breakdown below.
                notableChangesSection
                    .padding(.horizontal, Theme.Space.l)
                breakdownSection
                    .padding(.horizontal, Theme.Space.l)
                vitalsSection
                    .padding(.horizontal, Theme.Space.l)
                outboundSection
                    .padding(.horizontal, Theme.Space.l)
                marketingSection
                    .padding(.horizontal, Theme.Space.l)
                FreshnessLabel(date: store.loadedAt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.l)
            }
            .padding(.vertical, Theme.Space.l)
        }
        .pageSurface()
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Overview", systemImage: "chart.bar.xaxis")
                .padding(.horizontal, Theme.Space.l)

            // A scrolling strip rather than a reflowing grid: a tile squeezed
            // until its figure truncates has stopped being a metric, and the
            // grid did exactly that at large text sizes.
            StatStrip {
                ForEach(store.metrics) { metric in
                    WebKPITile(metric: metric)
                }
            }
            .skeleton(store.isLoadingOverview && store.metrics.isEmpty)

            if let error = store.overviewError, !store.metrics.isEmpty {
                staleNote("These figures are from an earlier load. \(error)")
                    .padding(.horizontal, Theme.Space.l)
            }
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Breakdown", systemImage: "list.number")

            dimensionPicker

            if filteredRows.isEmpty && !store.isLoadingRows {
                EmptyStateView(
                    title: search.isEmpty ? "No \(dimension.pluralTitle)" : "No matches",
                    systemImage: "magnifyingglass",
                    message: search.isEmpty
                        ? "PostHog returned no \(dimension.pluralTitle) for this period."
                        : "No \(dimension.pluralTitle) matched “\(search)”."
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
                    Divider().padding(.leading, Theme.Space.m)
                }
                WebStatsRowView(
                    row: row,
                    rank: index + 1,
                    fraction: store.peakVisitors > 0 ? row.visitors / store.peakVisitors : 0,
                    glyph: dimension.glyph
                )
            }
        }
        .background(
            Theme.cardBackground,
            in: .rect(cornerRadius: Theme.Radius.medium, style: .continuous)
        )
        .skeleton(store.isLoadingRows && store.rows.isEmpty)
    }

    private var notableChangesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sectionHeader(
                "Where to look first",
                systemImage: "sparkles",
                subtitle: "PostHog's ranking of the dimensions that stand out, highest impact first."
            )

            if store.notableChanges.isEmpty && !store.isLoadingChanges {
                EmptyStateView(
                    title: "Nothing notable",
                    systemImage: "sparkles",
                    message: "PostHog flagged no standout dimensions in the \(window.spokenTitle.lowercased())."
                )
                .frame(maxWidth: .infinity)
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(store.notableChanges.enumerated()), id: \.element.id) { index, change in
                            if index > 0 {
                                Divider().padding(.vertical, Theme.Space.s)
                            }
                            WebNotableChangeRow(change: change, rank: index + 1)
                        }
                    }
                }
                .skeleton(store.isLoadingChanges && store.notableChanges.isEmpty)

                if let note = comparisonNote {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = store.changesError, !store.notableChanges.isEmpty {
                staleNote("This ranking is from an earlier load. \(error)")
            }
        }
    }

    private var outboundSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sectionHeader(
                "Outbound links",
                systemImage: "arrow.up.forward.square",
                subtitle: "External destinations visitors clicked through to."
            )

            if topExternalClicks.isEmpty && !store.isLoadingClicks {
                EmptyStateView(
                    title: "No outbound clicks",
                    systemImage: "arrow.up.forward.square",
                    message: """
                        Nothing led off the site in the \(window.spokenTitle.lowercased()). \
                        PostHog only records these when external link tracking is switched on.
                        """
                )
                .frame(maxWidth: .infinity)
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(topExternalClicks.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Divider().padding(.vertical, Theme.Space.s)
                            }
                            WebExternalClickRowView(row: row, rank: index + 1)
                        }
                    }
                }
                .skeleton(store.isLoadingClicks && store.externalClicks.isEmpty)
            }

            if let error = store.clicksError, !store.externalClicks.isEmpty {
                staleNote("This list is from an earlier load. \(error)")
            }
        }
    }

    private var vitalsSection: some View {
        WebVitalsSection(
            metric: $vitalMetric,
            percentile: $vitalPercentile,
            breakdown: store.vitals,
            isLoading: store.isLoadingVitals,
            error: store.vitalsError,
            onRetry: { Task { await loadVitals() } }
        )
    }

    private var marketingSection: some View {
        MarketingSection(
            columns: store.marketingColumns,
            rows: store.marketingRows,
            isLoading: store.isLoadingMarketing,
            error: store.marketingError,
            onRetry: { Task { await loadMarketing() } }
        )
    }

    private func sectionHeader(
        _ title: String,
        systemImage: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: title, systemImage: systemImage)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    /// Stated once for the section rather than repeated under all eight rows.
    /// The rows already mark the absence individually; this explains it.
    private var comparisonNote: String? {
        let changes = store.notableChanges
        guard !changes.isEmpty, changes.allSatisfy({ !$0.hasComparablePrevious }) else { return nil }
        return """
            PostHog returned no previous-period figures for this window, \
            so these are ranked by impact score alone.
            """
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

    /// The external-clicks query carries no `limit`, so the cap lives here.
    /// Sorted client-side too, since the API promises no ordering.
    private var topExternalClicks: [WebExternalClickRow] {
        Array(store.externalClicks.sorted { $0.clicks > $1.clicks }.prefix(25))
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

    private func loadNotableChanges() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadNotableChanges(client: client, projectID: projectID, window: window)
    }

    private func loadExternalClicks() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadExternalClicks(client: client, projectID: projectID, window: window)
    }

    private func loadVitals() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadVitals(
            client: client,
            projectID: projectID,
            window: window,
            metric: vitalMetric,
            percentile: vitalPercentile
        )
    }

    private func loadMarketing() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadMarketing(client: client, projectID: projectID, window: window)
    }

    private func reloadAll() async {
        await loadOverview()
        await loadBreakdown()
        await loadNotableChanges()
        await loadExternalClicks()
        await loadVitals()
        await loadMarketing()
    }
}

/// A single web-overview figure with its period-over-period change.
struct WebKPITile: View {
    let metric: WebOverviewMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The arrow inside the delta always points the way the number
            // actually moved; the colour says whether that movement was good.
            // Splitting the two is the only way to stay honest about metrics
            // like bounce rate, where falling is a win — and it keeps direction
            // legible without relying on colour. `isIncreaseBad` is carried
            // straight from the API rather than decided here.
            MetricTile(
                label: metric.title,
                value: metric.formattedValue,
                delta: metric.value.map { (current: $0, previous: metric.previous) },
                isIncreaseBad: metric.isIncreaseBad ?? false,
                compact: true
            )

            // Without this, a green downward arrow just looks like a bug.
            if metric.isIncreaseBad == true {
                Text("Lower is better")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // A floor rather than a fixed width: tiles stay comparable down the
        // strip without clipping a long metric name.
        .frame(minWidth: 132, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
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
    let glyph: String

    private var label: String {
        row.breakdownValue.isEmpty ? "(not set)" : row.breakdownValue
    }

    var body: some View {
        // Direct labels on both figures: neither depends on a column header
        // that may have scrolled out of view.
        DataRow(
            glyph: glyph,
            title: label,
            subtitle: "\(row.views.compactFormatted) views",
            accessory: .metric("\(row.visitors.compactFormatted) visitors")
        )
        // Middle truncation for the whole row: page paths and referrer domains
        // share long prefixes, so the tail is what tells two of them apart.
        .truncationMode(.middle)
        .padding(.vertical, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.m)
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
