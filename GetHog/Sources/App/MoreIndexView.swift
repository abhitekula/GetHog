import SwiftUI

/// The iPhone index of everything the tab bar cannot hold.
///
/// This replaces the "More" list SwiftUI generates for tabs past the fourth,
/// which cost the app twice over.
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
/// The stack belongs to `RootView` now and every destination is stack-less, so a
/// pushed screen draws exactly one bar. Putting the `TabSection`s back in
/// compact width is what regenerates that list, and the second bar with it.
struct MoreIndexView: View {
    @State private var search = ""

    var body: some View {
        List {
            if visibleSections.isEmpty && visibleUtility.isEmpty {
                EmptyStateView(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    message: "Nothing here is called “\(search)”."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleSections) { section in
                    Section {
                        ForEach(section.tabs, id: \.self) { row($0) }
                    } header: {
                        SectionLabel(text: section.title)
                    }
                }

                if !visibleUtility.isEmpty {
                    Section {
                        ForEach(visibleUtility, id: \.self) { row($0) }
                    }
                }
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle("More")
        .toolbar { ProjectSwitcher() }
        .projectSubtitle()
        .searchable(text: $search, prompt: "Search screens")
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
        AppTab.sections.compactMap { section in
            let tabs = matches(section.tabs)
            return tabs.isEmpty ? nil : AppTabSection(title: section.title, tabs: tabs)
        }
    }

    private var visibleUtility: [AppTab] { matches(AppTab.utility) }

    /// Filtered inside the groups rather than flattened into one result list.
    /// The group is what separates "Actions" the event definition from
    /// "Automation" the workflow, and a flat list of hits throws that away.
    private func matches(_ tabs: [AppTab]) -> [AppTab] {
        guard !search.isEmpty else { return tabs }
        return tabs.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
}
