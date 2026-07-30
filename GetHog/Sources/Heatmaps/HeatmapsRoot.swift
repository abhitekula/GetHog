import Accessibility
import Charts
import GetHogKit
import SwiftUI

/// Which of the three clickmap questions is on screen.
enum HeatmapLens: String, CaseIterable, Identifiable, Hashable {
    case depth
    case across
    case elements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .depth: "Depth"
        case .across: "Across"
        case .elements: "Elements"
        }
    }

    var spokenTitle: String {
        switch self {
        case .depth: "Click depth down the page"
        case .across: "Click position across the page"
        case .elements: "Most clicked elements"
        }
    }
}

@MainActor
@Observable
final class HeatmapsStore {
    var profile = HeatmapProfile.make(points: [])
    var elementStats: [ElementStat] = []

    /// PostHog had more elements than it returned. There is no total to compare
    /// against on this endpoint — only `next` — so the note can say the list is
    /// capped but never how much was left off.
    var elementsTruncated = false

    var isLoadingHeatmap = false
    var isLoadingElements = false
    var heatmapError: String?
    var elementsError: String?
    var loadedAt: Date?

    var isLoading: Bool { isLoadingHeatmap || isLoadingElements }
    var isEmpty: Bool { profile.isEmpty && elementStats.isEmpty }

    /// Two independent requests. A heatmap outage must not blank the element
    /// list — they answer different questions and either is useful alone.
    func load(client: PostHogClient, projectID: Int, window: AnalyticsWindow) async {
        async let coordinates: Void = loadCoordinates(
            client: client, projectID: projectID, window: window
        )
        async let elements: Void = loadElements(
            client: client, projectID: projectID, window: window
        )
        _ = await (coordinates, elements)
    }

    private func loadCoordinates(
        client: PostHogClient,
        projectID: Int,
        window: AnalyticsWindow
    ) async {
        isLoadingHeatmap = true
        defer { isLoadingHeatmap = false }
        do {
            // Deliberately not `Page<HeatmapPoint>`: that would decode cleanly
            // and throw away `fold` and `has_more`, leaving the screen to add up
            // a truncated sample and present it as a total.
            let response: HeatmapResponse = try await client.send(
                PostHogAPI.heatmap(projectID: projectID, dateFrom: window.rawValue)
            )
            profile = HeatmapProfile.make(response)
            heatmapError = nil
            loadedAt = Date()
        } catch {
            heatmapError = Self.message(for: error)
        }
    }

    private func loadElements(
        client: PostHogClient,
        projectID: Int,
        window: AnalyticsWindow
    ) async {
        isLoadingElements = true
        defer { isLoadingElements = false }
        do {
            let page: Page<ElementStat> = try await client.send(
                PostHogAPI.elementStats(projectID: projectID, dateFrom: window.rawValue)
            )
            elementStats = page.results
            elementsTruncated = page.next != nil
            elementsError = nil
            loadedAt = Date()
        } catch {
            elementsError = Self.message(for: error)
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

/// A clickmap without the screenshot.
///
/// PostHog's web heatmap paints coordinates over a live render of the page. A
/// phone has neither the page nor a way to render it, and a fabricated backdrop
/// would put clicks over content they never touched. So this screen shows the
/// two distributions and the one ranking that are true on their own: how far
/// down people click, how far across, and what they actually hit.
struct HeatmapsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var store = HeatmapsStore()
    @State private var window: AnalyticsWindow = .week
    @State private var lens: HeatmapLens = .depth
    @State private var kindFilter: ElementClickKind?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Clickmap")
                .toolbar { ProjectSwitcher() }
                .refreshable { await load() }
                .task(id: LoadKey(projectID: model.projectID, window: window)) { await load() }
        }
    }

