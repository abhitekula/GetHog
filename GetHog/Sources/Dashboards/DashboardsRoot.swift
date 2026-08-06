import GetHogKit
import SwiftUI

@MainActor
@Observable
final class DashboardsStore {
    var dashboards: [DashboardSummary] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<DashboardSummary> = try await client.send(
                PostHogAPI.dashboards(projectID: projectID)
            )
            dashboards = page.results.filter { !$0.title.isEmpty }
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    var pinned: [DashboardSummary] { dashboards.filter(\.pinned) }
    var others: [DashboardSummary] { dashboards.filter { !$0.pinned } }
}

struct DashboardsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(OpenDetails.self) private var openDetails
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var store = DashboardsStore()
    @State private var search = ""

    /// The open dashboard's id, and deliberately **not** `@State`.
    ///
    /// See `FlagsRoot.selectedID` for the measurement. Since the tab bar became
    /// a preference this screen can be demoted, a demoted screen is pushed onto
    /// the search tab's stack, and a `NavigationSplitView` nested in a
    /// `NavigationStack` has nowhere to put its detail - so the row opened
    /// nothing at all.
    private var selectedID: Binding<Int?> {
        Binding(
            get: { openDetails[.dashboards] as? Int },
            set: { openDetails[.dashboards] = $0.map(AnyHashable.init) }
        )
    }

    private var selection: DashboardSummary? {
        selectedID.wrappedValue.flatMap { id in store.dashboards.first { $0.id == id } }
    }
    // `.all`, not `.automatic`: explicit visibility preserves the list column
    // when the split view's own toggle is removed below.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if sizeClass == .compact {
                // No split view in compact, and that is the fix: this screen is
                // hosted either by its own tab or - since the bar became a
                // preference - by a push on the search tab's stack, and a split
                // view nested in that stack could open nothing at all.
                listChrome
                    .navigationDestination(item: selectedID) { id in
                        if let summary = store.dashboards.first(where: { $0.id == id }) {
                            DashboardDetailView(summary: summary).id(id)
                        }
                    }
            } else {
                regularSplit
            }
        }
        // Teaches Siri which dashboard this person actually opens.
        //
        // Here rather than in `DashboardDetailView`: the detail screen is also
        // drawn by a restored window, by a deep link, and by
        // `applyDebugSelectionIfNeeded` under the UI tests, none of which is
        // somebody choosing a dashboard.
        .onChange(of: selection) { _, opened in
            guard let opened else { return }
            IntentDonations.dashboardOpened(opened)
        }
    }

    /// Regular width keeps the two-column arrangement, and everything the
    /// columns need to negotiate with each other.
    private var regularSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Bare on purpose: `listChrome` already carries the full modifier
            // stack. This site used to re-apply all of it inline — which drew
            // the project-switcher glyph twice in the sidebar header and, far
            // worse, mounted a second `.task(id: model.projectID)`, fetching
            // the dashboard list twice on appear and twice per project switch
            // against a shared rate limit.
            listChrome
        } detail: {
            if let selection {
                // `.id` rebuilds the screen per dashboard, which also clears the
                // previously selected tile rather than leaving one dashboard's
                // insight open beside another dashboard's grid.
                DashboardDetailView(summary: selection)
                    .id(selection.id)
            } else if store.dashboards.isEmpty {
                EmptyStateView(
                    title: "No dashboards",
                    systemImage: "square.grid.2x2",
                    illustration: .dashboard,
                    message: "This project doesn't have any dashboards yet."
                )
            } else {
                // The detail pane is the largest surface in the app. Handing it
                // a "Select a dashboard" placeholder wasted it on every launch.
                ProjectOverview(dashboards: store.dashboards)
            }
        }
        // The insight panel temporarily yields the list column, then restores it
        // explicitly when the panel closes.
        .onPreferenceChange(InsightPanelOpenKey.self) { isOpen in
            withAnimation(.snappy(duration: 0.25)) {
                columnVisibility = isOpen ? .detailOnly : .all
            }
        }
    }

    /// The list and everything attached to it, shared by both widths.
    /// The one copy of this chrome — `regularSplit` must not re-apply any of
    /// it, or the switcher glyph doubles and the list fetches twice.
    private var listChrome: some View {
        content
            // Left to its own devices the sidebar took 340pt of an 834pt
            // iPad, leaving the grid too narrow for two columns. The list
            // is titles and one line of description; it does not need more
            // than this, and the charts do.
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            // The tab sidebar already puts a toggle in this bar; the split
            // view added a second, identical one beside it.
            //
            // Removing it is only safe because the column is pinned `.all`
            // rather than left to resolve. The earlier reasoning here — that
            // `InsightPanelOpenKey` drives the column, so the button was
            // redundant — was the bug: the preference only ever *closes* the
            // column, and the reopening path it assumed existed was
            // `.automatic`, which in iPad portrait resolves to detail-only.
            .toolbar(removing: .sidebarToggle)
            .navigationTitle("Dashboards")
            .toolbar { ProjectSwitcher() }
#if os(macOS)
            // The customizable half of this bar — what "Customize Toolbar…"
            // rearranges. The switcher above stays in the fixed toolbar
            // deliberately: `ProjectSwitcher` is plain `ToolbarContent` and
            // cannot sit in a `.toolbar(id:)`, and project context is not
            // optional chrome anyway. Fixed and customizable items coexist.
            //
            // Refresh earns a visible control here because pull-to-refresh does
            // not exist on the Mac — this and ⌘R are the same closure wearing
            // two coats.
            .toolbar(id: "dashboards") {
                ToolbarItem(id: "refresh", placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh dashboards")
                }
            }
#endif
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search dashboards")
            .screenRefreshable { await load() }
            .task(id: model.projectID) {
                await load()
                applyDebugSelectionIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.dashboards.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load dashboards", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.dashboards.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No dashboards",
                systemImage: "square.grid.2x2",
                illustration: .dashboard,
                message: "This project doesn't have any dashboards yet."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: selectedID) {
            if !filtered(store.pinned).isEmpty {
                Section {
                    ForEach(filtered(store.pinned), id: \.self) { row($0) }
                } header: {
                    SectionLabel(text: "Pinned", productMark: .dashboard)
                }
            }
            Section {
                ForEach(filtered(store.others), id: \.self) { row($0) }
            } header: {
                if !filtered(store.pinned).isEmpty {
                    SectionLabel(text: "All dashboards", productMark: .dashboard)
                }
            }
            if let loadedAt = store.loadedAt {
                FreshnessLabel(date: loadedAt)
                    .listRowBackground(Color.clear)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.dashboards.isEmpty)
        // Same shape as the flags list. Without it, a query matching nothing
        // emptied both sections and left the freshness label floating over
        // ~1,600pt of bare page — a blank screen after typing reads as a
        // crash, on the landing tab.
        .overlay {
            if !search.isEmpty,
               filtered(store.pinned).isEmpty,
               filtered(store.others).isEmpty {
                EmptyStateView(
                    title: "No matching dashboards",
                    systemImage: "magnifyingglass",
                    message: "No dashboard title matched “\(search)”."
                )
            }
        }
    }

    private func row(_ dashboard: DashboardSummary) -> some View {
        NavigationLink(value: dashboard.id) {
            DataRow(
                glyph: dashboard.creationMode == .template ? "wand.and.stars" : "square.grid.2x2",
                brandGlyph: DashboardBrandAppearance.glyph(for: dashboard.creationMode),
                // Generated dashboards are tinted with the warm secondary
                // rather than the app accent: they are real, but half this
                // project's list is feature-flag exhaust and it should not
                // compete with the dashboards somebody actually made.
                tint: dashboard.creationMode == .template ? Theme.accentWarm : Theme.accent,
                title: dashboard.title,
                subtitle: dashboard.description,
                // Absent for any dashboard nobody has opened, which is most of
                // them. `DataRow` drops the line entirely rather than printing
                // a placeholder date the API never gave us.
                footnote: dashboard.lastRefresh.map {
                    "Updated \($0.formatted(.relative(presentation: .named)))"
                },
                accessory: .none
            )
        }
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
        .contextMenu {
            // The detail's own toolbar has offered this since the tear-off
            // landed; the row it was opened from did not, which put the one
            // affordance a Mac user reaches for behind a navigation step.
            // iOS keeps the menu it had — iPad parity is a separate question
            // about where a torn-off window belongs on a touch device.
            #if os(macOS)
            Button {
                openWindow(value: WindowTarget.dashboard(id: dashboard.id))
            } label: {
                Label("Open in new window", systemImage: "macwindow.badge.plus")
            }
            #endif
            if let url = model.webURL(path: "dashboard/\(dashboard.id)") {
                Link(destination: url) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("Copy link", systemImage: "link")
                }
            }
        }
    }

    private func filtered(_ items: [DashboardSummary]) -> [DashboardSummary] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }

    private func applyDebugSelectionIfNeeded() {
        #if DEBUG
        switch DebugLaunch.dashboard {
        case .first:
            selectedID.wrappedValue = (store.pinned.first ?? store.dashboards.first)?.id
        case .id(let id):
            selectedID.wrappedValue = store.dashboards.first { $0.id == id }?.id
        case nil:
            break
        }
        #endif
    }
}
