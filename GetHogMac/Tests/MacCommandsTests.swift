import Testing

@testable import GetHog

@Suite("Go menu layout")
struct GoMenuLayoutTests {

    /// The menu is the sidebar restated; a screen in one and not the other is a
    /// destination somebody cannot reach the way they expect.
    @Test("the Go menu mirrors the sidebar's sections exactly")
    func mirrorsSidebar() {
        let layout = GoMenuLayout.sections()
        #expect(layout.map(\.title) == AppTab.sections.map(\.title))
        #expect(
            layout.flatMap { $0.entries.map(\.tab) }
                == AppTab.sections.flatMap(\.tabs)
        )
    }

    @Test("⌘1–⌘9 belong to the first nine destinations, in sidebar order")
    func shortcutsAreTheFirstNine() {
        let entries = GoMenuLayout.sections().flatMap(\.entries)
        #expect(entries.compactMap(\.shortcut) == Array("123456789"))
        #expect(entries.prefix(GoMenuLayout.shortcutCount).allSatisfy { $0.shortcut != nil })
        #expect(entries.dropFirst(GoMenuLayout.shortcutCount).allSatisfy { $0.shortcut == nil })
    }

    /// ⌘1 is the landing tab. If a section reshuffle ever breaks this, the
    /// failure should be a decision, not a surprise.
    @Test("⌘1 goes home")
    func firstShortcutIsDashboards() {
        #expect(GoMenuLayout.sections().flatMap(\.entries).first?.tab == .dashboards)
    }

    /// The digits are positional, not a hand-tuned map — which is the whole
    /// reason the layout is derived. ⌘3 landing on Sessions is that rule's
    /// observable consequence today.
    @Test("⌘3 is the third destination the sidebar lists")
    func thirdShortcutIsSessions() {
        let entries = GoMenuLayout.sections().flatMap(\.entries)
        #expect(entries.first { $0.shortcut == "3" }?.tab == .sessions)
    }

    /// Flags leads the Experiment section, well past the ninth position, so it
    /// gets an item and no digit. Pinned because it looks like an omission and
    /// is the rule working.
    @Test("a screen past the ninth gets an item but no shortcut")
    func flagsHasAnItemWithoutADigit() {
        let entries = GoMenuLayout.sections().flatMap(\.entries)
        let flags = entries.first { $0.tab == .flags }
        #expect(flags != nil)
        #expect(flags?.shortcut == nil)
    }

    @Test("neither Search nor Settings gets a Go item")
    func utilityScreensStayOut() {
        let tabs = GoMenuLayout.sections().flatMap { $0.entries.map(\.tab) }
        #expect(!tabs.contains(.search))
        #expect(!tabs.contains(.settings))
    }

    @Test("every destination appears exactly once")
    func noDuplicates() {
        let tabs = GoMenuLayout.sections().flatMap { $0.entries.map(\.tab) }
        #expect(tabs.count == Set(tabs).count)
    }

    /// The numbering runs across sections rather than restarting inside each
    /// one, which is what makes "the nth thing the sidebar lists" a single
    /// unambiguous destination.
    @Test("position is counted across sections, not within them")
    func numberingIsGlobal() {
        let layout = GoMenuLayout.sections(
            from: [
                AppTabSection(title: "First", tabs: [.dashboards, .events]),
                AppTabSection(title: "Second", tabs: [.sessions, .flags]),
            ]
        )
        #expect(layout.flatMap { $0.entries.map(\.shortcut) } == ["1", "2", "3", "4"])
    }
}

@MainActor
@Suite("CSV export routing")
struct CSVExportRoutingTests {

    private var table: CSVExport {
        .table(title: "Example", rows: [["a", "b"], ["1", "2"]])
    }

    @Test("no table, no action — ⌘E stays disabled")
    func nilExport() {
        #expect(InsightCSVExportAction.routing(nil, through: CSVExportCoordinator()) == nil)
    }

    @Test("no coordinator, no action — a window without an exporter offers nothing")
    func nilCoordinator() {
        #expect(InsightCSVExportAction.routing(table, through: nil) == nil)
    }

    /// The same gate `CSVShareMenu` applies with `.disabled(export.isEmpty)`:
    /// exporting a header with no rows is offering a file that says nothing.
    @Test("an empty table is refused, matching the share menu")
    func emptyExport() {
        let empty = CSVExport.table(title: "Empty", rows: [["a", "b"]])
        #expect(InsightCSVExportAction.routing(empty, through: CSVExportCoordinator()) == nil)
    }

    @Test("the action carries the table it was built from")
    func passthrough() {
        let action = InsightCSVExportAction.routing(table, through: CSVExportCoordinator())
        #expect(action?.export.title == "Example")
        #expect(action?.export.rowCount == 1)
    }
}
