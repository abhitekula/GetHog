import AppKit
import GetHogKit
import GetHogUI
import SwiftUI

/// A native Mac source-list shell over the shared product screens. Only the
/// selected destination is mounted, so hidden screens cannot retain toolbar,
/// title, or search ownership. The detail column injects a size class derived
/// from its real width, letting the shared roots choose their compact drill-in
/// or regular split topology without a device-width fiction.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// The app shell's entitled cache boundary. Required rather than defaulted
    /// so a teamless Mac Debug build cannot accidentally resolve the App Group
    /// singleton while draining a widget or menu-bar navigation request.
    let snapshotStore: SharedSnapshotStore

    @SceneStorage("selectedTab") private var selectedTab: AppTab = .dashboards
    /// The search tab's stack — heterogeneous for the reason RootView's is:
    /// screen results push `AppTab`, links push `PostHogLink`.
    @State private var searchPath = NavigationPath()
    @State private var openDetails = OpenDetails()
    /// One object above list and detail, as on iOS — see RootView for the
    /// disagreement this prevents.
    @State private var surveyLifecycle = SurveyLifecycleController()
    @State private var experimentLifecycle = ExperimentLifecycleController()
    @AppStorage(MacSidebarExpansion.storageKey)
    private var persistedSidebarExpansion = MacSidebarExpansion.defaultPersistedValue
    /// Per window, and restored with that window. The same value draws the
    /// column and names the View command; AppKit never has a second inferred
    /// sidebar state to drift away from the visible shell.
    @SceneStorage("macSidebarPresentation")
    private var sidebarPresentationRawValue = MacSidebarPresentation.visible.rawValue
    @SceneStorage("macSidebarWidth")
    private var preferredSidebarWidth = Double(MacSidebarShellLayout.defaultWidth)
    /// Tab-keyed but scene-owned: switching destinations remounts roots, while
    /// each window restores only the divider choices made inside that window.
    @SceneStorage("macRegularSplitWidths")
    private var persistedRegularSplitWidths = ""
    @State private var sidebarRevealGeneration = 0
    @State private var sidebarHasRevealableWidth = false
    /// Set only when a link could not do what it said. Success is silent.
    @State private var linkNotice: LinkNotice?
    @State private var hasAppliedDebugTab = false

    /// The sidebar's shape, named statically so shell tests can pin it without
    /// mounting a view: Search loose at the top, then every section, Settings
    /// nowhere.
    static let looseTabs: [AppTab] = [.search]
    static let sections: [AppTabSection] = AppTab.sections

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: Theme.Space.m) {
                    BrandConnectingAccent()
                    ProgressView("Connecting…")
                        .controlSize(.large)
                }

            case .onboarding:
                OnboardingView()

            case .ready:
                tabs
            }
        }
        .onChange(of: model.flagWriteScope) { _, _ in
            // The pool belongs to one authenticated project epoch, not merely
            // one numeric project id. This observer sits above the phase switch
            // so sign-out cannot remove it before it invalidates the details.
            openDetails.reset()
        }
    }

    private var tabs: some View {
        // A layout split, not another navigation container. The old outer
        // NavigationSplitView exported its source-list width as the detail's
        // leading safe area; each of the six roots then consumed that width a
        // second time in its own split. This shell supplies physical sibling
        // proposals instead: the detail proxy is exactly the width after the
        // source list, with a zero inherited leading inset and no route
        // correction.
        //
        // HSplitView was also rejected here. Collapsing its first child to a
        // zero frame leaves NSSplitView's divider as structural width and a
        // visible hairline. This SwiftUI shell keeps both children in one
        // stable HStack, collapses both source list and separator to exactly
        // zero, and keeps the selected detail root mounted while hidden.
        GeometryReader { shellProxy in
            let adaptiveSizeClass = MacWindowLayout.sizeClass(
                forContentWidth: MacSidebarShellLayout.adaptiveDetailWidth(
                    forShellWidth: shellProxy.size.width,
                    preferredSidebarWidth: CGFloat(preferredSidebarWidth)
                )
            )

            MacSidebarShell(
                presentation: sidebarPresentation,
                preferredSidebarWidth: $preferredSidebarWidth
            ) {
                sidebar
                    .onGeometryChange(for: Bool.self) {
                        MacSidebarShellLayout.isRevealable(
                            sourceListWidth: $0.size.width
                        )
                    } action: { isRevealable in
                        guard isRevealable != sidebarHasRevealableWidth else { return }
                        sidebarHasRevealableWidth = isRevealable
                        if isRevealable { sidebarRevealGeneration += 1 }
                    }
            } detail: {
                detailColumn(sizeClass: adaptiveSizeClass)
                    .id("gethog.mac-detail-column")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("gethog.mac-detail-column")
            }
        }
        .focusedSceneValue(
            \.macSidebarToggle,
            MacSidebarToggleAction(presentation: sidebarPresentation) {
                sidebarPresentation = sidebarPresentation.toggled
            }
        )
        // Nothing typed into this app is a sentence by default — see RootView's
        // note for the measurement. The Mac half of that pair is autocorrection;
        // there is no software keyboard to stop capitalising.
        .autocorrectionDisabled()
        .environment(openDetails)
        // The Go menu's whole surface (Task 5). Published from the ready phase
        // only, so the menu items are correctly disabled while the app is still
        // connecting or asking for a key.
        .focusedSceneValue(\.openTab, OpenTabAction { open($0) })
        .onAppear {
            // Scene storage can only hold what this shell wrote, but the guard
            // costs one line and a selection with no sidebar row costs a launch.
            if selectedTab == .settings { selectedTab = .dashboards }
            reconcileSidebar(for: selectedTab)
            // Cold launch: a URL that started the app arrived before this body
            // existed, so it is waiting rather than lost.
            routePendingLinks()
            #if DEBUG
            // Last, for the reason RootView records: the mailbox above can
            // navigate, and an explicitly requested launch destination is the
            // most specific instruction the process has.
            if !hasAppliedDebugTab {
                hasAppliedDebugTab = true
                if let raw = DebugLaunch.initialTab, let tab = AppTab(rawValue: raw) {
                    open(tab)
                }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: LinkInbox.didChangeNotification)) { _ in
            routePendingLinks()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: IntentNavigationTarget.didChangeNotification
            )
        ) { _ in
            routePendingLinks()
        }
        // The menu bar's poke. Needed because a popover click does not
        // foreground the app the way opening it from the Dock would, so unlike
        // every other entrance there is no scene-phase change below to
        // piggyback on — the record would otherwise sit unread until something
        // else woke this shell.
        .onReceive(
            NotificationCenter.default.publisher(for: MacMenuBar.pendingOpenNotification)
        ) { _ in
            routePendingLinks()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { routePendingLinks() }
        }
        .alert(
            linkNotice?.title ?? "",
            isPresented: Binding(
                get: { linkNotice != nil },
                set: { if !$0 { linkNotice = nil } }
            ),
            presenting: linkNotice
        ) { notice in
            if let url = notice.webURL {
                Button("Open in PostHog") { openURL(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        // Beside the link notice for the same reason it is: a failed
        // organization switch has no screen of its own to report on, and the
        // switcher that started it is a menu that has already dismissed itself.
        .alert(
            "Couldn't switch organization",
            isPresented: Binding(
                get: { model.organizationError != nil },
                set: { if !$0 { model.organizationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.organizationError ?? "")
        }
        .environment(surveyLifecycle)
        .environment(experimentLifecycle)
    }

    private var sidebarPresentation: MacSidebarPresentation {
        get {
            MacSidebarPresentation(rawValue: sidebarPresentationRawValue) ?? .visible
        }
        nonmutating set {
            sidebarPresentationRawValue = newValue.rawValue
        }
    }

    private func detailColumn(sizeClass: UserInterfaceSizeClass) -> some View {
        mountedRoot(for: selectedTab, sizeClass: sizeClass)
        // The scene owns the selected root's native title from its shell detail
        // surface. Regular-width roots such as Events and Sessions
        // bring a nested `NavigationSplitView`, which consumes title
        // preferences attached inside its list column; without this outer
        // title the containing window falls back to GetHog. The roots keep
        // their own chrome for compact pushes and inner column labels.
        .topLevelNavigationTitle(selectedTab.title)
        .projectSubtitle()
    }

    // MARK: - Structure

    private var sidebar: some View {
        ScrollViewReader { proxy in
            List(selection: selectedTabBinding) {
                Label(AppTab.search.title, systemImage: AppTab.search.systemImage)
                    .tag(AppTab.search)
                    .id(AppTab.search)

                sidebarSections
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("gethog.mac-sidebar")
            .onAppear { reveal(selectedTab, using: proxy) }
            .onChange(of: sidebarRevealGeneration) { _, _ in
                reveal(selectedTab, using: proxy)
            }
        }
    }

    private var selectedTabBinding: Binding<AppTab?> {
        Binding(
            get: { selectedTab },
            set: { tab in
                guard let tab else { return }
                open(tab)
            }
        )
    }

    @ViewBuilder
    private var sidebarSections: some View {
        ForEach(Self.sections) { section in
            Section(isExpanded: expansionBinding(for: section.id)) {
                ForEach(section.tabs, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                        .id(tab)
                }
            } header: {
                Text(section.title)
            }
        }
    }

    private func expansionBinding(for sectionID: String) -> Binding<Bool> {
        Binding(
            get: {
                MacSidebarExpansion(persistedValue: persistedSidebarExpansion)
                    .contains(sectionID)
            },
            set: { isExpanded in
                var expansion = MacSidebarExpansion(
                    persistedValue: persistedSidebarExpansion
                )
                expansion.setExpanded(isExpanded, for: sectionID)
                persistedSidebarExpansion = expansion.persistedValue
            }
        )
    }

    @ViewBuilder
    private func mountedRoot(
        for tab: AppTab,
        sizeClass: UserInterfaceSizeClass
    ) -> some View {
        MacSelectedRootAccessibilityContainer(
            identifier: tab.selectedRootAccessibilityIdentifier,
            label: "\(tab.title) screen"
        ) {
            container(for: tab, compact: sizeClass == .compact)
                .id(tab)
                .environment(\.horizontalSizeClass, sizeClass)
                .environment(\.macRegularListWidth, regularSplitWidthBinding(for: tab))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func regularSplitWidthBinding(for tab: AppTab) -> Binding<Double> {
        Binding(
            get: {
                let width = MacRegularSplitWidthState(
                    persistedValue: persistedRegularSplitWidths
                ).width(for: tab, defaultWidth: .nan)
                return width
            },
            set: { width in
                var state = MacRegularSplitWidthState(
                    persistedValue: persistedRegularSplitWidths
                )
                state.set(width: width, for: tab)
                persistedRegularSplitWidths = state.persistedValue
            }
        )
    }

    @ViewBuilder
    private func container(for tab: AppTab, compact: Bool) -> some View {
        if tab == .search {
            NavigationStack(path: $searchPath) {
                ProjectSearchView()
                    .navigationDestination(for: AppTab.self) { destination in
                        TabRootView(tab: destination)
                            .onAppear { open(destination) }
                    }
                    // A link and a search result open the same objects, so both
                    // routes deliberately share this one stack.
                    .navigationDestination(for: PostHogLink.self) {
                        LinkDestinationView(link: $0)
                    }
            }
        } else {
            MacAdaptiveNavigationHost(tab: tab, compact: compact) {
                inlineDetailHost(for: tab)
            }
        }
    }

    /// The Mac ending of the sheet-hoisting story: the four screens that write
    /// a detail into `OpenDetails` and stop get that detail *pushed* here —
    /// same `DetailSheetView` switch, same clear-on-dismiss contract (a pop
    /// writes nil back through the binding), no sheet.
    @ViewBuilder
    private func inlineDetailHost(for tab: AppTab) -> some View {
        if tab.presentsDetailAsSheet {
            TabRootView(tab: tab)
                .navigationDestination(item: detailBinding(for: tab)) { detail in
                    DetailSheetView(presented: PresentedDetail(tab: tab, detail: detail))
                }
        } else {
            TabRootView(tab: tab)
        }
    }

    private func detailBinding(for tab: AppTab) -> Binding<AnyHashable?> {
        Binding(
            get: { openDetails[tab] },
            set: { openDetails[tab] = $0 }
        )
    }

    // MARK: - Navigation

    private func reconcileSidebar(for tab: AppTab) {
        var expansion = MacSidebarExpansion(persistedValue: persistedSidebarExpansion)
        expansion.reconcileOpening(tab)
        persistedSidebarExpansion = expansion.persistedValue
        sidebarRevealGeneration += 1
    }

    private func reveal(_ tab: AppTab, using proxy: ScrollViewProxy) {
        // `onChange` runs after expansion has rebuilt the List, so the stable
        // row id exists by the time the native scroll container receives this.
        proxy.scrollTo(tab, anchor: .center)
    }

    /// Goes to a destination by name — from the Go menu (through `\.openTab`),
    /// a link, or `GETHOG_TAB`. Settings has no row; ⌘, territory.
    private func open(_ tab: AppTab) {
        guard tab != .settings else {
            openSettings()
            return
        }
        selectedTab = tab
        reconcileSidebar(for: tab)
        // Asking for search means the field, not whatever the stack last held —
        // same reset, same reason, as RootView.
        if tab == .search { searchPath = NavigationPath() }
    }

    /// Drains everything waiting to be navigated to.
    private func routePendingLinks() {
        // The menu bar extra's landing path — the same `PendingOpen` record a
        // widget writes on iOS, consumed under `RootView`'s rules because it is
        // the same record: the metric routes to the dashboard it was read from,
        // carried with the project the snapshot names so `open(_:)` refuses
        // rather than showing another project's dashboard under the same
        // number; an unknown id routes one honest level up; and it is consumed
        // either way, so a stale request cannot redirect a later launch.
        if let pending = snapshotStore.pendingOpen() {
            snapshotStore.clearPendingOpen()
            let snapshot = snapshotStore.loadOrNil()
            if let metricID = pending.metricID,
               let dashboardID = snapshot?.metric(id: metricID)?.dashboardID,
               let projectID = snapshot?.projectID {
                open(PostHogLinkTarget(projectID: projectID, link: .dashboard(id: dashboardID)))
            } else {
                open(.dashboards)
            }
        }
        if let target = IntentNavigationTarget.consume() {
            if let staged = target.stagedQuery {
                LinkInbox.stage(query: staged.term, for: staged.tab)
            }
            open(target.linkTarget)
        }
        if let url = LinkInbox.consume() {
            guard let target = PostHogLinkParser.parse(url) else {
                linkNotice = .unrecognised(url)
                return
            }
            open(target)
        }
    }

    /// Goes where a link points, or explains why it can't — see RootView's
    /// twin for the project-first rationale.
    private func open(_ target: PostHogLinkTarget) {
        if let projectID = target.projectID, case .inaccessible = model.selectProject(id: projectID) {
            linkNotice = .inaccessibleProject(id: projectID)
            return
        }

        switch target.link {
        case .screen(let tab):
            open(tab)
        default:
            guard target.link.opensInApp else {
                linkNotice = .noScreen(
                    link: target.link,
                    webURL: target.link.webPath.flatMap(model.webURL(path:))
                )
                return
            }
            open(.search)
            var path = NavigationPath()
            path.append(target.link)
            searchPath = path
        }
    }
}

/// Keeps the selected destination's stable acceptance marker from becoming an
/// accessibility owner for the destination itself. On macOS, applying an
/// identifier to the mounted root replaces identifiers exported by descendants
/// such as the adjustable product divider. A separate, noninteractive witness
/// lets acceptance tests observe selection while every real control keeps its
/// own identity and actions.
struct MacSelectedRootAccessibilityContainer<Content: View>: View {
    let identifier: String
    let label: String
    private let content: Content

    init(
        identifier: String,
        label: String = "Selected screen",
        @ViewBuilder content: () -> Content
    ) {
        self.identifier = identifier
        self.label = label
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content

            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(label)
        }
    }
}

/// Keeps the compact/regular navigation boundary explicit and testable. The
/// shell chooses `compact` from its visibility-independent adaptive width, so
/// hiding a source list never swaps these branches underneath a selected root.
struct MacAdaptiveNavigationHost<Root: View>: View {
    let tab: AppTab
    let compact: Bool
    private let root: Root

    init(
        tab: AppTab,
        compact: Bool,
        @ViewBuilder root: () -> Root
    ) {
        self.tab = tab
        self.compact = compact
        self.root = root()
    }

    @ViewBuilder
    var body: some View {
        if tab.ownsNavigationContainer(compact: compact) {
            root
        } else {
            NavigationStack { root }
        }
    }
}

/// The structural split between the app-wide source list and the selected
/// product root. It deliberately is not a navigation container: nested product
/// splits must receive only their physical detail width and no inherited
/// source-list safe area.
///
/// Both children stay at stable structural positions. Hiding the sidebar
/// changes two widths to zero; it never conditionally removes or duplicates
/// the detail subtree.
struct MacSidebarShell<Sidebar: View, Detail: View>: View {
    let presentation: MacSidebarPresentation
    @Binding private var preferredSidebarWidth: Double
    private let sidebar: Sidebar
    private let detail: Detail

    @GestureState private var resizeTranslation: CGFloat = 0

    init(
        presentation: MacSidebarPresentation,
        preferredSidebarWidth: Binding<Double>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.presentation = presentation
        _preferredSidebarWidth = preferredSidebarWidth
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        let sourceListWidth = MacSidebarShellLayout.sourceListWidth(
            presentation: presentation,
            preferredWidth: CGFloat(preferredSidebarWidth),
            resizeTranslation: resizeTranslation
        )
        let separatorWidth = MacSidebarShellLayout.separatorWidth(
            presentation: presentation
        )

        HStack(spacing: 0) {
            sidebar
                .frame(width: sourceListWidth)
                .clipped()
                .opacity(presentation == .visible ? 1 : 0)
                .allowsHitTesting(presentation == .visible)
                .accessibilityHidden(presentation == .hidden)

            sidebarSeparator(
                sourceListWidth: sourceListWidth,
                separatorWidth: separatorWidth
            )

            detail
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .animation(.easeInOut(duration: 0.16), value: presentation)
    }

    private func sidebarSeparator(
        sourceListWidth: CGFloat,
        separatorWidth: CGFloat
    ) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: separatorWidth)
            .overlay {
                Color.clear
                    .frame(width: MacSidebarShellLayout.separatorHitWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($resizeTranslation) { value, state, _ in
                                state = value.translation.width
                            }
                            .onEnded { value in
                                preferredSidebarWidth = Double(
                                    MacSidebarShellLayout.clampedWidth(
                                        CGFloat(preferredSidebarWidth)
                                            + value.translation.width
                                    )
                                )
                            }
                    )
            }
            .allowsHitTesting(presentation == .visible)
            .accessibilityElement()
            .accessibilityIdentifier("gethog.mac-sidebar-divider")
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(sourceListWidth)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat
                switch direction {
                case .increment:
                    delta = MacSidebarShellLayout.keyboardResizeStep
                case .decrement:
                    delta = -MacSidebarShellLayout.keyboardResizeStep
                @unknown default:
                    return
                }
                preferredSidebarWidth = Double(
                    MacSidebarShellLayout.clampedWidth(sourceListWidth + delta)
                )
            }
            .accessibilityHidden(presentation == .hidden)
    }
}
