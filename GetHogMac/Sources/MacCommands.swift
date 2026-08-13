import SwiftUI

/// The key window's one sidebar action. The binding is the scene-storage
/// location that draws the shell, so the command title and invocation cannot
/// become two snapshots of one window at different times.
struct MacSidebarToggleAction {
    let presentationRawValue: Binding<String>

    var presentation: MacSidebarPresentation {
        MacSidebarPresentation(rawValue: presentationRawValue.wrappedValue) ?? .visible
    }

    @MainActor func callAsFunction() {
        presentationRawValue.wrappedValue = presentation.toggled.rawValue
    }
}

extension FocusedValues {
    @Entry var macSidebarToggle: MacSidebarToggleAction?
}

/// How the Go menu lays itself out: `AppTab.sections`, in its own order, with
/// ⌘1–⌘9 on the first nine destinations it lists.
///
/// Derived rather than declared so the menu cannot drift from the sidebar —
/// `AppTab.sections` is the single source of truth for both, and this is
/// another of its consumers. A hand-tuned shortcut map was considered and
/// rejected: today the first nine are exactly the Analyze section, and the day
/// a section is reordered the digits follow `AppTab.sections` rather than a
/// list nobody remembers to edit. (Flags, leading the Experiment section,
/// therefore gets an item but no digit; that is the rule working, not an
/// omission.)
///
/// The digits count destinations in `AppTab.sections`, which is *not* the same
/// as counting rows down the Mac sidebar: `MacRootView` draws its loose Search
/// tab above the sections, so Search is the first row and ⌘1's Dashboards is
/// the second. Search is a utility surface with no Go item at all, so numbering
/// around it is the right answer — but the two orderings are offset by one and
/// the prose here should not pretend otherwise.
///
/// A type, not view code, so `GetHogMacTests` can pin the layout without
/// rendering a menu.
enum GoMenuLayout {

    /// How many leading destinations carry ⌘-digits.
    static let shortcutCount = 9

    struct Entry: Hashable, Identifiable {
        let tab: AppTab
        /// "1"–"9" for the first nine screens in `AppTab.sections` order, nil
        /// after.
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
        // destination in `AppTab.sections`", which is only one screen if the
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

/// The menu bar, reading the four key-window focus values named by the shared
/// command contracts and `MacSidebarToggleAction` above.
///
/// Items whose value is nil are disabled, never hidden: a window still
/// connecting, the Settings window, and a tear-off with nothing in focus all
/// read as "not now", which is what a grey menu item says. A menu that grew and
/// shrank instead would make the bar's shape a function of what happened to be
/// frontmost.
struct MacCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.openTab) private var openTab
    @FocusedValue(\.screenRefresh) private var screenRefresh
    @FocusedValue(\.insightCSVExport) private var insightCSVExport
    @FocusedValue(\.macSidebarToggle) private var macSidebarToggle

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                MacMenuBar.activateRegular()
                openWindow(id: MacSettingsWindow.id)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

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

        // `SidebarCommands` discovers a `NavigationSplitView` indirectly. Once
        // the source list became the outer structural column, it kept a stale
        // command state: a visible sidebar could advertise "Show Sidebar" and
        // clicking it addressed no rendered column. The focused key-window
        // action below is still the standard View ▸ sidebar command and
        // shortcut, but it reads the same per-window value that draws the
        // column, so its title cannot desynchronise.
        CommandGroup(replacing: .sidebar) {
            Button(macSidebarToggle?.presentation.commandTitle ?? "Show Sidebar") {
                macSidebarToggle?()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(macSidebarToggle == nil)
        }

        // View ▸ Show Toolbar / Customize Toolbar…, likewise sanctioned.
        //
        // Not optional here: `DashboardsRoot` and `SessionsRoot` both declare
        // `.toolbar(id:)` with customisable items, and without this group there
        // is no way at all to reach that customisation — measured, the View
        // menu carried no toolbar items and the toolbar's own context menu
        // offered only "Icon and Text" / "Icon Only". A customisable toolbar
        // nobody can customise is the declaration silently doing nothing.
        ToolbarCommands()

        CommandGroup(after: .toolbar) {
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
