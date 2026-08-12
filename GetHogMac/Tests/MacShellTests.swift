import Testing

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
