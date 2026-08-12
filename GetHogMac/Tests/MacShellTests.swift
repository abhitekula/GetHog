import AppKit
import SwiftUI
import Testing
import Vision

@testable import GetHog

// Compiled by GetHogMacTests (Task 8). Not in any target until then — which
// is the point: the shell logic lands testable, and the target lands later.

@MainActor
@Suite("Mac shell structure")
struct MacShellStructureTests {

    @Test("content width, not device, selects compact navigation")
    func contentWidthClassifiesNavigation() {
        #expect(MacWindowLayout.sizeClass(forContentWidth: 719) == .compact)
        #expect(MacWindowLayout.sizeClass(forContentWidth: 720) == .regular)
    }

    @Test("Analyze and Monitor start expanded")
    func defaultSidebarExpansion() {
        let expansion = MacSidebarExpansion(persistedValue: nil)

        #expect(expansion.expandedSectionIDs == ["Analyze", "Monitor"])
    }

    @Test("persisted expansion ignores sections the app no longer has")
    func staleSidebarExpansionIsDiscarded() {
        let expansion = MacSidebarExpansion(
            persistedValue: "Workspace,Removed section,Analyze"
        )

        #expect(expansion.expandedSectionIDs == ["Analyze", "Workspace"])
        #expect(expansion.persistedValue == "Analyze,Workspace")
    }

    @Test("reset restores the default expanded sections")
    func resetSidebarExpansion() {
        var expansion = MacSidebarExpansion(persistedValue: "Data,Workspace")

        expansion.reset()

        #expect(expansion.expandedSectionIDs == ["Analyze", "Monitor"])
        #expect(expansion.persistedValue == "Analyze,Monitor")
    }

    @Test("Display settings names the source-list reset")
    func sidebarResetCopy() {
        #expect(MacSidebarSettings.resetTitle == "Reset Sidebar Sections")
    }