    private struct LoadKey: Hashable {
        let projectID: Int?
        let window: AnalyticsWindow
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // There is no heatmap scope to probe. Both endpoints read captured
            // autocapture data, the same material the events feed reads, so this
            // is the closest gate that is actually true — and a key that somehow
            // has one and not the other still gets the real 403 text below.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.heatmapError ?? store.elementsError, store.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load the clickmap", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No clicks recorded",
                systemImage: "hand.tap",
                description: Text(
                    "PostHog captured no clicks in the \(window.spokenTitle.lowercased()). Heatmap data needs autocapture enabled in your web SDK."
                )
            )
        } else {
            report
        }
    }

    private var report: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                adaptivelyStyled(
                    Picker("Date range", selection: $window) {
                        ForEach(AnalyticsWindow.allCases) { option in
                            Text(option.title).accessibilityLabel(option.spokenTitle).tag(option)
                        }
                    }
                )

                adaptivelyStyled(
                    Picker("View", selection: $lens) {
                        ForEach(HeatmapLens.allCases) { option in
                            Text(option.title).accessibilityLabel(option.spokenTitle).tag(option)
                        }
                    }
                )

                switch lens {
                case .depth: depthSection
                case .across: horizontalSection
                case .elements: elementsSection
                }

                noScreenshotNote

                FreshnessLabel(date: store.loadedAt)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
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

    // MARK: - Depth

    @ViewBuilder
    private var depthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where down the page people click")
                .font(.headline)

            if let error = store.heatmapError {
                staleNote(error)
            }

            clickTotalsCard

            if store.profile.depthBands.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No scroll-depth data")
                            .font(.subheadline.weight(.semibold))
                        Text(store.profile.fixedClicks > 0
                            ? "Every recorded click was on a fixed-position element, so none of them has a scroll depth."
                            : "No clicks were recorded in this period.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HeatmapDepthChart(profile: store.profile)
            }

            fixedClicksCard

            Text(depthFootnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .skeleton(store.isLoadingHeatmap && store.profile.isEmpty)
    }

    private var depthFootnote: String {
        var parts = ["Bands are CSS pixels from the top of the document. The axis stays in pixels rather than a percentage of the page, because the response never says how tall any page is."]
        if let overflow = store.profile.overflowBand {
            // Real pages produce a very long, very thin tail — the live capture
            // reached 25,872 px on two clicks. Scaling the axis to that turns
            // every band that matters into a hairline, so the tail is pooled and
            // the pooling is stated rather than left to be noticed.
            parts.append("The last band pools everything deeper than \(overflow.start.formatted()) px, where clicks are too sparse to band separately.")
        }
        if let height = store.profile.fold?.medianViewportHeight {
            parts.append("The fold line sits at the median viewport height, \(height.formatted()) px — half of visitors saw less than that without scrolling, so it is a typical fold and not anyone's in particular.")
        }
        return parts.joined(separator: " ")
    }

    /// The one place on this screen that states counts, so it is the one place
    /// that has to keep clicks and positions apart.
    ///
    /// There is deliberately no "total clicks" figure. A row is one position
    /// carrying a click `count`, `fold` counts positions, and the positions
    /// PostHog withheld carry an unknown number of clicks — so no total exists
    /// to state. The headline says what it can stand behind, and the line under
    /// it says how much of the page that covers.
    @ViewBuilder
    private var clickTotalsCard: some View {
        if !store.profile.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(store.profile.sampledClicks.formatted()) clicks")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()

                    Text(store.profile.coverageNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let fold = store.profile.fold {
                        // "positions", not "clicks", and taken from `fold` rather
                        // than the rows: rows arrive hottest-first and hot
                        // positions sit above the fold, so the sample's own share
                        // is about a third of the truth.
                        Text("\(fold.belowFoldShare.formatted(.percent.precision(.fractionLength(0...1)))) of click positions are below the fold — reaching them meant scrolling.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(totalsSpokenSummary)
        }
    }

    private var totalsSpokenSummary: String {
        var parts = [
            "\(store.profile.sampledClicks.formatted()) clicks",
            store.profile.coverageNote,
        ]
        if let fold = store.profile.fold {
            parts.append(
                "\(fold.belowFoldCount) click positions below the fold, \(fold.belowFoldShare.formatted(.percent.precision(.fractionLength(0...1)))) of them"
            )
        }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private var fixedClicksCard: some View {
        if store.profile.fixedClicks > 0 {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "\(Double(store.profile.fixedClicks).compactFormatted) clicks on fixed elements",
                        systemImage: "pin"
                    )
                    .font(.subheadline.weight(.semibold))

                    Text("\(store.profile.fixedShare.formatted(.percent.precision(.fractionLength(0)))) of the charted clicks landed on sticky navigation, floating buttons or pinned footers. Their vertical position is a screen position, not a scroll depth, so they are counted here and left out of the chart above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(store.profile.fixedClicks) of the \(store.profile.sampledClicks) charted clicks were on fixed-position elements, \(store.profile.fixedShare.formatted(.percent.precision(.fractionLength(0)))). They are excluded from the scroll depth chart because their vertical position is not a scroll depth."
            )
        }
    }

    // MARK: - Horizontal

    @ViewBuilder
    private var horizontalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where across the page people click")
                .font(.headline)

            if let error = store.heatmapError {
                staleNote(error)
            }

            clickTotalsCard

            if store.profile.horizontalBands.isEmpty {
                Text("No clicks were recorded in this period.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HeatmapColumnChart(profile: store.profile)
            }

            Text("Horizontal position is a fraction of the viewport width, so it is comparable across every screen size — and unlike depth it means something for fixed elements too, which are included here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .skeleton(store.isLoadingHeatmap && store.profile.isEmpty)
    }

    // MARK: - Elements

    @ViewBuilder
    private var elementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most clicked elements")
                .font(.headline)

            adaptivelyStyled(
                Picker("Click type", selection: $kindFilter) {
                    Text("All").tag(ElementClickKind?.none)
                    ForEach(ElementClickKind.selectable) { kind in
                        Text(kind.title).tag(ElementClickKind?.some(kind))
                    }
                }
            )

            if let kindFilter {
                Text(kindFilter.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = store.elementsError {
                staleNote(error)
            }

            if rankedElements.isEmpty && !store.isLoadingElements {
                ContentUnavailableView(
                    "No elements",
                    systemImage: "square.dashed",
                    description: Text(emptyElementsMessage)
                )
                .frame(maxWidth: .infinity)
            } else {
                elementList

                // The endpoint reports only that more exists, never how much, so
                // the note stops exactly where the evidence does.
                if store.elementsTruncated {
                    Label(
                        "Showing the \(store.elementStats.count) most-clicked elements. PostHog has more than it returned.",
                        systemImage: "ellipsis.rectangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .skeleton(store.isLoadingElements && store.elementStats.isEmpty)
    }

    private var elementList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rankedElements.enumerated()), id: \.offset) { index, stat in
                if index > 0 { Divider().padding(.leading, 12) }
                ElementStatRowView(
                    stat: stat,
                    rank: index + 1,
                    fraction: peakElementCount > 0
                        ? Double(stat.count) / Double(peakElementCount)
                        : 0
                )
            }
        }
        .background(Theme.cardBackground, in: .rect(cornerRadius: 14))
    }

    /// The bar scale is pinned to the top row of the *current* filter, so
    /// switching to dead clicks doesn't leave every bar a sliver.
    private var peakElementCount: Int {
        rankedElements.first?.count ?? 0
    }

    private var rankedElements: [ElementStat] {
        ElementStat.ranked(store.elementStats, kind: kindFilter)
    }

    private var emptyElementsMessage: String {
        guard let kindFilter else {
            return "PostHog recorded no element clicks in this period."
        }
        return "No \(kindFilter.title.lowercased()) were recorded in this period."
    }

    // MARK: - Chrome

    private var noScreenshotNote: some View {
        Text("PostHog's web heatmap paints these clicks over a screenshot of the page. That render isn't available to this app, so nothing here is drawn over a page image — the numbers stand on their own.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func staleNote(_ text: String) -> some View {
        Label("This section is from an earlier load. \(text)", systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, window: window)
    }
}

// MARK: - Charts

/// Scroll depth as a horizontal bar per band, shallowest at the top.
///
/// Horizontal bars and a top-down axis so the chart is oriented the same way as
/// the page it describes; a vertical bar chart would put "deep in the page" on
/// the right, which reads as later in time.
struct HeatmapDepthChart: View {
    let profile: HeatmapProfile

    var body: some View {
        Chart {
            ForEach(profile.depthBands) { band in
                BarMark(
                    x: .value("Clicks", band.clicks),
                    y: .value("Depth", band.label)
                )
                // The catch-all band spans the rest of the document rather than
                // one 300px slice, so it is drawn as a different thing rather
                // than as one more equal step down the page.
                .foregroundStyle(
                    band.isOverflow ? Color.secondary : SeriesPalette.color(at: 0)
                )
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    // Direct labels: on a phone the x-axis is too coarse to read
                    // a bar against, and a near-empty band would otherwise be a
                    // hairline with no number attached to it.
                    Text(band.clicks.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(band.spokenLabel)
                .accessibilityValue(spokenValue(for: band))
            }

            // Dashed and labelled, because it is a median viewport height rather
            // than a measured boundary — bars land on one side or the other of a
            // line that is only true for the middle visitor.
            if let foldBand = profile.foldBandLabel {
                RuleMark(y: .value("Depth", foldBand))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text("Median fold")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Median fold line")
                    .accessibilityValue(foldSpokenValue)
            }
        }
        .chartYScale(domain: profile.depthBands.map(\.label))
        // Room on the right for the direct value labels, which would otherwise
        // be clipped at the plot edge.
        .chartXScale(domain: 0...Double(max(profile.peakDepthClicks, 1)) * 1.18)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .extended, position: .leading) { _ in
                // Labels only, drawn outside the plot: gridlines behind a dozen
                // bars added stripes without adding information, and the value
                // is already printed on each bar.
                AxisValueLabel(horizontalSpacing: 8)
            }
        }
        .frame(height: chartHeight)
        .accessibilityChartDescriptor(DepthDescriptor(profile: profile))
    }

    /// Sized per band rather than capped, so bars stay thick enough to compare.
    /// The band count is bounded in the kit, so this can't run away.
    private var chartHeight: CGFloat {
        max(180, CGFloat(profile.depthBands.count) * 30)
    }

    private func spokenValue(for band: ClickDepthBand) -> String {
        let share = profile.scrollableClicks > 0
            ? Double(band.clicks) / Double(profile.scrollableClicks)
            : 0
        return "\(band.clicks) clicks, \(share.formatted(.percent.precision(.fractionLength(0...1)))) of the charted scroll-positioned clicks"
    }

    private var foldSpokenValue: String {
        guard let height = profile.fold?.medianViewportHeight else { return "Median fold" }
        return "Median viewport height, \(height) pixels. Anything below this line needed scrolling for at least half of visitors."
    }
}

/// Left-to-right click distribution across the viewport width.
struct HeatmapColumnChart: View {
    let profile: HeatmapProfile

    var body: some View {
        Chart(profile.horizontalBands) { band in
            BarMark(
                x: .value("Across", band.label),
                y: .value("Clicks", band.clicks)
            )
            .foregroundStyle(SeriesPalette.color(at: 2))
            .accessibilityLabel(band.label)
            .accessibilityValue(spokenValue(for: band))
        }
        .chartXScale(domain: profile.horizontalBands.map(\.label))
        .chartXAxis {
            AxisMarks { value in
                // Every other label: ten "0–10%"-style ticks overlap on a phone.
                if value.index.isMultiple(of: 2) {
                    AxisValueLabel()
                }
                AxisGridLine()
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 240)
        .accessibilityChartDescriptor(ColumnDescriptor(profile: profile))
    }

    private func spokenValue(for band: ClickColumnBand) -> String {
        let total = profile.horizontalTotal
        let share = total > 0 ? Double(band.clicks) / Double(total) : 0
        return "\(band.clicks) clicks, \(share.formatted(.percent.precision(.fractionLength(0...1)))) of all clicks"
    }
}

// MARK: - Chart descriptors
//
// The rotor descriptors matter more here than on most charts: with no
// screenshot the chart *is* the whole finding, so it has to be navigable point
// by point rather than summarised in one sentence.

private struct DepthDescriptor: AXChartDescriptorRepresentable {
    let profile: HeatmapProfile

    func makeChartDescriptor() -> AXChartDescriptor {
        let bands = profile.depthBands

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Depth down the page",
            categoryOrder: bands.map(\.label)
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Clicks",
            range: 0...Double(max(profile.peakDepthClicks, 1)),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0))) }

        return AXChartDescriptor(
            title: "Clicks by scroll depth",
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Clicks",
                    isContinuous: false,
                    dataPoints: bands.map {
                        AXDataPoint(x: $0.spokenLabel, y: Double($0.clicks))
                    }
                )
            ]
        )
    }

    private var summary: String {
        var parts = [
            "\(profile.scrollableClicks) clicks on scrolling content across \(profile.depthBands.count) bands of \(profile.bandSize) pixels"
        ]
        if let peak = profile.peakDepthBand {
            parts.append("busiest band \(peak.spokenLabel) with \(peak.clicks) clicks")
        }
        if let overflow = profile.overflowBand {
            parts.append(
                "a final band holds \(overflow.clicks) clicks deeper than \(overflow.start) pixels"
            )
        }
        if let height = profile.fold?.medianViewportHeight {
            parts.append("median fold at \(height) pixels")
        }
        if let fold = profile.fold {
            parts.append(
                "\(fold.pctBelowFold.formatted(.number.precision(.fractionLength(0...1)))) percent of click positions are below the fold"
            )
        }
        if profile.fixedClicks > 0 {
            parts.append("\(profile.fixedClicks) clicks on fixed elements are excluded")
        }
        // Stated last so it is the thing a listener is left holding.
        parts.append(profile.coverageNote)
        return parts.joined(separator: ", ")
    }
}

