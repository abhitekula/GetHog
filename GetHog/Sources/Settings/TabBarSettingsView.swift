import SwiftUI

/// Which four product screens sit in the phone's tab bar.
///
/// **Two routes to any arrangement, and the second is scope rather than
/// polish.** Dragging is the obvious gesture and it is not available to every
/// input method, so each slot is also a menu of every screen: a reader using
/// Switch Control, Voice Control or a keyboard can reach any arrangement
/// without ever reordering by hand. `EditButton` supplies the drag half, which
/// also gives VoiceOver its own reorder action for free.
///
/// The fifth row is Search, drawn and disabled. Without it the screen shows four
/// slots against a bar of five, and "where did my fifth go" is the first
/// question it raises.
///
/// Phone-only, and `SettingsRoot` is what enforces that: on iPad the sidebar is
/// rearranged by SwiftUI's own Edit button and `NavPreferences` is not read at
/// all, so this screen has no route to it there.
struct TabBarSettingsView: View {
    @Environment(NavPreferences.self) private var nav

    var body: some View {
        List {
            Section {
                ForEach(Array(nav.barTabs.enumerated()), id: \.element) { index, tab in
                    slotRow(index: index, tab: tab)
                }
                .onMove { nav.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("In the tab bar")
            } footer: {
                Text("These four sit in the tab bar, in this order. Every other screen is reached from Search.")
            }

            Section {
                Label(AppTab.search.title, systemImage: AppTab.search.systemImage)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Search is always last. It's the only way to reach every screen that isn't in the bar, so it can't be moved out of it.")
            }

            Section {
                Button("Reset to default") { nav.reset() }
                    .disabled(nav.barTabs == AppTab.primary)
            }
        }
        .listStyle(.insetGrouped)
        .pageSurface()
        .navigationTitle("Tab bar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    /// One slot: what is in it, and a menu of everything that could be.
    private func slotRow(index: Int, tab: AppTab) -> some View {
        Menu {
            ForEach(AppTab.sections) { section in
                Section(section.title) {
                    ForEach(section.tabs, id: \.self) { candidate in
                        Button {
                            nav.assign(candidate, to: index)
                        } label: {
                            // A checkmark on the current one, the way
                            // `ProjectSwitcher` marks the current project.
                            if candidate == tab {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Label(candidate.title, systemImage: candidate.systemImage)
                            }
                        }
                        // A glyph inside a menu item is not announced, so the
                        // checkmark above is written out here — the same
                        // correction `ProjectSwitcher` records.
                        .accessibilityLabel(
                            candidate == tab ? "\(candidate.title), in this slot" : candidate.title
                        )
                    }
                }
            }
        } label: {
            // **The 44pt floor goes inside the label closure.** A borderless
            // `Menu`'s tap region is its *label's* bounds, so the same modifier
            // outside would silently just recentre the label and leave the
            // target undersized — measured, and recorded in `CLAUDE.md`.
            HStack {
                Label(tab.title, systemImage: tab.systemImage)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        // The slot number is spoken because the order *is* the setting: four
        // rows reading only their screen names would not say which is first.
        .accessibilityLabel("Slot \(index + 1): \(tab.title)")
        .accessibilityHint("Chooses which screen sits in this slot of the tab bar")
    }
}
