import GetHogKit
import GetHogUI
import SwiftUI
import TipKit

/// How a flag is filed in the list. Archived wins over on/off, because an
/// archived flag isn't something you reason about as "currently live".
enum FlagStatusGroup: String, CaseIterable, Identifiable, Hashable {
    case enabled, disabled, archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .archived: "Archived"
        }
    }

    /// Text first: the pill is the accessible carrier of status, the tint is
    /// only reinforcement.
    var tint: Color {
        switch self {
        case .enabled: Theme.Status.good
        case .disabled, .archived: Color.secondary
        }
    }

    /// Section header symbol. Deliberately about *state* — the row glyphs below
    /// it are about the kind of flag, so the two don't say the same thing twice.
    var symbol: String {
        switch self {
        case .enabled: "flag.fill"
        case .disabled: "flag.slash"
        case .archived: "archivebox"
        }
    }
}

@MainActor
@Observable
final class FlagsStore {
    var flags: [FeatureFlag] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// Writes and their optimistic state live here so the list and the detail
    /// view agree instantly without either owning the other.
    let toggles = FlagToggleController()

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<FeatureFlag> = try await client.send(
                PostHogAPI.featureFlags(projectID: projectID)
            )
            flags = page.results
                .filter { !$0.deleted }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            toggles.reconcile(with: flags)
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    func group(for flag: FeatureFlag) -> FlagStatusGroup {
        if flag.archived { return .archived }
        return toggles.effectiveActive(flag) ? .enabled : .disabled
    }

    func flags(in group: FlagStatusGroup, search: String) -> [FeatureFlag] {
        flags.filter { self.group(for: $0) == group && matches($0, search: search) }
    }

    func matchCount(search: String) -> Int {
        flags.filter { matches($0, search: search) }.count
    }

    private func matches(_ flag: FeatureFlag, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        return flag.key.localizedCaseInsensitiveContains(search)
            || (flag.name ?? "").localizedCaseInsensitiveContains(search)
    }
}