private struct ColumnDescriptor: AXChartDescriptorRepresentable {
    let profile: HeatmapProfile

    func makeChartDescriptor() -> AXChartDescriptor {
        let bands = profile.horizontalBands

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Position across the viewport",
            categoryOrder: bands.map(\.label)
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Clicks",
            range: 0...Double(max(profile.peakHorizontalClicks, 1)),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0))) }

        let busiest = bands.max { $0.clicks < $1.clicks }

        return AXChartDescriptor(
            title: "Clicks across the page",
            summary: "\(profile.horizontalTotal) clicks in \(bands.count) columns"
                + (busiest.map { ", busiest \($0.label) with \($0.clicks) clicks" } ?? ""),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Clicks",
                    isContinuous: false,
                    dataPoints: bands.map { AXDataPoint(x: $0.label, y: Double($0.clicks)) }
                )
            ]
        )
    }
}

// MARK: - Element row

/// One ranked element, with the kind of click always stated in words.
struct ElementStatRowView: View {
    let stat: ElementStat
    let rank: Int
    let fraction: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(stat.label)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if let tag = stat.tagName {
                        // Monospaced so a tag reads as markup, not prose.
                        Text("<\(tag)>")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let ancestor = stat.ancestorLabel {
                        Text("in “\(ancestor)”")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Double(stat.count).compactFormatted)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                // The kind is never left to the number alone: 40 dead clicks and
                // 40 real clicks are opposite findings.
                StatusPill(text: stat.kind.title, tint: clickKindTint(stat.kind))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(alignment: .leading) { proportionBar }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var proportionBar: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 6)
                .fill(clickKindTint(stat.kind).opacity(0.14))
                .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }

    private var spokenSummary: String {
        var parts = ["Rank \(rank)", stat.label]
        if let tag = stat.tagName { parts.append("\(tag) element") }
        if let ancestor = stat.ancestorLabel { parts.append("inside \(ancestor)") }
        parts.append("\(stat.count) \(stat.kind.noun)")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Formatting
//
// File-private so concurrent work on other screens can't collide with the name.

/// Tint for a click kind. Always paired with the kind's name, never used alone.
private func clickKindTint(_ kind: ElementClickKind) -> Color {
    switch kind {
    case .autocapture: Theme.accent
    case .rageClick: Theme.Status.critical
    case .deadClick: SeriesPalette.color(at: 3)
    case .other: .secondary
    }
}