    @Test("Display settings reset restores source-list defaults")
    func sidebarSettingsReset() {
        #expect(
            MacSidebarSettings.resetValue(from: "Data,Workspace")
                == MacSidebarExpansion.defaultPersistedValue
        )
    }

    /// On the Mac a section row is a screen's only route — there is no phone
    /// index behind a search tab — so a tab missing from every section is a
    /// screen nothing can open.
    @Test("the sidebar lists every screen but Settings, exactly once")
    func sidebarCoversEveryScreen() {
        let listed = MacRootView.looseTabs + MacRootView.sections.flatMap(\.tabs)
        #expect(Set(listed) == Set(AppTab.allCases).subtracting([.settings]))
        #expect(listed.count == Set(listed).count)
    }

    @Test("settings has no sidebar row; the Settings scene owns it")
    func settingsStaysOut() {
        #expect(!MacRootView.sections.flatMap(\.tabs).contains(.settings))
        #expect(!MacRootView.looseTabs.contains(.settings))
    }

    @Test("search sits loose at the top, never inside a section")
    func searchIsLoose() {
        #expect(MacRootView.looseTabs == [.search])
        #expect(!MacRootView.sections.flatMap(\.tabs).contains(.search))
    }

    @Test("the sidebar's sections are AppTab's, not a copy")
    func sectionsAreTheSharedOnes() {
        #expect(MacRootView.sections.map(\.id) == AppTab.sections.map(\.id))
    }

    @Test("every selected Mac root has one stable acceptance identity")
    func selectedRootAcceptanceIdentities() {
        let roots = MacRootView.looseTabs + MacRootView.sections.flatMap(\.tabs)
        let identifiers = roots.map(\.selectedRootAccessibilityIdentifier)

        #expect(identifiers == [
            "gethog.root.search",
            "gethog.root.dashboards",
            "gethog.root.events",
            "gethog.root.sessions",
            "gethog.root.insights",
            "gethog.root.webAnalytics",
            "gethog.root.clickmap",
            "gethog.root.people",
            "gethog.root.groups",
            "gethog.root.sql",
            "gethog.root.errorTracking",
            "gethog.root.sessionSummaries",
            "gethog.root.llm",
            "gethog.root.tracing",
            "gethog.root.logs",
            "gethog.root.support",
            "gethog.root.inbox",
            "gethog.root.signals",
            "gethog.root.health",
            "gethog.root.ingestion",
            "gethog.root.warehouse",
            "gethog.root.pipelines",
            "gethog.root.automation",
            "gethog.root.actions",
            "gethog.root.annotations",
            "gethog.root.taxonomy",
            "gethog.root.flags",
            "gethog.root.experiments",
            "gethog.root.surveys",
            "gethog.root.earlyAccess",
            "gethog.root.notebooks",
            "gethog.root.max",
            "gethog.root.renders",
            "gethog.root.templates",
        ])
        #expect(Set(identifiers).count == identifiers.count)
    }

    /// The Mac shell's structural split matters only for roots that bring a
    /// second split at regular width. Dashboard is the important control: it
    /// owns navigation, but its landing is not nested.
    @Test("regular nested splits are exactly the six list-detail roots")
    func regularNestedSplitOwners() {
        let owners = Set(AppTab.allCases.filter(\.ownsRegularNestedSplit))

        #expect(owners == Set([
            AppTab.events,
            .sessions,
            .insights,
            .people,
            .errorTracking,
            .flags,
        ]))
        #expect(!AppTab.dashboards.ownsRegularNestedSplit)
    }

    /// Balanced split allocation belongs to the six roots that render an
    /// inner list-detail split inside the regular Mac shell. Compact roots
    /// drill into one pane, while Dashboard and the remaining destinations do
    /// not own a nested split that needs balancing.
    @Test("only regular nested roots balance their inner split")
    func nestedSplitStyleFollowsRenderedTopology() {
        let balancedAtRegularWidth = Set(AppTab.allCases.filter {
            MacNestedSplitStylePolicy.style(for: $0, compact: false) == .balanced
        })

        #expect(balancedAtRegularWidth == Set([
            AppTab.events,
            .sessions,
            .insights,
            .people,
            .errorTracking,
            .flags,
        ]))
        #expect(AppTab.allCases.allSatisfy {
            MacNestedSplitStylePolicy.style(for: $0, compact: true) == .automatic
        })
        #expect(MacNestedSplitStylePolicy.style(for: .dashboards, compact: false) == .automatic)
        #expect(MacNestedSplitStylePolicy.style(for: .warehouse, compact: false) == .automatic)
    }

    @Test("every grouped destination knows its one owning sidebar section")
    func sidebarSectionOwnershipComesFromTheSharedSections() {
        for section in AppTab.sections {
            for tab in section.tabs {
                #expect(tab.sidebarSectionID == section.id)
            }
        }
        #expect(AppTab.search.sidebarSectionID == nil)
        #expect(AppTab.settings.sidebarSectionID == nil)
    }

    @Test("opening a collapsed destination expands only its owning section")
    func openingDestinationReconcilesSidebarExpansion() {
        var expansion = MacSidebarExpansion(persistedValue: "Analyze,Monitor")

        let reveal = expansion.reconcileOpening(.warehouse)

        #expect(reveal == .warehouse)
        #expect(expansion.expandedSectionIDs == ["Analyze", "Monitor", "Data"])
        #expect(expansion.persistedValue == "Analyze,Monitor,Data")
    }

    @Test("opening a loose destination preserves every expansion choice")
    func openingLooseDestinationPreservesSidebarExpansion() {
        var expansion = MacSidebarExpansion(persistedValue: "Data,Workspace")

        let reveal = expansion.reconcileOpening(.search)

        #expect(reveal == .search)
        #expect(expansion.expandedSectionIDs == ["Data", "Workspace"])
        #expect(expansion.persistedValue == "Data,Workspace")
    }

    @Test("visible sidebar state always advertises Hide and hidden advertises Show")
    func sidebarCommandMatchesRenderedState() {
        #expect(MacSidebarPresentation.visible.commandTitle == "Hide Sidebar")
        #expect(MacSidebarPresentation.hidden.commandTitle == "Show Sidebar")
        #expect(MacSidebarPresentation.visible.toggled == .hidden)
        #expect(MacSidebarPresentation.hidden.toggled == .visible)
    }

    @Test("sidebar visibility cannot change adaptive navigation topology")
    func adaptiveWidthIsVisibilityIndependent() {
        let shellWidth: CGFloat = 900
        let adaptiveWidth = MacSidebarShellLayout.adaptiveDetailWidth(
            forShellWidth: shellWidth,
            preferredSidebarWidth: MacSidebarShellLayout.defaultWidth
        )

        #expect(adaptiveWidth == 679)
        #expect(MacWindowLayout.sizeClass(forContentWidth: adaptiveWidth) == .compact)
        #expect(
            MacSidebarShellLayout.sourceListWidth(
                presentation: .visible,
                preferredWidth: MacSidebarShellLayout.defaultWidth
            ) == MacSidebarShellLayout.defaultWidth
        )
        #expect(
            MacSidebarShellLayout.sourceListWidth(
                presentation: .hidden,
                preferredWidth: MacSidebarShellLayout.defaultWidth
            ) == 0
        )
        #expect(!MacSidebarShellLayout.isRevealable(sourceListWidth: 1))
        #expect(MacSidebarShellLayout.isRevealable(sourceListWidth: 190))
    }

    @Test("hidden shell reserves no source-list or separator width and keeps detail mounted")
    func hiddenSidebarGeometryIsActuallyZero() async throws {
        let recorder = MacSidebarShellGeometryRecorder()
        let controller = NSHostingController(
            rootView: MacSidebarShellGeometryProbe(recorder: recorder)
        )
        let contentSize = CGSize(width: 900, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.alphaValue = 0.01
        window.makeKeyAndOrderFront(nil)
        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        layoutSidebarShell(controller: controller, window: window)
        defer { window.close() }

        #expect(
            await waitForSidebarShellGeometry(
                pumpLayout: { layoutSidebarShell(controller: controller, window: window) }
            ) {
                recorder.detailWidth > 0 && recorder.sidebarWidth > 0
            },
            "The production shell never reported its visible child proposals."
        )
        #expect(recorder.sidebarWidth == MacSidebarShellLayout.defaultWidth)
        #expect(
            recorder.detailWidth
                == contentSize.width
                    - MacSidebarShellLayout.defaultWidth
                    - MacSidebarShellLayout.visibleSeparatorWidth,
            "The visible detail was not proposed the physical remainder."
        )
        let detailAppearances = recorder.detailAppearances

        recorder.presentation = .hidden
        #expect(
            await waitForSidebarShellGeometry(
                pumpLayout: { layoutSidebarShell(controller: controller, window: window) }
            ) {
                recorder.sidebarWidth <= 1
                    && abs(recorder.detailWidth - contentSize.width) <= 1
            },
            "The hidden production shell retained source-list or divider width."
        )
        #expect(
            MacSidebarShellLayout.separatorWidth(presentation: .hidden) == 0,
            "The hidden shell retained a divider hairline."
        )
        #expect(
            recorder.detailAppearances == detailAppearances,
            "Toggling the source list rebuilt the selected detail root."
        )
    }

    private func waitForSidebarShellGeometry(
        timeout: Duration = .seconds(2),
        pumpLayout: @escaping @MainActor () -> Void,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            pumpLayout()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        pumpLayout()
        return condition()
    }

    private func layoutSidebarShell(
        controller: NSHostingController<MacSidebarShellGeometryProbe>,
        window: NSWindow
    ) {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }
}

