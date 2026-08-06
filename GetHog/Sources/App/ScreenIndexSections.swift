import GetHogUI
import SwiftUI

/// The app's own screens, as sections inside the search list.
///
/// This is what replaced the "More" list SwiftUI generates for tabs past the
/// fourth, which cost the app twice over.
///
/// It was a navigation stack in its own right, so each of the 24 destinations
/// behind it — every one of which carried a stack of its own — rendered **two**
/// navigation bars: one holding nothing but a back chevron, a second holding the
/// project switcher and the screen's actions, and only then the title. Measured
/// on device on Errors and on Web. That is the same row of chrome the project
/// name was moved out of the toolbar to reclaim (see `ScreenChrome`), spent
/// again on 24 of 28 screens.
///
/// And it was the one surface here that had never had a design pass: system
/// chrome on system grey, no `DataRow`, no project subtitle, and no way to
/// search 24 entries — which is the real cost, because scanning is what a list
/// this long charges you for.
///
/// It began as a screen of its own, `MoreIndexView`, with a search field over
/// those 24 names. It is sections now because the phone's tab bar holds five
/// items and search could not have a sixth: the index and the project search
/// share the fifth slot, and therefore share one field. Two fields that both
/// answer "find me the thing I want" is the redundancy that made the merge worth
/// doing rather than merely necessary.
///
/// Compact width only. The iPad sidebar lists every one of these screens itself,
/// so offering them again — and pushing them into the search tab's own stack,
/// where the sidebar would not follow — would be both duplication and a wrong
/// destination.
struct ScreenIndexSections: View {
    let query: String
    /// The screens that are in the tab bar, and therefore must not be listed
    /// here as well.
    ///
    /// Passed in rather than read from `NavPreferences` directly, so this view
    /// stays a pure function of what it is told and can be tested against an
    /// arrangement nobody has stored.
    let loose: [AppTab]

    var body: some View {
        ForEach(visibleSections) { section in
            Section {
                ForEach(section.tabs, id: \.self) { row($0) }
            } header: {
                // Every screen header carries the same glyph, and every object
                // header carries its own type's. That repetition is what tells a
                // reader at a glance which half of the results they are in.
                SectionLabel(
                    text: "\(section.title) screens",
                    systemImage: nil,
                    brandEmblem: BrandEmblem(sectionTitle: section.title)
                )
            }
        }

        if !visibleUtility.isEmpty {
            Section {
                ForEach(visibleUtility, id: \.self) { row($0) }
            } header: {
                SectionLabel(text: "App screens", systemImage: "macwindow")
            }
        }
    }

    private func row(_ tab: AppTab) -> some View {
        NavigationLink(value: tab) {
            // No accessory: a `NavigationLink` in a `List` draws its own
            // disclosure indicator, and `DataRow`'s would sit beside it.
            DataRow(glyph: tab.systemImage, title: tab.title, accessory: .none)
        }
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }

    // MARK: - Filtering

    private var visibleSections: [AppTabSection] {
        AppTab.groupedScreens(excluding: loose).compactMap { section in
            let tabs = Self.matching(section.tabs, query: query)
            return tabs.isEmpty ? nil : AppTabSection(title: section.title, tabs: tabs)
        }
    }

    private var visibleUtility: [AppTab] { Self.matching(AppTab.utility, query: query) }

    /// Whether this half of the list has anything in it, so the host can tell
    /// "no screens, but objects" from "nothing at all" and word the empty state
    /// for what was actually searched.
    /// Takes the same `loose` set the view does, and for the same reason: a
    /// screen in the tab bar is not in this list, so an empty state that counted
    /// it would claim a match the reader cannot see.
    static func hasMatches(query: String, loose: [AppTab]) -> Bool {
        let indexed = AppTab.groupedScreens(excluding: loose).flatMap(\.tabs) + AppTab.utility
        return !matching(indexed, query: query).isEmpty
    }

    /// Filtered inside the groups rather than flattened into one result list.
    /// The group is what separates "Actions" the event definition from
    /// "Automation" the workflow, and a flat list of hits throws that away.
    private static func matching(_ tabs: [AppTab], query: String) -> [AppTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tabs }
        return tabs.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }
}
