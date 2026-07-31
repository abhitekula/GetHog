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
///
/// Twenty of the thirty-three the API accepts. `PostHogAPI.webStats` lists all
/// thirty-three and how they were established; the thirteen left out are named
/// in `omitted` below, with the measurement that ruled each one out, because
/// "we never got round to it" and "this one lies" are different facts and the
/// next person to widen this list needs to know which is which.
enum WebStatsDimension: String, CaseIterable, Identifiable, Hashable {

    // Where they went.
    case page = "Page"
    case entryPage = "InitialPage"
    case exitPage = "ExitPage"

    // Where they came from.
    case channel = "InitialChannelType"
    case referrer = "InitialReferringDomain"
    case referringURL = "InitialReferringURL"

    // What brought them.
    case utmSource = "InitialUTMSource"
    case utmMedium = "InitialUTMMedium"
    case utmCampaign = "InitialUTMCampaign"
    case utmContent = "InitialUTMContent"
    case utmTerm = "InitialUTMTerm"

    // What they were using.
    case device = "DeviceType"
    case browser = "Browser"
    case os = "OS"
    case viewport = "Viewport"

    // Where they were.
    case country = "Country"
    case region = "Region"
    case city = "City"
    case timezone = "Timezone"
    case language = "Language"

    var id: String { rawValue }

    /// The groups the picker draws, in this order. Every case appears in
    /// exactly one — a `switch` over `self` rather than a hand-kept list, so a
    /// new dimension cannot be added and then silently fail to appear in the
    /// menu.
    enum Group: String, CaseIterable, Identifiable, Hashable {
        case content = "Content"
        case acquisition = "Acquisition"
        case campaign = "Campaign"
        case technology = "Technology"
        case geography = "Geography"

        var id: String { rawValue }

        var members: [WebStatsDimension] {
            WebStatsDimension.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .page, .entryPage, .exitPage: .content
        case .channel, .referrer, .referringURL: .acquisition
        case .utmSource, .utmMedium, .utmCampaign, .utmContent, .utmTerm: .campaign
        case .device, .browser, .os, .viewport: .technology
        case .country, .region, .city, .timezone, .language: .geography
        }
    }

    var title: String {
        switch self {
        case .page: "Page"
        case .entryPage: "Entry page"
        case .exitPage: "Exit page"
        case .channel: "Channel"
        case .referrer: "Referrer"
        case .referringURL: "Referring URL"
        case .utmSource: "UTM source"
        case .utmMedium: "UTM medium"
        case .utmCampaign: "UTM campaign"
        case .utmContent: "UTM content"
        case .utmTerm: "UTM term"
        case .device: "Device"
        case .browser: "Browser"
        case .os: "Operating system"
        case .viewport: "Viewport"
        case .country: "Country"
        case .region: "Region"
        case .city: "City"
        case .timezone: "Time zone"
        case .language: "Language"
        }
    }

    var pluralTitle: String {
        switch self {
        case .page: "pages"
        case .entryPage: "entry pages"
        case .exitPage: "exit pages"
        case .channel: "channels"
        case .referrer: "referrers"
        case .referringURL: "referring URLs"
        case .utmSource: "UTM sources"
        case .utmMedium: "UTM mediums"
        case .utmCampaign: "UTM campaigns"
        case .utmContent: "UTM content values"
        case .utmTerm: "UTM terms"
        case .device: "devices"
        case .browser: "browsers"
        case .os: "operating systems"
        case .viewport: "viewport sizes"
        case .country: "countries"
        case .region: "regions"
        case .city: "cities"
        case .timezone: "time zones"
        case .language: "languages"
        }
    }