@MainActor
@Observable
private final class MacSidebarShellGeometryRecorder {
    var presentation = MacSidebarPresentation.visible
    var preferredWidth = Double(MacSidebarShellLayout.defaultWidth)
    var sidebarWidth: CGFloat = 0
    var detailWidth: CGFloat = 0
    var detailAppearances = 0
}

private struct MacSidebarShellGeometryProbe: View {
    @Bindable var recorder: MacSidebarShellGeometryRecorder

    var body: some View {
        GeometryReader { shellProxy in
            let compact = MacWindowLayout.sizeClass(
                forContentWidth: MacSidebarShellLayout.adaptiveDetailWidth(
                    forShellWidth: shellProxy.size.width,
                    preferredSidebarWidth: CGFloat(recorder.preferredWidth)
                )
            ) == .compact

            MacSidebarShell(
                presentation: recorder.presentation,
                preferredSidebarWidth: $recorder.preferredWidth
            ) {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        recorder.sidebarWidth = $0
                    }
            } detail: {
                MacAdaptiveNavigationHost(tab: .events, compact: compact) {
                    Color.clear
                        .onAppear { recorder.detailAppearances += 1 }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                            recorder.detailWidth = $0
                        }
                }
            }
        }
    }
}

@MainActor
@Suite("Compact Clickmap composition")
struct CompactClickmapCompositionTests {

