import Charts
import GetHogKit
import SwiftUI

// MARK: - Chrome

extension IngestionWarningWindow {
    /// What fits in a segment.
    ///
    /// The full titles read as prose in the empty state — "none in the last 48
    /// hours" — and three of them in a segmented control beside a filter menu
    /// leave each segment about two characters wide on an iPhone. Same values,
    /// two registers.
    var shortTitle: String {
        switch self {
        case .twoDays: "48h"
        case .sevenDays: "7d"
        case .thirtyDays: "30d"
        }
    }
}

extension IngestionWarningSeverity {
    /// Always paired with the severity's word — this is a pill with text in it,
    /// never a bare coloured dot. Chrome, so it comes from `Theme.Status`;
    /// `SeriesPalette` belongs to the sparkline beside it and nothing else.
    var tint: Color {
        switch self {
        case .error: Theme.Status.critical
        case .warning: Theme.accentWarm
        case .info: Theme.accent
        // An unrated severity gets no colour opinion, because PostHog gave
        // none. Tinting it would state a judgement the API never made. The
        // neutral is the app's own ink rather than `.secondary`: as a pill this
        // tints both the word and its capsule, and `.secondary` put that pair at
        // 3.2:1 where the app's ink puts it at 6.3:1.
        case .unknown: Theme.Ink.secondary
        }
    }