    /// Leads every row of the breakdown, so switching dimension is visible
    /// before a single value is read.
    var glyph: String {
        switch self {
        case .page: "doc.text"
        case .entryPage: "arrow.right.to.line"
        case .exitPage: "arrow.right.doc.on.clipboard"
        case .channel: "arrow.triangle.branch"
        case .referrer: "arrow.turn.down.right"
        case .referringURL: "link"
        case .utmSource, .utmMedium, .utmCampaign, .utmContent, .utmTerm: "megaphone"
        case .device: "iphone"
        case .browser: "safari"
        case .os: "desktopcomputer"
        case .viewport: "rectangle.expand.vertical"
        case .country: "globe"
        case .region: "map"
        case .city: "building.2"
        case .timezone: "clock"
        case .language: "character.bubble"
        }
    }

    // MARK: - Labelling

    /// What to call the bucket PostHog returns as JSON `null`.
    ///
    /// Every UTM dimension has one and it is routinely the **largest row** —
    /// 1,194 of ~1,400 visitors for `InitialUTMSource` in the project this was
    /// measured against. It is not missing data: it is everyone who arrived
    /// without a campaign on the link, which is the number a marketer is
    /// comparing the campaigns *against*. Calling it "(not set)" would be true
    /// and useless; naming it is what makes the table readable.
    private var unsetLabel: String {
        switch group {
        case .campaign: "No campaign"
        default: "Not recorded"
        }
    }

    /// Turns one raw breakdown value into the text a row shows.
    ///
    /// Only the caller knows that `["US", "Newark"]` is a city and `-4.0` is an
    /// hour offset, which is why this lives here and not in the kit. Every
    /// non-string shape below was measured against project [REMOVED PRIVATE DATA] — see
    /// `WebStatsRow.rows(from:label:)` for the table.
    func label(for value: JSONValue) -> String {
        switch value {
        case .null:
            return unsetLabel

        case .string(let text):
            return text.isEmpty ? unsetLabel : text

        case .number(let number):
            // `Timezone` is the only dimension that breaks down by a number, and
            // the number is an offset in hours — including half-hour and
            // three-quarter-hour zones, so `5.5` is India and must not be
            // rounded to 5 or printed as "5.5". Rendered the way a clock app
            // writes it, with a real minus sign rather than a hyphen so it does
            // not read as a list separator.
            guard self == .timezone else { return number.formatted() }
            let sign = number < 0 ? "\u{2212}" : "+"
            let magnitude = abs(number)
            let hours = Int(magnitude)
            let minutes = Int((magnitude - Double(hours)) * 60 + 0.5)
            return minutes == 0
                ? "UTC\(sign)\(hours)"
                : String(format: "UTC%@%d:%02d", sign, hours, minutes)

        case .array(let parts):
            return arrayLabel(parts)

        default:
            return value.stringValue ?? unsetLabel
        }
    }

    /// The three dimensions that break down by a tuple.
    ///
    /// Measured shapes, in the API's own order:
    ///
    ///     Viewport   [1919.0, 992.0]              width, height
    ///     Region     ["US", "NJ", "New Jersey"]   country, code, name
    ///     City       ["US", "Newark"]             country, city
    ///
    /// Region and City are read most-specific-first because that is how a person
    /// says an address, and the country is kept on the end rather than dropped:
    /// "Newark" alone is three cities, and the row is a ranking where two of
    /// them could sit next to each other. `Region` deliberately skips its middle
    /// element — "New Jersey, NJ, US" says New Jersey twice.
    ///
    /// The country-only rows (`["US", null, null]`, `["US", null]`) are real and
    /// large — 877 of ~1,560 visitors for Region — and are geo-lookups that got
    /// as far as a country and no further. They keep the country and say what is
    /// missing, so they stay distinguishable from the resolved rows below them
    /// rather than collapsing onto the same label and colliding as list ids.
    private func arrayLabel(_ parts: [JSONValue]) -> String {
        if self == .viewport {
            let numbers = parts.compactMap { value -> Int? in
                guard case .number(let d) = value else { return nil }
                return Int(d)
            }
            guard numbers.count == 2 else { return WebStatsRow.plainLabel(.array(parts)) }
            // The multiplication sign, not the letter x: this is a size.
            return "\(numbers[0]) \u{00D7} \(numbers[1])"
        }

        let country = parts.first?.stringValue
        // Region sends the code and the name; the name is the last element in
        // both shapes, so taking the tail covers Region and City alike.
        let specific = parts.dropFirst().compactMap(\.stringValue).last

        switch (specific, country) {
        case (let specific?, let country?): return "\(specific), \(country)"
        case (let specific?, nil): return specific
        case (nil, let country?): return "\(country) — \(pluralTitle.dropLast()) unknown"
        case (nil, nil): return unsetLabel
        }
    }

