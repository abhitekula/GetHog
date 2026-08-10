import GetHogKit
import GetHogUI
import SwiftUI

/// One effective description of the compact tab bar, shared by Search and
/// every navigation decision that has to translate a destination into it.
struct CompactTabMembership: Equatable {
    let productTabs: [AppTab]

    var visibleTabs: [AppTab] { productTabs + [.search] }

    func shellSelection(for destination: AppTab) -> AppTab {
        visibleTabs.contains(destination) ? destination : .search
    }

    func requiresSearchPush(for destination: AppTab) -> Bool {
        !visibleTabs.contains(destination)
    }

    func shouldRestore(destination: AppTab, searchPathIsEmpty: Bool) -> Bool {
        searchPathIsEmpty && requiresSearchPush(for: destination)
    }
}

/// iPhone owns its four product tabs in `NavPreferences`; iPad owns the
/// visibility of its four authored primary tabs in SwiftUI's
/// `TabViewCustomization`. Keeping the effective membership here prevents a
/// narrow iPad from reading the unrelated phone preference store, or treating
/// a regular-width secondary as a compact tab that SwiftUI never declared.
enum CompactNavigationPolicy {
    static func membership(
        isPad: Bool,
        phoneTabs: [AppTab],
        iPadTabBarVisibility: (AppTab) -> Visibility
    ) -> CompactTabMembership {
        let productTabs = isPad ? AppTab.primary.filter {
            // These four are the only product tabs declared in compact iPad
            // width. `automatic` therefore means the authored visible default;
            // a secondary tab made visible in the regular sidebar is still not
            // a compact tab and must remain reachable through Search.
            iPadTabBarVisibility($0) != .hidden
        } : phoneTabs
        return CompactTabMembership(productTabs: productTabs)
    }
}

/// Carries the destination of an intentional Search-stack reset across
/// SwiftUI's later empty-path observation. A genuine Back/pop has no pending
/// destination and therefore returns to Search.
struct SearchPathResetTransition: Equatable {
    private(set) var pendingSelection: AppTab?

    mutating func prepareProgrammaticReset(
        finalSelection: AppTab,
        pathWasEmpty: Bool
    ) {
        guard finalSelection != .search else {
            pendingSelection = nil
            return
        }
        guard !pathWasEmpty || pendingSelection != nil else { return }
        pendingSelection = finalSelection
    }

    mutating func supersedePendingSelection(with finalSelection: AppTab) {
        guard pendingSelection != nil else { return }
        pendingSelection = finalSelection == .search ? nil : finalSelection
    }

    mutating func invalidateForNonemptyPath() {
        pendingSelection = nil
    }

    mutating func selectionWhenPathBecomesEmpty(
        pathIsCurrentlyEmpty: Bool
    ) -> AppTab? {
        guard pathIsCurrentlyEmpty else { return nil }
        let selection = pendingSelection ?? .search
        pendingSelection = nil
        return selection
    }
}

@MainActor
enum IOSOpenDetailsAuthority {
    static func applyChange(
        from previous: FlagWriteScope?,
        to current: FlagWriteScope?,
        openDetails: OpenDetails
    ) {
        guard previous != current else { return }
        openDetails.reset()
    }
}