struct FlagsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = FlagsStore()
    @State private var search = ""

    /// The open flag, and deliberately **not** `@State`.
    ///
    /// This screen used to be one of the four loose tabs, hosted once at both
    /// widths, and `@State` inside an always-`NavigationSplitView` body was
    /// correct for exactly that reason. Since the bar became a preference it can
    /// be **demoted**, and a demoted screen is reached by a push on the search
    /// tab's stack - where a `NavigationSplitView` is nested inside a
    /// `NavigationStack` and its selection-driven detail has nowhere to go, so
    /// the row opened nothing at all.
    ///
    /// The fix is the arrangement the seven secondary split views already use:
    /// carry the selection in `OpenDetails`, push it with
    /// `navigationDestination(item:)` in compact, and keep the split view for
    /// regular width only. The **id** is carried rather than the row, so the
    /// selection survives a reload that replaces the decoded value.
    private var selectedID: Binding<Int?> {
        Binding(
            get: { openDetails[.flags] as? Int },
            set: { openDetails[.flags] = $0.map(AnyHashable.init) }
        )
    }

    private var selection: FeatureFlag? {
        selectedID.wrappedValue.flatMap { id in store.flags.first { $0.id == id } }
    }

    var body: some View {
        if sizeClass == .compact {
            // No `NavigationSplitView` here, and that is the whole fix: in
            // compact width this screen is hosted either by its own tab or by a
            // push on the search stack, and only the second of those was broken.
            listChrome
                .navigationDestination(item: selectedID) { id in
                    if let flag = store.flags.first(where: { $0.id == id }) {
                        FlagDetailView(flag: flag, controller: store.toggles).id(id)
                    }
                }
        } else {
            NavigationSplitView {
                listChrome
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 400)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                detailPane
            }
        }
    }

    /// The list and everything attached to it, shared by both widths so the two
    /// arrangements cannot drift in what they load or how they search.
    private var listChrome: some View {
        content
                .navigationTitle("Flags")
                .toolbar { ProjectSwitcher() }
                .projectSubtitle()
                // Absent on tvOS for the reason `DashboardsRoot` records in
                // full: the field takes initial focus there and raises the
                // full-screen grid keyboard over the list it filters.
                #if !os(tvOS)
                .searchable(text: $search, prompt: "Search flag key or name")
                #endif
                .screenRefreshable { await load() }
                .task(id: model.projectID) {
                    AppTips.refresh(from: model)
                    await load()
                }
                // Narrower than the error and session lists on purpose: the
                // widest thing in a flag row is the key on the monospaced line,
                // around 30 characters, and the footnote is a short
                // "50% rollout · 3 variants". It does not need what a stack
                // trace message needs, and the release conditions in the detail
                // pane do.
    }

    /// The detail column: the chosen flag, or a summary of the product when
    /// nothing is chosen yet.
    ///
    /// The no-selection branch mirrors the list's own states rather than summarising thin air: a locked
    /// key and a project with no flags are both normal outcomes, and a grid of
    /// zeroes would misreport either one.
    @ViewBuilder
    private var detailPane: some View {
        if let selection {
            FlagDetailView(flag: selection, controller: store.toggles)
                .id(selection.id)
        } else if !model.isAvailable(.flags) {
            LockedCapabilityView(capability: .flags, scope: model.lockedScope(for: .flags)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.flags.isEmpty {
            EmptyStateView(
                title: "Couldn't load flags",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await load() }
            }
        } else if store.flags.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.large)
            } else {
                EmptyStateView(
                    title: "No feature flags",
                    systemImage: "flag",
                    illustration: .experiment,
                    message: "This project doesn't have any feature flags yet."
                )
            }
        } else {
            FlagsOverview(store: store, selection: selectedID)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.flags) {
            LockedCapabilityView(capability: .flags, scope: model.lockedScope(for: .flags)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.flags.isEmpty {
            EmptyStateView(
                title: "Couldn't load flags",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await load() }
            }
        } else if store.flags.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No feature flags",
                systemImage: "flag",
                illustration: .experiment,
                message: "This project doesn't have any feature flags yet."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: selectedID) {
            // Withheld at accessibility sizes. Measured at AX5: the card grew
            // past the full viewport — title, four-line body and dismiss button
            // — and not one flag row was visible under it, so opening the tab
            // meant scrolling through a screen of promotional copy to reach the
            // list. A tip that hides the thing it is about has stopped being a
            // tip, and the widget it advertises is not the reason anyone came
            // here. TipKit keeps its own display state, so a user who has never
            // seen it still gets it at a text size where it fits.
            if !dynamicTypeSize.isAccessibilitySize {
                // `AppTipView`, not `TipView`. The surface used to be corrected
                // here with `.tipBackground(Theme.cardBackground)` — TipKit's own
                // is `secondarySystemGroupedBackground`, sampled `#F2F2F7`, the
                // stock cool grey-blue on a cream ground. That fixed the fill and
                // could not reach the ink: TipKit's message measured **4.00:1**
                // in light on this very card, and its close glyph **2.66:1**.
                // Both live inside the framework's own body, so the fix is a
                // `TipViewStyle` — see `AppTipView`, which also draws the card,
                // so nothing is set here.
                AppTipView(FlagWidgetTip())
                    .listRowBackground(Color.clear)
            }
            ForEach(FlagStatusGroup.allCases) { group in
                let items = store.flags(in: group, search: search)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { flag in
                            NavigationLink(value: flag.id) {
                                FlagRowView(flag: flag, group: group)
                            }
                            .listRowBackground(
                                Theme.cardBackground
                                    .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                    .padding(.vertical, 1)
                            )
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionLabel(text: group.title, productMark: .flag)
                    }
                }
            }
            if let loadedAt = store.loadedAt {
                FreshnessLabel(date: loadedAt)
                    .listRowBackground(Color.clear)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.flags.isEmpty)
        .overlay {
            if !search.isEmpty && store.matchCount(search: search) == 0 {
                EmptyStateView(
                    title: "No matching flags",
                    systemImage: "magnifyingglass",
                    message: "No flag key or name matched “\(search)”."
                )
            }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

/// One flag in the list.
///
/// Read-only by design: there is no swipe action and no inline switch, because a
/// list is exactly the place where a production flag gets flipped by accident.
struct FlagRowView: View {
    let flag: FeatureFlag
    let group: FlagStatusGroup

    var body: some View {
        DataRow(
            glyph: glyph,
            brandGlyph: FlagBrandAppearance.glyph(
                isMultivariate: flag.isMultivariate,
                isArchived: group == .archived
            ),
            tint: tint,
            title: name ?? flag.key,
            // The key is what developers copy verbatim, so it takes the
            // monospaced line — except where it is already carrying the title,
            // because printing it twice buys nothing.
            subtitle: name == nil ? nil : flag.key,
            footnote: facts.isEmpty ? nil : facts.joined(separator: " · "),
            isSubtitleMonospaced: true,
            accessory: .pill(group.title, group.tint)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The glyph carries the *kind* of flag, leaving the pill to carry its
    /// state. A multivariate flag takes the warm secondary the way generated
    /// dashboards do: it is a different thing to reason about than a switch.
    private var glyph: String {
        if group == .archived { return "archivebox" }
        return flag.isMultivariate ? "arrow.triangle.branch" : "flag.fill"
    }

    private var tint: Color {
        if group == .archived { return .secondary }
        return flag.isMultivariate ? Theme.accentWarm : Theme.accent
    }

    /// Only present when it adds something: `displayName` falls back to the key.
    ///
    /// The whole name, not a shortened copy, because this string is also the
    /// spoken one. `DataRow` caps the title at two lines and that cap never
    /// reaches VoiceOver: SwiftUI truncates while rendering, long after the
    /// label has been handed over. The 80-character cap this used to inherit
    /// from `FeatureFlag.displayName` was the mirror image — it happened in the
    /// model, so it *did* reach the label, and a fictional
    /// `example-observatory-label` row spoke "…coordinate the sample telescope
    /// calibration across every portable display…, 0% rollout", a sentence cut
    /// mid-word and read out loud. Shortening for
    /// layout is only safe where layout happens.
    private var name: String? {
        let displayName = flag.displayName
        return displayName == flag.key ? nil : displayName
    }

    private var facts: [String] {
        var parts: [String] = []
        if let rollout = flag.rolloutPercentage {
            parts.append("\(FlagFormat.percent(rollout)) rollout")
        }
        if flag.isMultivariate {
            parts.append("\(flag.variants.count) variants")
        }
        return parts
    }

    private var accessibilityDescription: String {
        ([flag.key, group.title] + (name.map { [$0] } ?? []) + facts)
            .joined(separator: ", ")
    }
}

enum FlagFormat {
    /// Rollouts arrive as 0…100, not 0…1.
    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }
}