    /// The thirteen accepted values this app deliberately does not offer, and
    /// the reason for each. All thirteen answer HTTP 200 — none of this is about
    /// what the API allows.
    ///
    /// - `FrustrationMetrics` returns different **columns** —
    ///   `[breakdown_value, rage_clicks, dead_clicks, errors, cross_sell]`
    ///   against every other dimension's `[…, visitors, views, …]`. A stats
    ///   table would print its rage clicks under "visitors". It deserves a
    ///   section of its own with its own columns, not a slot in this picker.
    /// - The eight `FirstPageview*` dimensions duplicate the `Initial*` ones.
    ///   Measured side by side over 90 days: `FirstPageviewChannelType` 741
    ///   visitors against `InitialChannelType` 740; `FirstPageviewReferringDomain`
    ///   769 against `InitialReferringDomain` 769. Offering both would nearly
    ///   double the menu to express a distinction the data does not show.
    /// - `InitialUTMSourceMediumCampaign` and its `FirstPageview` twin are the
    ///   three UTM fields glued together, and the glue shows: the top value
    ///   comes back as `"referrer:$direct / (none) / (none)"`. The three
    ///   dimensions this list already offers say the same thing legibly.
    /// - `ExitClick` is already on this screen. "Outbound clicks" is
    ///   `WebExternalClicksTableQuery`, a different query kind over the same
    ///   fact, so adding it here would offer the same numbers twice under two
    ///   names — and the two are computed differently enough that they need not
    ///   agree.
    /// - `PreviousPage` mixes kinds within one column: its top value is
    ///   `$direct`, a session start rather than a page, so the ranking is not a
    ///   ranking of pages.
    /// - `ScreenName` is the mobile-SDK `$screen` equivalent of `Page` and
    ///   returned zero rows here. It is not wrong, it is simply not web, and
    ///   this screen is called Web. The first mobile-heavy project to want it is
    ///   a better reason to add it than symmetry is.
    static let omitted = [
        "FrustrationMetrics", "ExitClick", "PreviousPage", "ScreenName",
        "InitialUTMSourceMediumCampaign", "FirstPageviewUTMSourceMediumCampaign",
        "FirstPageviewChannelType", "FirstPageviewReferringDomain",
        "FirstPageviewUTMSource", "FirstPageviewUTMCampaign",
        "FirstPageviewUTMMedium", "FirstPageviewUTMTerm", "FirstPageviewUTMContent",
    ]
}