    /// A second, non-colour encoding, so an error is distinguishable from an
    /// info by shape before either pill has been read.
    var glyph: String {
        switch self {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class IngestionWarningsStore {
    private(set) var warnings: [IngestionWarning] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?

    /// Held on the store rather than in the view so a project switch or a
    /// pull-to-refresh reuses whatever the reader last chose.
    var window: IngestionWarningWindow = .sevenDays
    var category: IngestionWarningCategory?
    var search = ""

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            // The response is a bare array, not a `Page` — decoding it as one
            // throws, and a screen whose decode throws reports "couldn't load"
            // when the truth is "your ingestion is fine".
            let rows: [IngestionWarning] = try await client.send(
                PostHogAPI.ingestionWarnings(
                    projectID: projectID,
                    window: window,
                    category: category
                )
            )
            warnings = rows.sorted(by: IngestionWarning.mostUrgentFirst)
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Narrows what is already loaded.
    ///
    /// The API accepts a `q` parameter and this deliberately does not use it:
    /// the rate-limit budget is organisation-wide and shared with the reader's
    /// own integrations, so a request per keystroke is the fastest way to spend
    /// somebody else's production quota. The window and the category do go to
    /// the server, because each is one request on a deliberate tap.
    var visible: [IngestionWarning] {
        guard !search.isEmpty else { return warnings }
        return warnings.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.type.localizedCaseInsensitiveContains(search)
                || $0.category.title.localizedCaseInsensitiveContains(search)
        }
    }

    /// Drives the header. Counts the events, not the rows — one warning firing
    /// 40,000 times is the fact, and "5 warnings" hides it.
    ///
    /// Computed over what is on screen rather than over everything loaded: a
    /// header that kept the unfiltered total while the list beneath it shrank
    /// would attribute the whole project's volume to whatever was searched for.
    var visibleEvents: Int {
        visible.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Root

/// Ingestion warnings — "is my data arriving, and is it arriving intact".
///
/// The highest-value screen in this app to check away from a desk, for one
/// structural reason: the server pre-aggregates severity, volume, last-seen
/// *and* a per-row sparkline, so a whole answer costs a single request and no
/// client-side rollup. Nothing else here gives that much for that little.
///
/// Read-only, like the rest of the app. Warnings are resolved by changing what
/// the SDK sends, which is not a thing anybody does from a phone.
struct IngestionWarningsRoot: View {
    @Environment(AppModel.self) private var model
    /// Read because the rows change shape rather than shrinking at accessibility
    /// sizes; see `row(_:)`.
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var store = IngestionWarningsStore()

    var body: some View {
        @Bindable var store = store

        content
            .navigationTitle("Ingestion")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $store.search, prompt: "Search warnings")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.warnings.isEmpty {
            EmptyStateView(
                title: "Couldn't load ingestion warnings",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else {
            VStack(spacing: 0) {
                filterBar
                if store.visible.isEmpty && !store.isLoading {
                    emptyState
                        .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(Theme.pageBackground)
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        @Bindable var store = store

        return GlassFilterBar {
            Picker("Window", selection: $store.window) {
                ForEach(IngestionWarningWindow.allCases) { window in
                    Text(window.shortTitle)
                        .accessibilityLabel(window.title)
                        .tag(window)
                }
            }
            // Segmented below the accessibility sizes, a menu at and above them:
            // a segmented control divides its width by its segment count and
            // shrinks the labels to fit, so at AX5 this one was still drawn at
            // its default size while every neighbour on the screen had tripled.
            .adaptivePickerStyle()
            .onChange(of: store.window) { _, _ in Task { await load() } }
            // Takes the row's slack so the category menu sits at the trailing
            // edge, and the whole line once `GlassFilterBar` stacks.
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Picker("Category", selection: categoryBinding) {
                    Text("All categories").tag(String?.none)
                    ForEach(IngestionWarningCategory.filterable, id: \.apiValue) { category in
                        Text(category.title).tag(String?.some(category.apiValue))
                    }
                }
            } label: {
                Label(
                    store.category?.title ?? "All",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.subheadline)
                .lineLimit(1)
                // Measured 41×17pt — a subheadline glyph and one short word,
                // with nothing behind them. A borderless menu is exactly as
                // tappable as its label is big, so the floor is set here rather
                // than on the `Menu`, which would only recentre this label in a
                // larger box.
                .minimumHitTarget()
            }
            .accessibilityLabel("Category filter, \(store.category?.title ?? "all categories")")
        }
        .padding(.bottom, Theme.Space.s)
    }

    /// Bound through the API string rather than the enum: `IngestionWarningCategory`
    /// carries an associated value, so it is not `RawRepresentable` and a
    /// `Picker` tag cannot round-trip it directly.
    private var categoryBinding: Binding<String?> {
        Binding(
            get: { store.category?.apiValue },
            set: { raw in
                store.category = raw.map { value in
                    IngestionWarningCategory.filterable.first { $0.apiValue == value }
                        ?? .unknown(value)
                }
                Task { await load() }
            }
        )
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                ForEach(store.visible) { warning in
                    row(warning)
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(text: summaryLine, systemImage: "arrow.down.circle")
            }

            if let loadedAt = store.loadedAt {
                FreshnessLabel(date: loadedAt)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.warnings.isEmpty)
    }

    private var summaryLine: String {
        let events = Double(store.visibleEvents).compactFormatted
        let rows = store.visible.count
        return "\(rows) warning\(rows == 1 ? "" : "s") · \(events) events"
    }

    /// The row, in the shape the current type size can carry.
    ///
    /// This row was written before `DataRow` learned to reflow and never got the
    /// same treatment. Measured at AX5 on iPhone: the count and the fixed-width
    /// sparkline held about 40% of the row whatever the type size, so the title
    /// was squeezed to `Cannot merge…` and the strip left over broke the category
    /// to `Merg` / `es`. Everything the row is for was in the part that went.
    private func row(_ warning: IngestionWarning) -> some View {
        rowLayout(warning)
            // Nothing here is prose — titles are PostHog's own warning strings,
            // categories are product nouns — so the hyphenation dictionary has no
            // business splitting them. `zxx` is the ISO code for "no linguistic
            // content", which is the same fix `DataRow` uses.
            .typesettingLanguage(Locale.Language(identifier: "zxx"))
            .padding(.vertical, Theme.Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spoken(warning))
    }

    @ViewBuilder
    private func rowLayout(_ warning: IngestionWarning) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    RowGlyph(systemName: warning.severity.glyph, tint: warning.severity.tint)
                    title(warning)
                }
                severityLine(warning)
                footnoteText(warning)
                // Kept, and kept together: the count is the fact the screen is
                // read for and the sparkline is its shape over time. On its own
                // line neither has to be paid for out of the title's width.
                HStack(spacing: Theme.Space.s) {
                    count(warning)
                    Spacer(minLength: Theme.Space.s)
                    Sparkline(warning: warning, window: store.window)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                RowGlyph(systemName: warning.severity.glyph, tint: warning.severity.tint)

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    title(warning)
                    severityLine(warning)
                    footnoteText(warning)
                }

                Spacer(minLength: Theme.Space.s)

                VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                    count(warning)
                    Sparkline(warning: warning, window: store.window)
                }
            }
        }
    }

    private func title(_ warning: IngestionWarning) -> some View {
        Text(warning.title)
            .font(Theme.Typography.title)
            // Uncapped at accessibility sizes, as `DataRow` is: two lines of type
            // that large is a few words, and the cap exists to keep rows an even
            // height, which is a scanning concern that no longer applies there.
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
    }

    private func severityLine(_ warning: IngestionWarning) -> some View {
        HStack(spacing: Theme.Space.s) {
            StatusPill(text: warning.severity.title, tint: warning.severity.tint)
            Text(warning.category.title)
                .font(Theme.Typography.caption)
                // `.secondary` measured 3.44:1 against this white row background,
                // under the 4.5:1 AA floor for text this size.
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private func footnoteText(_ warning: IngestionWarning) -> some View {
        Text(footnote(warning))
            .font(Theme.Typography.caption)
            // Measured 1.84:1 light and 2.27:1 dark on `.tertiary`; this line
            // carries the only date on the row.
            .foregroundStyle(Theme.Ink.tertiary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }

    private func count(_ warning: IngestionWarning) -> some View {
        Text(Double(warning.count).compactFormatted)
            .font(Theme.Typography.body.weight(.semibold).monospacedDigit())
    }

    private func footnote(_ warning: IngestionWarning) -> String {
        var parts: [String] = []
        if let lastSeen = warning.lastSeen {
            // "Last seen", not "Last": the relative formatter yields "8 hours
            // ago", and without the verb the row read "Last 8 hours ago", which
            // is a different claim — a window rather than a most-recent sighting.
            parts.append("Last seen \(lastSeen.formatted(.relative(presentation: .named)))")
        } else {
            // Absence stated rather than left blank: PostHog aggregated this
            // warning without timestamping it, which is a different fact from
            // "it has never fired".
            parts.append("No last-seen recorded")
        }
        if warning.sampleCount > 0 {
            parts.append("\(warning.sampleCount) sample\(warning.sampleCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private func spoken(_ warning: IngestionWarning) -> String {
        var text = "\(warning.title), \(warning.severity.title), \(warning.category.title). "
        text += "\(warning.count.formatted()) events"
        if let lastSeen = warning.lastSeen {
            text += ", last seen \(lastSeen.formatted(.relative(presentation: .named)))"
        }
        text += trend(warning)
        return text
    }

    /// The sparkline said, rather than promised.
    ///
    /// This line used to end ", daily trend available", which advertised a chart
    /// nothing could reach. The `Sparkline` beside it is `.accessibilityHidden`;
    /// the row is a single `.combine`d element, so a descriptor attached inside
    /// it would be flattened away along with everything else; and the row is not
    /// tappable, so there is no detail screen to open the chart in either.
    ///
    /// Giving it a descriptor instead was the other option and is the worse one,
    /// because the axis would have to be invented: the payload carries bucket
    /// *values* and no timestamps at all — see `IngestionWarning.sparkline` —
    /// so a descriptor's x-axis could only count "bucket 0 to 11", which is
    /// exactly the unlabelled-and-unknowable axis `IngestionWarningWindow`
    /// already calls decoration. The two facts the shape genuinely carries fit
    /// in the sentence the row is read as anyway.
    private func trend(_ warning: IngestionWarning) -> String {
        guard warning.hasTrend else { return ", no activity in this window" }

        let buckets = warning.sparkline
        let unit = store.window.bucket == .hourly ? "hour" : "day"
        let peak = (buckets.max() ?? 0).formatted(.number.precision(.fractionLength(0)))
        let worst = "worst \(unit) \(peak)"

        // Halves, not first-versus-last: one quiet bucket at either end is
        // ordinary and would otherwise flip the verb on its own. Under four
        // buckets there are no halves worth comparing, so nothing is claimed.
        guard buckets.count >= 4 else { return ", \(worst)" }

        let split = buckets.count / 2
        let earlier = buckets.prefix(split).reduce(0, +)
        let later = buckets.suffix(from: split).reduce(0, +)
        // A fifth either way, so ordinary bucket-to-bucket jitter does not get
        // announced as a direction.
        let direction = if later > earlier * 1.2 {
            "rising"
        } else if later * 1.2 < earlier {
            "falling"
        } else {
            "steady"
        }

        return ", \(store.window.bucket.title) trend \(direction), \(worst)"
    }

    // MARK: Empty

    /// The state this project actually shows, so it is written to be worth
    /// reading rather than to fill a hole.
    @ViewBuilder
    private var emptyState: some View {
        if !store.search.isEmpty {
            EmptyStateView(
                title: "No matching warnings",
                systemImage: "magnifyingglass",
                message: "Nothing in the last \(store.window.title) matches “\(store.search)”."
            )
        } else if store.category != nil {
            EmptyStateView(
                title: "Nothing in this category",
                systemImage: "line.3.horizontal.decrease.circle",
                message: "PostHog recorded no \(store.category?.title.lowercased() ?? "") "
                    + "warnings in the last \(store.window.title). "
                    + "Other categories may still have some.",
                actionTitle: "Show all categories",
                action: {
                    store.category = nil
                    Task { await load() }
                }
            )
        } else {
            EmptyStateView(
                title: "Ingestion looks clean",
                systemImage: "checkmark.seal",
                illustration: .allClear,
                message: "PostHog flags events it had to alter or drop on the way in — "
                    + "payloads too large to store, timestamps in the future, "
                    + "and identify calls that could not merge two people. "
                    + "None were recorded in the last \(store.window.title). "
                    + "Anything found appears here worst-first, with a "
                    + "\(store.window.bucket.title) trend and how often it fired."
            )
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Sparkline

/// The server's own pre-aggregated buckets, drawn.
///
/// This is the one place on the screen that `SeriesPalette` is allowed: the
/// sparkline *is* data, not chrome. Slot 0 on every row deliberately — each row
/// plots the same series (this warning's volume over time), so colour follows
/// the series' fixed slot rather than the row's rank, and filtering the list
/// never repaints anything.
private struct Sparkline: View {
    let warning: IngestionWarning
    let window: IngestionWarningWindow

    var body: some View {
        if warning.hasTrend {
            Chart(Array(warning.sparkline.enumerated()), id: \.offset) { bucket, value in
                AreaMark(x: .value("Bucket", bucket), y: .value("Events", value))
                    .foregroundStyle(SeriesPalette.color(at: 0).opacity(0.25))
                LineMark(x: .value("Bucket", bucket), y: .value("Events", value))
                    .foregroundStyle(SeriesPalette.color(at: 0))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            // Fixed rather than proportional: this is a shape cue beside a
            // number, and a chart that grew with Dynamic Type would push the
            // count it annotates off the row.
            .frame(width: 68, height: 22)
            .accessibilityHidden(true)
        } else {
            // A flat line at zero is indistinguishable from a chart that failed
            // to draw, so the absence is said in words instead.
            Text(warning.sparkline.isEmpty ? "No trend" : "Quiet")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
                .frame(width: 68, alignment: .trailing)
        }
    }
}