// `TabRootView`, `PresentedDetail` and `DetailSheetView` moved to
// `App/TabRootView.swift`: this file is iOS-only — `UIDevice`, the size class
// and `tabBarMinimizeBehavior` are all named below — and is excluded from the
// Mac target, which needs those three.

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(NavPreferences.self) private var nav
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @SceneStorage("selectedTab") private var selectedTab: AppTab = .dashboards
    /// The search tab's stack. Heterogeneous — a screen result pushes an
    /// `AppTab`, the root it lands on then pushes its own issues, logs and
    /// traces into the same stack, and an object result pushes a dashboard or a
    /// flag — so no typed path can hold it.
    @State private var searchPath = NavigationPath()
    @State private var searchPathReset = SearchPathResetTransition()
    /// Held here rather than in the screens themselves: this view is the only
    /// thing in the tree that survives a size-class change intact.
    @State private var openDetails = OpenDetails()
    /// The optimistic state behind the survey and experiment writes, owned here
    /// for two reasons that are the same reason `openDetails` is.
    ///
    /// The detail *sheets* for both are presented from this view — see
    /// `presentedDetail` — while the lists that opened them live in a secondary
    /// screen hosted twice across the size-class boundary. A controller declared
    /// as `@State` in either place would be a different object from the other's,
    /// so a survey stopped in the sheet would leave the row behind it reading
    /// "Running", and a rotation would discard whichever copy the resize rebuilt.
    /// One object above both, injected into both, is the only arrangement where
    /// the list and the sheet cannot disagree.
    @State private var surveyLifecycle = SurveyLifecycleController()
    @State private var experimentLifecycle = ExperimentLifecycleController()
    @State private var hasAppliedDebugTab = false
    /// SwiftUI's own record of how the iPad sidebar has been rearranged.
    ///
    /// **iPad only, and the gate is `tabViewCustomization`'s own optional
    /// binding rather than a branch in the view tree** — passing `nil` switches
    /// the whole mechanism off without changing the shape of the `TabView`, so
    /// the single-`TabView`-across-both-widths arrangement survives intact.
    ///
    /// Two stores describing one bar is what this avoids. On iPhone the four
    /// loose tabs come from `NavPreferences`; on iPad they are the static
    /// defaults and this holds the arrangement instead. No device has both.
    @AppStorage("sidebarCustomization") private var sidebarCustomization = TabViewCustomization()
    /// Set only when a link could not do what it said. Success is silent; see
    /// `LinkNotice`.
    @State private var linkNotice: LinkNotice?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

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
                .environment(openDetails)
                .tabViewStyle(.sidebarAdaptable)
                // **Measured** on iPad Air 11-inch (M4), 820 x 1180, sidebar
                // open: this adds the system's own Edit button to the sidebar
                // header at (18, 36, 54.5, 36) - 18 buttons against 17 without
                // it. The control run kept the `customizationID`s and removed
                // only this line, and the button went away, which is what makes
                // the attribution causal rather than coincidental.
                //
                // **Measured** on iPhone 17, 402 x 874: nothing. No Edit, no
                // Customize, no Rearrange anywhere in the rendered tree, and a
                // 1.2s long press on a tab bar button surfaced no affordance
                // (183 elements before, 185 after). The API cannot be driven
                // into the compact bar programmatically either -
                // `TabCustomization.tabBarVisibility` is get-only. That is why
                // there is a Settings editor at all.
                .tabViewCustomization(isPad ? $sidebarCustomization : nil)
                // Gives the tab bar's height back to the data while reading down a
                // long list, which is most of what this app is. It restores itself
                // on the first upward scroll, so nothing becomes unreachable.
                .tabBarMinimizeBehavior(.onScrollDown)
                // Nothing typed into this app is a sentence by default: search
                // queries are event names, flag keys, emails and URLs, and
                // autocapitalisation was corrupting every one of them
                // (`zzzqqq` → `Zzzqqq` across all ~29 search fields, measured
                // live on both devices). The handful of true prose fields —
                // annotation text, experiment conclusions, saved-filter names —
                // opt back in with `.sentences` locally, which wins over this.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // On iPhone, Cmd-1..4 follow the user's four product tabs. On
                // iPad they remain the four authored primary commands; if the
                // system customization hides one, `open(_:)` routes it through
                // Search under the same effective compact policy. Settings
                // takes the platform-conventional comma rather than a fifth
                // number it would have to compete for.
                .keyboardActions(
                    looseTabs.enumerated().map { index, tab in
                        // `KeyEquivalent` is expressible by a literal but not
                        // convertible from a `Character`, and the digit here is
                        // computed rather than written out.
                        KeyboardAction(
                            key: KeyEquivalent(Character("\(index + 1)")),
                            title: tab.title
                        ) { open(tab) }
                    }
                        + [KeyboardAction(key: ",", title: AppTab.settings.title) { open(.settings) }]
                )
                // Attached **here**, to the one view in the tree that a resize
                // never rebuilds, rather than inside the four screens that own
                // these details. See `presentedDetail`.
                //
                // The lifecycle controllers are injected before `.sheet` because
                // a presented view inherits the environment at the modifier site.
                // Attaching the sheet outside those injections would leave its
                // content without the required lifecycle controllers.
                .sheet(item: presentedDetail) { DetailSheetView(presented: $0) }
                .onAppear {
                    restorePushedTab()
                    // Cold launch: a quick action or a URL that started the app
                    // arrived before this body existed, so it is waiting rather
                    // than lost.
                    routePendingLinks()
                    #if DEBUG
                    // Last, not first. Both mailboxes above can navigate, and
                    // they are drained from storage shared with the widgets and
                    // the intent extension — so a target left over from an
                    // earlier run used to arrive *after* `GETHOG_TAB` had been
                    // honoured and quietly overrule it. An explicitly requested
                    // launch destination is the most specific instruction the
                    // process has; it now wins.
                    //
                    // Applied once: `@SceneStorage` would otherwise fight a user who
                    // switched tabs after launch.
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
                // The notification above only ever arrives from inside this
                // process. An intent runs in one the system picked, so its
                // hand-off is a write to shared defaults and nothing more — the
                // only moment the app can notice is coming forward.
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
                // Attached beside the link notice for the same reason it is: a
                // failed organization switch has no screen of its own to report
                // on, and the switcher that started it is a menu that has already
                // dismissed itself by the time the request comes back. Nothing
                // moved when this fires — the projects, the project and the
                // subtitle are all still the organization the user was in — so
                // the alert is the whole of the feedback and has to carry the
                // reason.
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
                // A Max-size iPhone in landscape and an iPad in narrow
                // multitasking both cross the size-class boundary while running,
                // which moves a destination between the sidebar and the index.
                .onChange(of: sizeClass) { _, _ in restorePushedTab() }
                .onChange(of: searchPath.isEmpty) { _, isEmpty in
                    // Popping back leaves `selectedTab` naming a screen that is no
                    // longer showing, which the sidebar would then restore on the
                    // next rotation into regular width. At the root it is `.search`,
                    // unless a visible tab deliberately cleared the old Search
                    // stack and left its final selection for this observer.
                    if isEmpty,
                       let finalSelection = searchPathReset.selectionWhenPathBecomesEmpty(
                           pathIsCurrentlyEmpty: searchPath.isEmpty
                       ) {
                        selectedTab = finalSelection
                    }
                }
                // **Outermost, and that is load-bearing.** Both the tab tree and
                // the `.sheet` above have to see these, and only a modifier that
                // encloses the sheet supplies it — see the note on `.sheet`, which
                // records the crash that established this. Placing them here means
                // the survey list and the survey sheet read one object, so a
                // survey stopped in the sheet cannot leave the row behind it
                // reading "Running".
                .environment(surveyLifecycle)
                .environment(experimentLifecycle)
            }
        }
        .onChange(of: model.flagWriteScope) { previousScope, currentScope in
            // This observer must outlive the ready subtree: sign-out clears the
            // authenticated scope and replaces that subtree in one actor turn.
            // Keeping it above the phase switch guarantees authentication-bound
            // detail stores are invalidated even when no ready screen remains.
            IOSOpenDetailsAuthority.applyChange(
                from: previousScope,
                to: currentScope,
                openDetails: openDetails
            )
        }
        .onChange(of: model.projectID) { _, id in
            // The dynamic quick actions name objects in one project, so they
            // have to be rebuilt whenever that project changes.
            QuickActions.refresh(projectID: id)
        }
    }

    // MARK: - Structure

    /// One `TabView` across both widths rather than two.
    ///
    /// Only the trailing content differs, so the four primary tabs keep their
    /// identity — and therefore their loaded data and scroll position — when a
    /// Max-size iPhone is rotated across the size-class boundary. Two separate
    /// `TabView`s threw all of that away on every rotation.
    /// Whether this process is running on an iPad.
    ///
    /// **Idiom, deliberately, and not the size class** - which is the
    /// discriminator used everywhere else in this file. An iPhone 17 Pro Max in
    /// landscape *is* regular width, so a size-class gate would make the user's
    /// chosen four vanish on rotation and return on rotating back. Idiom is a
    /// per-process constant, which keeps this a static branch: the single
    /// `TabView` below stays single, and nothing rebuilds when the device turns.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The tabs that sit loose in the bar - or, in regular width, above the
    /// sidebar's sections.
    ///
    /// The user's four on iPhone; the defaults on iPad, where SwiftUI's own
    /// customisation owns the arrangement instead.
    private var looseTabs: [AppTab] { isPad ? AppTab.primary : nav.barTabs }

    /// The effective compact bar, including the decisions Search, selection,
    /// opening, and scene restoration all derive from. The static `Tab`
    /// declarations below stay authored and stable; SwiftUI's customization
    /// modifier owns which of the iPad declarations are actually visible.
    private var compactMembership: CompactTabMembership {
        CompactNavigationPolicy.membership(
            isPad: isPad,
            phoneTabs: nav.barTabs,
            iPadTabBarVisibility: { tab in
                sidebarCustomization[tab: tab.rawValue].tabBarVisibility
            }
        )
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            tabItems(for: looseTabs)

            searchTab

            if sizeClass != .compact {
                sidebarSections
                tabItems(for: AppTab.utility)
            }
        }
    }

    /// The index tab uses an ordinary `Tab` at both widths.
    ///
    /// It owns the stack, our list, our chrome. SwiftUI's generated "More" list
    /// is what this replaces; `ScreenIndexSections` records what that list cost.
    private var searchTab: some TabContent<AppTab> {
        Tab(
            AppTab.search.title,
            systemImage: AppTab.search.systemImage,
            value: AppTab.search
        ) {
            NavigationStack(path: searchPathBinding) {
                ProjectSearchView(compactLooseTabs: compactMembership.productTabs)
                    .navigationDestination(for: AppTab.self) { tab in
                        TabRootView(tab: tab)
                            // Which destination is showing, for the sidebar to
                            // select if this scene becomes regular width, and for
                            // scene restoration. The stack cannot be read back.
                            .onAppear { selectedTab = tab }
                    }
                    // Where a link lands. Registered on this stack rather than a
                    // stack of its own because a link and a search result open
                    // the same objects, and two stacks would mean two back
                    // buttons that behave differently for the same dashboard.
                    .navigationDestination(for: PostHogLink.self) { LinkDestinationView(link: $0) }
            }
        }
    }

    @TabContentBuilder<AppTab>
    private func tabItems(for tabs: [AppTab]) -> some TabContent<AppTab> {
        ForEach(tabs, id: \.self) { tab in
            Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                container(for: tab)
            }
            // Applied at both idioms, and inert on iPhone: the control run
            // recorded on `.tabViewCustomization` above kept these ids and
            // removed only the binding, and no editor appeared.
            .customizationID(tab.rawValue)
        }
    }

    /// `.sidebarAdaptable` turns these into the iPad sidebar. That arrangement
    /// is good and must stay; only compact width swaps them for the index inside
    /// the search tab.
    @TabContentBuilder<AppTab>
    private var sidebarSections: some TabContent<AppTab> {
        // Excluding the loose tabs is what the taxonomy change made necessary:
        // the four defaults now live inside sections, so a sidebar that declared
        // them loose *and* rendered every section would list each of them twice.
        ForEach(AppTab.groupedScreens(excluding: looseTabs)) { section in
            TabSection(section.title) {
                tabItems(for: section.tabs)
            }
            .customizationID("section.\(section.title)")
        }
    }

    /// The stack a screen navigates in.
    ///
    /// Ownership sits here rather than in the roots because a root that carried
    /// its own stack would draw a redundant navigation bar when content pushed.
    @ViewBuilder
    private func container(for tab: AppTab) -> some View {
        if tab.ownsNavigationContainer(
            compact: sizeClass == .compact,
            accessibilitySize: dynamicTypeSize.isAccessibilitySize
        ) {
            TabRootView(tab: tab)
        } else {
            NavigationStack {
                TabRootView(tab: tab)
            }
        }
    }

    // MARK: - Sheet details

    /// The sheet the showing screen has open, if that screen shows sheets.
    ///
    /// **Why this is here and not in the four screens.** Everything else a
    /// secondary screen opens is a *push*, and a push can be driven from inside
    /// the screen: `navigationDestination(item:)` reads `OpenDetails`, and when
    /// the size class swaps hosts the destination is simply rebuilt from the
    /// value on the other side. A sheet cannot be driven that way, and two
    /// nested presentation would clear its state when the host sheet is
    /// dismissed during a size-class transition.
    ///
    /// Both failures are the same fact — a sheet's teardown is indistinguishable
    /// from a user dismissing it, and the teardown happens on a beat the screen
    /// does not control. So the presentation moves to the one place a resize
    /// never tears down. `RootView` straddles the boundary; only the *content*
    /// of its `TabView` changes shape when the size class does. Nothing dismisses
    /// this sheet but a user, and a user's dismissal is the only `nil` it writes.
    ///
    /// Keyed on `selectedTab` because that is what names the showing screen at
    /// both widths — the sidebar selects it in regular width and the search
    /// stack's destination sets it in compact. Navigating away therefore closes
    /// the sheet without clearing it, and coming back re-presents it. That is
    /// the same promise every pushing screen makes — `OpenDetails` is what
    /// a screen *has open*, and a screen you return to is where you left it —
    /// and it is reachable only by a link arriving from outside, since a sheet
    /// covers the app and there is nothing else to tap while one is up.
    ///
    /// A read, and only a read: no `onChange` clears this. Every clearing path
    /// that ran off something other than the user's own dismissal is what broke
    /// the two attempts above.
    private var presentedDetail: Binding<PresentedDetail?> {
        Binding(
            get: {
                guard selectedTab.presentsDetailAsSheet,
                      let detail = openDetails[selectedTab]
                else { return nil }
                return PresentedDetail(tab: selectedTab, detail: detail)
            },
            set: { newValue in
                // `.sheet(item:)` only ever writes `nil` here, and it means the
                // user dismissed it. Cleared across all four rather than for
                // `selectedTab` alone: the write can land after the selection
                // has already moved on, and clearing the tab that happens to be
                // showing *then* would leave the dismissed screen's detail set
                // and reopen its sheet the moment it came back.
                guard newValue == nil else { return }
                for tab in AppTab.allCases where tab.presentsDetailAsSheet {
                    openDetails[tab] = nil
                }
            }
        )
    }

    // MARK: - Selection

    /// `selectedTab` names a destination; the tab bar and the sidebar can each
    /// show only the subset they have a row for.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: {
                if sizeClass == .compact {
                    // A destination outside the effective compact membership
                    // sits on Search's stack. This covers secondary screens on
                    // every device and an authored primary hidden on iPad.
                    compactMembership.shellSelection(for: selectedTab)
                } else {
                    // Every tab has a sidebar row of its own in regular width,
                    // search included, so nothing needs translating here.
                    selectedTab
                }
            },
            set: { selectedTab = $0 }
        )
    }

    /// Child pushes enter through this binding; root-driven navigation goes
    /// through `setSearchPath(_:finalSelection:)` below. A nonempty path always
    /// supersedes a pending empty observation, while an empty child write is a
    /// genuine Back/pop and must leave that observation for the resolver.
    private var searchPathBinding: Binding<NavigationPath> {
        Binding(
            get: { searchPath },
            set: { path in
                if !path.isEmpty {
                    searchPathReset.invalidateForNonemptyPath()
                }
                searchPath = path
            }
        )
    }

    /// The one root-level write seam for the heterogeneous Search stack.
    private func setSearchPath(_ path: NavigationPath, finalSelection: AppTab) {
        let pathWasEmpty = searchPath.isEmpty
        if path.isEmpty {
            searchPathReset.prepareProgrammaticReset(
                finalSelection: finalSelection,
                pathWasEmpty: pathWasEmpty
            )
        } else {
            searchPathReset.invalidateForNonemptyPath()
        }
        searchPath = path
    }

    /// Goes to a destination by name, from a keyboard shortcut or `GETHOG_TAB`.
    ///
    /// In compact width a destination outside the effective membership means
    /// selecting Search *and* pushing, replacing whatever was pushed before
    /// rather than landing behind it: `⌘,` has to reach Settings from anywhere.
    private func open(_ tab: AppTab) {
        selectedTab = tab

        // Asking for search means the field, at *both* widths. The reset used to
        // sit behind the compact guard below, so in regular width selecting
        // search showed whatever had last been pushed onto this stack — a link's
        // destination, or a screen restored from a rotation — instead of the
        // search root. The stack is shared with links precisely so a back button
        // behaves once; that sharing is what makes clearing it necessary here.
        if tab == .search {
            setSearchPath(NavigationPath(), finalSelection: .search)
            return
        }

        // Everything past this point is compact-only: in regular width every
        // destination has a sidebar row of its own, so selecting it is the whole
        // job and nothing needs pushing.
        guard sizeClass == .compact else {
            searchPathReset.supersedePendingSelection(with: tab)
            return
        }
        if compactMembership.requiresSearchPush(for: tab) {
            var path = NavigationPath()
            path.append(tab)
            setSearchPath(path, finalSelection: tab)
        } else {
            // A destination with a bar row of its own, so nothing needs pushing
            // - but whatever *was* pushed has to go, and that is not tidiness.
            //
            // **Measured**, launching with a custom bar and `GETHOG_TAB=logs`:
            // the app came up on *Dashboards*, under the Search tab.
            // `restorePushedTab()` runs first and pushes the scene-restored
            // `selectedTab` - which that bar does not hold - and the pushed
            // destination carries `.onAppear { selectedTab = tab }` so the
            // sidebar can follow it. That write lands *after* `open(.logs)` and
            // puts the selection back on a screen with no bar row, so
            // `tabSelection` falls through to `.search`.
            setSearchPath(NavigationPath(), finalSelection: tab)
        }
    }

    // MARK: - Links

    /// Drains everything waiting to be navigated to.
    ///
    /// Both mailboxes, because an intent that opens the app and a tapped link
    /// are the same request as far as this view is concerned: go somewhere.
    private func routePendingLinks() {
        // The Control Center dashboard button writes this and, until now,
        // nothing read it. Its intent sets `openAppWhenRun`, so the app came to
        // the front and stopped — on whatever screen you happened to leave it.
        // Pressing a control labelled with a *metric* and landing on Settings is
        // the control silently failing at the only job it has.
        //
        // The landing is the dashboard the metric was read from, and it stays
        // that way now that `.insight` opens in the app.
        //
        // The old reasoning here was that this app had no screen for a lone
        // insight, so a dashboard was the deepest it could go. That reason is
        // gone — `InsightsRoot` and `SavedInsightDetailView` exist and
        // `PostHogLink.insight.opensInApp` is now true — but the destination is
        // unchanged, for a reason that was always the better one and was
        // previously hidden behind the limitation:
        //
        // `SharedSnapshot.Metric` records the *dashboard* id at write time
        // because that is what the widget's writer had in hand; it has never
        // carried an insight id, and it still doesn't. Routing to an insight
        // would mean inventing one from the metric's title, which is a guess.
        // A control labelled with a metric landing on the dashboard that
        // contains it is honest; landing on some other project object that
        // happens to share a name is not.
        //
        // Falls back to the dashboards home whenever the id is unknown — a
        // snapshot written by an older build, or a metric that has since left
        // the dashboard. Landing one level up is the correct degradation; a
        // guess would not be.
        //
        // Consumed either way, so a stale request cannot redirect a later launch
        // the user began somewhere else.
        if let pending = SharedSnapshotStore.shared.pendingOpen() {
            SharedSnapshotStore.shared.clearPendingOpen()
            let snapshot = SharedSnapshotStore.shared.loadOrNil()
            if let metricID = pending.metricID,
               let dashboardID = snapshot?.metric(id: metricID)?.dashboardID,
               let projectID = snapshot?.projectID {
                // Carried with its project: the snapshot names the project the
                // dashboard id was read in, and `open(_:)` refuses rather than
                // showing another project's dashboard under the same number.
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

    /// Goes where a link points, or explains why it can't.
    ///
    /// The project is settled before the object, and a project this key cannot
    /// see stops the whole thing. Resolving an object ID against a different
    /// project would draw unrelated data, so the project switcher is available
    /// on every screen.
    ///
    /// A *successful* switch says nothing. The project's name is the navigation
    /// subtitle of every screen in this app, so an alert announcing it would
    /// interrupt the user to repeat what the screen behind the alert already
    /// says.
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
            selectedTab = .search
            // Replaces rather than stacks, for the same reason `⌘,` does: a link
            // has to arrive at its destination from wherever the app was, not
            // behind whatever was already pushed.
            var path = NavigationPath()
            path.append(target.link)
            setSearchPath(path, finalSelection: .search)
        }
    }

    /// Puts a destination outside the effective compact membership back on the
    /// Search tab's stack.
    ///
    /// `selectedTab` is scene storage and survives a relaunch; the stack is
    /// `@State` and does not. Without this, `GETHOG_TAB=errorTracking` — and
    /// a restored scene — would select search and stop there instead of landing
    /// on the screen.
    private func restorePushedTab() {
        guard sizeClass == .compact,
              compactMembership.shouldRestore(
                  destination: selectedTab,
                  searchPathIsEmpty: searchPath.isEmpty
              )
        else { return }
        var path = searchPath
        path.append(selectedTab)
        setSearchPath(path, finalSelection: selectedTab)
    }
}