@MainActor
@Observable
final class WebAnalyticsStore {
    var metrics: [WebOverviewMetric] = []
    var rows: [WebStatsRow] = []
    /// Whether PostHog had more rows than it returned. See `loadBreakdown`.
    var rowsAreTruncated = false
    /// The limit PostHog actually applied, which is not necessarily the one that
    /// was asked for — a query with no limit of its own is capped at 100 in
    /// silence, so the number to state is the server's, never the request's.
    var rowLimit: Int?
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
    var overviewError: LoadFailure?
    var rowsError: LoadFailure?
    var changesError: LoadFailure?
    var clicksError: LoadFailure?
    var vitalsError: LoadFailure?
    var marketingError: LoadFailure?
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
    var anyError: LoadFailure? {
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
            overviewError = Self.failure(for: error, loading: "overview")
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
            // The dimension labels its own rows: a viewport is "1919 × 992", a
            // city is "Newark, US", an absent UTM is "No campaign". Nothing else
            // knows that, and the kit deliberately does not.
            rows = WebStatsRow.rows(from: response, label: dimension.label(for:))
            // Recorded, because the table has always been a *top N* and never
            // said so. The captured `web_stats.json` is 50 rows with
            // `hasMore: true` and `limit: 50` beside them, so this has been true
            // since the screen shipped — it simply mattered less when the only
            // dimensions offered were five with few values. `City`, `Language`
            // and both page dimensions routinely have hundreds.
            rowsAreTruncated = response.isTruncated
            rowLimit = response.appliedLimit
            loadedAt = Date()
            rowsError = nil
        } catch {
            rowsError = Self.failure(for: error, loading: "breakdown")
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
            changesError = Self.failure(for: error, loading: "notable-changes")
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
            clicksError = Self.failure(for: error, loading: "outbound-clicks")
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
            vitalsError = Self.failure(for: error, loading: "vitals")
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
            marketingError = Self.failure(for: error, loading: "marketing")
        }
    }

    /// The bar scale is pinned to the whole result set, not the visible subset,
    /// so searching narrows the list without silently re-scaling every bar.
    var peakVisitors: Double { rows.map(\.visitors).max() ?? 0 }

    /// `subject` names the query that failed, so a decoding summary can say
    /// which response it means without the reader inferring it from whichever
    /// section went blank.
    private static func failure(for error: any Error, loading subject: String) -> LoadFailure {
        LoadFailure(error, loading: subject)
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
        content
            .navigationTitle("Web")
            .toolbar {
                ProjectSwitcher()
                ToolbarItem(placement: .topBarTrailing) {
                    WebAnalyticsExportMenu(store: store, dimension: dimension)
                }
            }
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
        } else if let failure = store.anyError, store.isEmpty {
            // Screen-level emptiness, so this one keeps the full treatment. The
            // detail sits under it rather than inside the message: a decoding
            // dump is what the compact states were built to stop putting there.
            LoadFailureState(title: "Couldn't load web analytics", failure: failure) {
                Task { await reloadAll() }
            }
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
    /// the stack, because `GlassFilterBar` insets itself and would otherwise sit
    /// on a doubled margin.
    ///
    /// The gap between sections is one step above the gap inside them, not two:
    /// at `xl` there was roughly 100pt of dead ground between the overview and
    /// "Where to look first" on iPhone, which cost more than the separation was
    /// worth. The small-caps section headers already do most of the dividing.
    private var report: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
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

    /// Twenty dimensions in five named groups.
    ///
    /// **Not the segmented control this used to be.** Five titles already had to
    /// be abbreviated to fit an iPhone; twenty cannot be shown at all, and a
    /// segmented control does not scroll — it shrinks its labels until they are
    /// slivers, which is the same failure the accessibility-size branch of
    /// `adaptivelyStyled` exists to avoid. So the menu is now unconditional and
    /// `adaptivelyStyled` is no longer used here.
    ///
    /// **Buttons in `Section`s, not a `Picker`**, and that is not a preference —
    /// it is what makes the group headings appear. The project switcher in
    /// `RootView` was built and photographed both ways: with a `Picker` inside
    /// it, the `Section`'s title is dropped and the heading vanishes entirely.
    /// Twenty flat entries with no headings is exactly the wall this grouping
    /// exists to break up, so the same arrangement that worked there — a `Menu`
    /// of `Button`s with a checkmark on the current one, which is what a `Picker`
    /// compiles to anyway — is what is written out here.
    ///
    /// The label carries the *current* dimension rather than the word
    /// "Breakdown": with twenty possibilities, which one you are looking at is
    /// no longer inferable from the rows.
    private var dimensionPicker: some View {
        Menu {
            ForEach(WebStatsDimension.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.members) { option in
                        let isCurrent = option == dimension
                        Button {
                            dimension = option
                        } label: {
                            if isCurrent {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Label(option.title, systemImage: option.glyph)
                            }
                        }
                        // A glyph inside a menu item is not announced, so the
                        // checkmark that is the only visual mark of the current
                        // row has to be said in words.
                        .accessibilityLabel(
                            isCurrent ? "\(option.title), currently shown" : option.title
                        )
                    }
                }
            }
        } label: {
            Label(dimension.title, systemImage: dimension.glyph)
                .font(.subheadline.weight(.medium))
                // Inside the label closure, not on the `Menu`. A borderless
                // menu's tap region is its *label's* bounds, so a frame applied
                // outside would silently just recentre the text and leave the
                // target the size it was. Kept even though the style below is
                // bordered — it is what makes the 44pt true by construction
                // rather than by whatever height the style happens to pick.
                .frame(minHeight: 44)
        }
        // Bordered, so it reads as something to press. The segmented control it
        // replaces was unmistakably a control; a bare label under a section
        // heading is not, and this is the only way to change what the table
        // below is showing.
        .buttonStyle(.bordered)
        // The groups are an order — content, then acquisition, then campaign,
        // then technology, then geography — and `.automatic` would let the menu
        // flip them when it opens upward.
        .menuOrder(.fixed)
        .accessibilityLabel("Breakdown dimension: \(dimension.title)")
        .accessibilityHint("Changes what the table below is broken down by")
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

            overviewFigures

            if let error = store.overviewError, !store.metrics.isEmpty {
                staleNote(
                    "These figures are from an earlier load. \(error.summary)",
                    detail: error.detail
                )
            }
        }
        .padding(.horizontal, Theme.Space.l)
    }

    /// Wraps to as many rows as the width needs, rather than running off the
    /// edge.
    ///
    /// Measured on iPhone at default text size: three captioned tiles do not fit
    /// 402pt, so the horizontal strip cut the third one's caption to
    /// "No prior p…" — and with the scroll indicators hidden, nothing said the
    /// remaining stats were there at all. Wrapping keeps every figure present
    /// and comparable; showing fewer in compact would hide the numbers the
    /// screen exists for. The widest arrangement that fits wins, so iPad keeps
    /// its single row of five, and accessibility sizes fall all the way to one
    /// tile per row instead of squeezing a metric until it truncates.
    private var overviewFigures: some View {
        ViewThatFits(in: .horizontal) {
            metricGrid(columns: store.metrics.count)
            metricGrid(columns: (store.metrics.count + 1) / 2)
            metricGrid(columns: 2)
            metricGrid(columns: 1)
        }
        .skeleton(store.isLoadingOverview && store.metrics.isEmpty)
    }

    private func metricGrid(columns: Int) -> some View {
        let width = max(columns, 1)
        let chunks = stride(from: 0, to: store.metrics.count, by: width).map { start in
            Array(store.metrics[start..<min(start + width, store.metrics.count)])
        }
        return Grid(
            alignment: .topLeading,
            horizontalSpacing: Theme.Space.xl,
            verticalSpacing: Theme.Space.l
        ) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                GridRow {
                    ForEach(chunk) { metric in
                        WebKPITile(metric: metric)
                    }
                }
            }
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Breakdown", systemImage: "list.number")

            dimensionPicker

            if filteredRows.isEmpty && !store.isLoadingRows {
                SectionEmptyState(
                    text: search.isEmpty
                        ? "PostHog returned no \(dimension.pluralTitle) for this period."
                        : "No \(dimension.pluralTitle) matched “\(search)”.",
                    systemImage: "magnifyingglass"
                )
            } else {
                breakdownTable
                truncationNote
            }

            if let error = store.rowsError, !store.rows.isEmpty {
                staleNote(
                    "This table is from an earlier load. \(error.summary)",
                    detail: error.detail
                )
            }
        }
    }

    /// Hand-rolled container rather than `Card`: the proportional bars need to
    /// reach the container's edges, which a card's inner padding would inset.
    ///
    /// Reaching the edge is also why the container has to *clip* rather than
    /// merely draw a rounded background. Each row's bar is a
    /// `RoundedRectangle(cornerRadius: 6)` painted from x = 0, and
    /// `.background(_:in:)` puts the card's shape behind it without constraining
    /// it — so the top row's bar, which is always full width because the scale
    /// is pinned to it, went on painting square into the container's 16pt
    /// corner. Rendered at 8× against the same table with the clip applied:
    /// 4.13pt of tint outside the corner over a 16.75pt run, at the top-leading
    /// and bottom-leading corners both. Same defect as `Card`'s spine, and the
    /// same fix — the decoration is clipped by the shape it lives in.
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
        .background(Theme.cardBackground)
        .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
        .skeleton(store.isLoadingRows && store.rows.isEmpty)
    }

    /// Says the table is a top N whenever PostHog said there were more.
    ///
    /// Not decoration. Ranked rows with nothing under them read as *the whole
    /// list*, and on this table that reading is wrong on almost every dimension
    /// — the recording that ships in the demo is 50 rows with `hasMore: true`
    /// beside them. Someone comparing "how many countries" against PostHog's own
    /// UI would have found the app quietly answering 50.
    ///
    /// Only ever states the limit **the server applied**, which is the one the
    /// envelope carries, not the one the request asked for. A query that sends no
    /// limit is capped at 100 in silence, so the two can differ.
    ///
    /// Suppressed while a search is active: the visible count is then the
    /// filter's doing, and "showing the top 50" next to three matched rows would
    /// describe something the reader is not looking at.
    @ViewBuilder
    private var truncationNote: some View {
        if store.rowsAreTruncated, search.isEmpty {
            Label(
                store.rowLimit.map { "Top \($0) \(dimension.pluralTitle) by visitors. PostHog has more." }
                    ?? "Ranked by visitors. PostHog has more \(dimension.pluralTitle) than are shown.",
                systemImage: "list.number"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var notableChangesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionHeader(
                "Where to look first",
                systemImage: "sparkles",
                subtitle: "PostHog's ranking of the dimensions that stand out, highest impact first."
            )

            if store.notableChanges.isEmpty && !store.isLoadingChanges {
                SectionEmptyState(
                    text: "PostHog flagged no standout dimensions in the \(window.spokenTitle.lowercased()).",
                    systemImage: "sparkles"
                )
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
                staleNote(
                    "This ranking is from an earlier load. \(error.summary)",
                    detail: error.detail
                )
            }
        }
    }

    private var outboundSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionHeader(
                "Outbound links",
                systemImage: "arrow.up.forward.square",
                subtitle: "External destinations visitors clicked through to."
            )

            if topExternalClicks.isEmpty && !store.isLoadingClicks {
                SectionEmptyState(
                    text: """
                        Nothing led off the site in the \(window.spokenTitle.lowercased()). \
                        PostHog only records these when external link tracking is switched on.
                        """,
                    systemImage: "arrow.up.forward.square"
                )
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
                staleNote(
                    "This list is from an earlier load. \(error.summary)",
                    detail: error.detail
                )
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

    /// Stale data still owes the reader the reason it is stale — and, when the
    /// reason was a decoding fault, the fault itself rather than a summary that
    /// quietly loses it.
    private func staleNote(_ text: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label(text, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail {
                FailureDetail(text: detail)
            }
        }
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
        // A floor rather than a fixed width: tiles stay comparable across the
        // row without clipping a long metric name. It is also what makes the
        // grid's fit test honest — without it a tile would claim to fit any
        // width and go back to truncating its own caption, which is the failure
        // this replaced.
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