    /// A compact Clickmap still owns one scroll view, but its initial viewport
    /// must answer the selected lens before asking someone to scroll past saved
    /// render navigation. This mounts the real screen and deterministic demo
    /// transport; the pixel assertion is about the rendered viewport, not an
    /// ordering constant or a copy of the production layout decision.
    @Test("selected depth outcome is fully visible before compact scrolling")
    func selectedDepthOutcomeIsInitiallyVisible() async throws {
        let model = MacAppModelFactory.makeModel(
            environment: [:],
            demoModeEnabled: true
        )
        await model.bootstrap()

        let root = NavigationStack {
            HeatmapsRoot()
        }
        .environment(model)
        .environment(
            \.horizontalSizeClass,
            MacWindowLayout.sizeClass(forContentWidth: 640)
        )

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setFrame(
            NSRect(x: 80, y: 80, width: 640, height: 480),
            display: false
        )
        window.orderBack(nil)
        defer { window.close() }

        var renderedText: [String] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            controller.view.layoutSubtreeIfNeeded()
            renderedText = try recognizedText(in: controller.view)
            if contains("No scroll-depth data", in: renderedText) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(
            contains("No scroll-depth data", in: renderedText),
            "The compact initial viewport clipped the selected depth outcome title. OCR: \(renderedText)"
        )
        #expect(
            contains("No clicks were recorded in this period", in: renderedText),
            "The compact initial viewport clipped the selected depth outcome explanation. OCR: \(renderedText)"
        )
    }

    private func contains(_ text: String, in recognized: [String]) -> Bool {
        recognized.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    private func recognizedText(in view: NSView) throws -> [String] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return []
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }
}

@Suite("Mac settings regrouping")
struct MacSettingsRegroupingTests {

    @Test("the four panes are the spec's four, in order")
    func paneTitles() {
        #expect(
            MacSettingsPane.allCases.map(\.title)
                == ["Account", "Display", "Refresh & Notifications", "Advanced"]
        )
    }

    /// Losing a section in the regrouping would be silent — the pane it left
    /// simply gets shorter — so coverage is pinned as set equality.
    @Test("every settings section kept exactly one home")
    func everySectionHasOneHome() {
        let placed = MacSettingsPane.allCases.flatMap(\.sections)
        #expect(Set(placed) == Set(SettingsSectionID.allCases))
        #expect(placed.count == SettingsSectionID.allCases.count)
    }
}

@MainActor
@Suite("Focused command values")
struct FocusedCommandValueTests {

    /// The closures the focus surface carries are `@MainActor` and
    /// non-`Sendable` by design, so a plain main-actor box is what records
    /// their effect — a captured `var` would not survive strict concurrency.
    @MainActor
    private final class Recorder {
        var openedTabs: [AppTab] = []
        var didRun = false
    }

    @Test("OpenTabAction forwards the tab it was handed")
    func openTabForwards() {
        let recorder = Recorder()
        let action = OpenTabAction { recorder.openedTabs.append($0) }
        action(.logs)
        #expect(recorder.openedTabs == [.logs])
    }

    @Test("ScreenRefreshAction runs the work it wraps")
    func refreshRuns() async {
        let recorder = Recorder()
        let action = ScreenRefreshAction { recorder.didRun = true }
        await action()
        #expect(recorder.didRun)
    }
}
