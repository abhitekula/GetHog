import SwiftUI

/// How the Go menu lays itself out: the sidebar's own sections, in the
/// sidebar's own order, with ⌘1–⌘9 on the first nine destinations listed.
///
/// Derived rather than declared so the menu cannot drift from the sidebar —
/// `AppTab.sections` is the single source of truth, and this is another of its
/// consumers. A hand-tuned shortcut map was considered and rejected: today the
/// first nine are exactly the Analyze section, and the day a section is
/// reordered the digits follow the sidebar rather than a list nobody remembers
/// to edit. (Flags, leading the Experiment section, therefore gets an item but
/// no digit; that is the rule working, not an omission.)
///
/// A type, not view code, so `GetHogMacTests` can pin the layout without
/// rendering a menu.
enum GoMenuLayout {

    /// How many leading destinations carry ⌘-digits.
    static let shortcutCount = 9

    struct Entry: Hashable, Identifiable {
        let tab: AppTab
        /// "1"–"9" for the first nine screens in sidebar order, nil after.
        let shortcut: Character?

        var id: AppTab { tab }
    }

    /// `MenuSection` rather than `Section`, which would collide with SwiftUI's
    /// own inside the `CommandMenu` below.
    struct MenuSection: Hashable, Identifiable {
        let title: String
        let entries: [Entry]

        var id: String { title }
    }

    static func sections(from sections: [AppTabSection] = AppTab.sections) -> [MenuSection] {
        // Counted across sections rather than within them: ⌘n means "the nth
        // destination the sidebar lists", which is only one screen if the
        // numbering never restarts.
        var position = 0
        return sections.map { section in
            MenuSection(
                title: section.title,
                entries: section.tabs.map { tab in
                    position += 1
                    return Entry(
                        tab: tab,
                        shortcut: position <= shortcutCount
                            ? Character("\(position)")
                            : nil
                    )
                }
            )
        }
    }
}

/// The menu bar, reading the three keys `FocusedCommandValues.swift` names as
/// contract.
///
/// Items whose value is nil are disabled, never hidden: a window still
/// connecting, the Settings window, and a tear-off with nothing in focus all
/// read as "not now", which is what a grey menu item says. A menu that grew and
/// shrank instead would make the bar's shape a function of what happened to be
/// frontmost.
struct MacCommands: Commands {
    @FocusedValue(\.openTab) private var openTab
    @FocusedValue(\.screenRefresh) private var screenRefresh
    @FocusedValue(\.insightCSVExport) private var insightCSVExport

    var body: some Commands {
        // File ▸ New Window (⌘N) is the system's own `WindowGroup` item; these
        // join it rather than replacing it, because the system's already opens
        // the right group. Export saves through the key window's
        // `CSVExportCoordinator`, whose file dialog outlives this menu — see
        // `Export.swift` for why that indirection is not optional.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export CSV…") { insightCSVExport?.save() }
                .keyboardShortcut("e")
                .disabled(insightCSVExport == nil)
        }

        // Edit ▸ Copy CSV, below the standard pasteboard commands: it is a
        // copy, and File is not where a Mac user looks for one. Routed through
        // the coordinator so an oversized table is refused with an explanation
        // rather than truncated — the same budget every other copy path pays.
        CommandGroup(after: .pasteboard) {
            Button("Copy CSV") { insightCSVExport?.copy() }
                .disabled(insightCSVExport == nil)
        }

        // View ▸ Toggle Sidebar (⌃⌘S), the sanctioned SwiftUI item.
        SidebarCommands()

        CommandGroup(after: .sidebar) {
            Button("Refresh") {
                guard let screenRefresh else { return }
                Task { await screenRefresh() }
            }
            .keyboardShortcut("r")
            .disabled(screenRefresh == nil)
        }

        CommandMenu("Go") {
            ForEach(GoMenuLayout.sections()) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        goItem(for: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func goItem(for entry: GoMenuLayout.Entry) -> some View {
        let button = Button(entry.tab.title) { openTab?(entry.tab) }
            .disabled(openTab == nil)
        if let shortcut = entry.shortcut {
            button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            button
        }
    }
}
