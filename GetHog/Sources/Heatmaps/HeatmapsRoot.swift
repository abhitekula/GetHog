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

    /// How far the saved-render lookup got.
    ///
    /// Four states distinguish a successful empty response from a failed lookup.
    /// The UI must not infer that no render exists when the request failed.
    enum RenderLookup {
        /// Not asked yet, or still in flight. "There is nothing on this screen"
        /// is a claim rather than an observation until this resolves.
        case pending
        case loaded([SavedHeatmap])
        /// Asked, and PostHog did not answer. Carries the reason so the note can
        /// say it could not check, rather than that there was nothing to find.
        case failed(String)
    }

    var renderLookup: RenderLookup = .pending

    var isLoadingHeatmap = false
    var isLoadingElements = false
    var heatmapError: String?
    var elementsError: String?
    var loadedAt: Date?

    var isLoading: Bool { isLoadingHeatmap || isLoadingElements }

    /// Whether the *click* sections have anything to chart. Scoped to the two
    /// query responses on purpose — it is what decides skeletons and section
    /// placeholders, and it says nothing about the rest of the screen.
    var isEmpty: Bool { profile.isEmpty && elementStats.isEmpty }

    /// The saved renders this app can actually draw on. Empty while the lookup
    /// is pending or failed — which is a statement about what this screen can
    /// offer, never about what the project contains.
    var renderablePages: [SavedHeatmap] {
        guard case .loaded(let renders) = renderLookup else { return [] }
        return renders.filter(\.isRenderable)
    }

    /// Whether *no* section on this screen has anything, which is the only
    /// condition that justifies replacing the whole page with one state.
    ///
    /// The page renders are a third, independent source: they come from their
    /// own request, they are looked up per project rather than per window, and
    /// they are what the page overlay is reached through. Testing only the two
    /// click queries took the overlay off the screen entirely for any project
    /// with a saved render and no clicks in the window — which is exactly the
    /// demo project, so the feature could not be reached or reviewed at all.
    var hasNothingToShow: Bool { isEmpty && renderablePages.isEmpty }

    /// The render lookup has not answered yet. Until it does, "there is nothing
    /// on this screen" is a claim rather than an observation — the same
    /// discipline `renderLookup` is documented with, applied to the branch that
    /// would otherwise assert it a request early.
    ///
    /// A *failed* lookup is not resolving: it has finished, badly. The screen
    /// stops waiting and says what it could not check instead.
    var isResolvingRenders: Bool {
        if case .pending = renderLookup { true } else { false }
    }

    /// Why the render lookup failed, if it did. Read by the two states that
    /// would otherwise present its absence as a finding.
    var renderLookupFailure: String? {
        if case .failed(let reason) = renderLookup { reason } else { nil }
    }

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

    /// Looked up once per project, not once per date range: whether a page has a
    /// saved render has nothing to do with the window being charted, and
    /// re-asking on every range change would spend requests to learn the same
    /// answer.
    ///
    /// A failure must reach the closing note: an empty list is distinct from an
    /// unsuccessful lookup, and the UI must preserve that distinction.
    func loadSavedRenders(client: PostHogClient, projectID: Int) async {
        do {
            let page: Page<SavedHeatmap> = try await client.send(
                PostHogAPI.savedHeatmaps(projectID: projectID)
            )
            renderLookup = .loaded(page.results)
        } catch {
            renderLookup = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

/// Click distributions, plus a link to the page image where one exists.
///
/// PostHog renders a page image for any URL somebody saves as a heatmap in the
/// web console, and those renders are fetchable — so the picture its web
/// heatmap paints clicks over *is* available here, on those pages. It is also
/// rare: a render exists only where a person explicitly asked for one, and this
/// project has a single such page against a whole site's worth of traffic.
///
/// So the picture is a destination (`HeatmapPageOverlay`) and this screen stays
/// what it was — how far down people click, how far across, and what they
/// actually hit. Those three answers need no backdrop, which is what makes them
/// the right thing to show on every other page.
struct HeatmapsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var store = HeatmapsStore()
    @State private var window: AnalyticsWindow = .week
    @State private var lens: HeatmapLens = .depth
    @State private var kindFilter: ElementClickKind?

    var body: some View {
        content
            .navigationTitle("Clickmap")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .refreshable { await load() }
            .task(id: LoadKey(projectID: model.projectID, window: window)) { await load() }
            .task(id: model.projectID) { await loadSavedRenders() }
    }

    private struct LoadKey: Hashable {
        let projectID: Int?
        let window: AnalyticsWindow
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Both endpoints use event capture data, so the events capability is
            // the closest meaningful gate; individual request failures still
            // retain their server-provided text below.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        // Both full-screen states test `hasNothingToShow`, not `isEmpty`: either
        // one drawn over a project that has a saved page render would hide the
        // one section on this screen that neither query feeds. A failed query
        // still gets said — inline, on the section it belongs to.
        } else if let error = store.heatmapError ?? store.elementsError, store.hasNothingToShow {
            EmptyStateView(
                title: "Couldn't load the clickmap",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.hasNothingToShow && !store.isLoading && !store.isResolvingRenders {
            EmptyStateView(
                title: "No clicks recorded",
                systemImage: "hand.tap",
                // Both click queries answered with no rows. A saved-render lookup
                // is independent, so its failure remains an explicit caveat.
                message: "PostHog captured no clicks in the \(window.spokenTitle.lowercased())."
                    + (store.renderLookupFailure.map {
                        " This app also couldn't check whether the project has a saved page render: \(Self.sentence($0))"
                    } ?? "")
            )
        } else {
            report
        }
    }

    /// Both selectors share one glass bar. They are read together — a lens is
    /// always a lens *over a period* — and two separate bars would imply the
    /// screen has two unrelated controls.
    private var report: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                GlassFilterBar {
                    VStack(spacing: Theme.Space.s) {
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
                    }
                }

                Group {
                    overlayLinks

                    switch lens {
                    case .depth: depthSection
                    case .across: horizontalSection
                    case .elements: elementsSection
                    }

                    screenshotNote

                    FreshnessLabel(date: store.loadedAt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Theme.Space.l)
            }
            .padding(.vertical, Theme.Space.l)
        }
        .pageSurface()
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sectionHeader(
                "Click depth",
                systemImage: "arrow.down.to.line",
                subtitle: "Where down the page people click"
            )

            if let error = store.heatmapError {
                sectionErrorNote(error, hasEarlierData: !store.profile.isEmpty)
            }

            clickTotalsCard

            if !store.profile.depthBands.isEmpty {
                HeatmapDepthChart(profile: store.profile)
            } else if store.heatmapError == nil {
                // Only when the request answered. Both wordings below state what
                // PostHog reported, and a failed request reported nothing — this
                // branch is now reachable with an error above it, because the
                // screen no longer replaces itself wholesale when one query dies.
                EmptyStateView(
                    title: "No scroll-depth data",
                    systemImage: "arrow.down.to.line",
                    message: store.profile.fixedClicks > 0
                        ? "Every recorded click was on a fixed-position element, so none of them has a scroll depth."
                        : "No clicks were recorded in this period."
                )
                .frame(maxWidth: .infinity)
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
            // Long, sparse tails would compress useful bands, so pooled overflow
            // is stated rather than left implicit.
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
        // `coverageNote` is a whole sentence and ends like one.
        return parts.joinedAsSentences()
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sectionHeader(
                "Click position",
                systemImage: "arrow.left.and.right",
                subtitle: "Where across the page people click"
            )

            if let error = store.heatmapError {
                sectionErrorNote(error, hasEarlierData: !store.profile.isEmpty)
            }

            clickTotalsCard

            if !store.profile.horizontalBands.isEmpty {
                HeatmapColumnChart(profile: store.profile)
            } else if store.heatmapError == nil {
                // See `depthSection`: "no clicks were recorded" is an
                // observation, and a failed request made none.
                Text("No clicks were recorded in this period.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sectionHeader(
                "Most clicked elements",
                systemImage: "cursorarrow.rays",
                subtitle: "What visitors actually hit, ranked by clicks"
            )

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
                sectionErrorNote(error, hasEarlierData: !store.elementStats.isEmpty)
            }

            // See `depthSection`: `emptyElementsMessage` reports what PostHog
            // recorded, so it is only said once PostHog answered.
            if rankedElements.isEmpty && !store.isLoadingElements && store.elementsError == nil {
                EmptyStateView(
                    title: "No elements",
                    systemImage: "square.dashed",
                    message: emptyElementsMessage
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

    /// Hand-rolled container rather than `Card`: the proportional bars need to
    /// reach the container's edges, which a card's inner padding would inset.
    ///
    /// Reaching the edge is also why the container must *clip* rather than only
    /// draw a rounded background. The top row is full width because the scale is
    /// pinned to it.
    private var elementList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rankedElements.enumerated()), id: \.offset) { index, stat in
                if index > 0 { Divider().padding(.leading, Theme.Space.m) }
                ElementStatRowView(
                    stat: stat,
                    rank: index + 1,
                    fraction: peakElementCount > 0
                        ? Double(stat.count) / Double(peakElementCount)
                        : 0
                )
            }
        }
        .background(Theme.cardBackground)
        .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
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

    /// The sentence under the label is not decoration: "Depth" alone does not
    /// say depth *of what*, and the lens picker's own labels are abbreviated.
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

    /// The two things that are true, depending on the project.
    ///
    /// This note used to claim the page render "isn't available to this app".
    /// It is — `/heatmap_screenshots/` serves the same image PostHog's web
    /// heatmap paints over, at real device widths. What is scarce is coverage:
    /// a render exists only for URLs somebody saved as a heatmap in the web
    /// console, and the charts above aggregate every URL in the project. So the
    /// note now says which of those two situations the reader is in, and the
    /// no-render wording no longer blames the app for a picture the project
    /// simply has not asked PostHog to draw.
    private var screenshotNote: some View {
        Text(screenshotNoteText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// Both places that quote a failure splice it into the middle of a
    /// paragraph, and `PostHogError`'s descriptions are inconsistently
    /// terminated — "Endpoint not found." ends in a stop, "Couldn't reach
    /// PostHog: connection lost" does not — so without this the next sentence
    /// runs straight into it.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }

    private var screenshotNoteText: String {
        let lede = "PostHog's web heatmap paints these clicks over a rendered image of the page. It renders one only for pages saved as a heatmap in the web console"

        // Absence is a finding only after a successful response; a pending or
        // failed lookup must not be presented as an empty collection.
        switch store.renderLookup {
        case .pending:
            return "\(lede); checking whether this project has any."

        case .failed(let reason):
            return "\(lede). This app couldn't check whether this project has any: \(Self.sentence(reason)) The charts above are unaffected — what's missing is the link to a page image, if one exists."

        case .loaded(let renders):
            let pages = renders.filter(\.isRenderable)
            guard !pages.isEmpty else {
                // Now it is an observation, so it can be stated as one.
                return "\(lede), and this project has none, so the numbers here stand on their own."
            }
            let noun = pages.count == 1 ? "one saved page" : "\(pages.count) saved pages"
            return "The charts above aggregate every URL in the project, so no single page image fits them. PostHog has rendered \(noun) in this project — open it above to see these clicks drawn on the page itself."
        }
    }

    /// Only shown when there is an image to open. An always-present row that
    /// usually explained why it could do nothing would be the same false promise
    /// the old note made, moved into the layout.
    @ViewBuilder
    private var overlayLinks: some View {
        let pages = store.renderablePages
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(text: "Pages with a render", systemImage: "photo.on.rectangle")

                VStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        if index > 0 { Divider().padding(.leading, Theme.Space.m) }
                        NavigationLink {
                            HeatmapPageOverlay(saved: page, window: window)
                        } label: {
                            DataRow(
                                glyph: "photo",
                                tint: Theme.accent,
                                title: page.name ?? page.url,
                                subtitle: page.name == nil ? nil : page.url,
                                footnote: renderFootnote(for: page),
                                isSubtitleMonospaced: true,
                                accessory: .chevron
                            )
                            .truncationMode(.middle)
                            .padding(.vertical, Theme.Space.xs)
                            .padding(.horizontal, Theme.Space.m)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    Theme.cardBackground,
                    in: .rect(cornerRadius: Theme.Radius.medium, style: .continuous)
                )
            }
        }
    }

    private func renderFootnote(for page: SavedHeatmap) -> String {
        // The widths are the reason the overlay can be trusted on this device,
        // so they are stated rather than left as an implementation detail.
        let widths = page.renderedWidths
        guard let first = widths.first, let last = widths.last else { return "Rendered" }
        return widths.count == 1
            ? "Rendered at \(first) px"
            : "Rendered at \(widths.count) widths, \(first)–\(last) px"
    }

    /// A failed request, said on the section it cost rather than over the page.
    ///
    /// The "earlier load" half is conditional because the note is no longer only
    /// shown beside surviving data: a project with a saved page render keeps the
    /// screen up when *both* queries fail, and telling that reader their empty
    /// chart is stale would invent a load that never happened.
    private func sectionErrorNote(_ text: String, hasEarlierData: Bool) -> some View {
        Label(
            hasEarlierData ? "This section is from an earlier load. \(text)" : text,
            systemImage: "exclamationmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, window: window)
    }

    private func loadSavedRenders() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadSavedRenders(client: client, projectID: projectID)
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

    /// The depth chart next door derives its height from its band count; this
    /// one's bands run across, so the box has to track the type size instead.
    /// Fixed, the "0–10%" axis labels grew into the plot and squeezed the bars.
    @ScaledMetric(relativeTo: .caption2) private var chartHeight: CGFloat = 240

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
        .frame(height: chartHeight)
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
        DataRow(
            glyph: stat.kind.systemImage,
            tint: clickKindTint(stat.kind),
            title: stat.label,
            // Monospaced so a tag reads as markup, not prose.
            subtitle: stat.tagName.map { "<\($0)>" },
            footnote: stat.ancestorLabel.map { "in “\($0)”" },
            isSubtitleMonospaced: true,
            // The kind is never left to the number alone: 40 dead clicks and
            // 40 real clicks are opposite findings, so the noun travels with
            // the count instead of relying on the glyph's colour.
            accessory: .metric("\(Double(stat.count).compactFormatted) \(stat.kind.noun)")
        )
        .truncationMode(.middle)
        .padding(.vertical, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.m)
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
///
/// Drawn entirely from the chrome palette. A dead click used to borrow a hue
/// from `SeriesPalette`, which implied a relationship to a plotted series that
/// does not exist — the warm secondary says "worth a look, not an emergency"
/// without spending a data colour on a row.
private func clickKindTint(_ kind: ElementClickKind) -> Color {
    switch kind {
    case .autocapture: Theme.accent
    case .rageClick: Theme.Status.critical
    case .deadClick: Theme.accentWarm
    case .other: .secondary
    }
}
