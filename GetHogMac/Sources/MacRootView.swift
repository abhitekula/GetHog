import SwiftUI

/// Temporary macOS shell: the sidebar-adaptable skeleton over the shared
/// section model. Task 4 replaces the placeholders with the real screens and
/// the shared navigation state; this exists so the target has a launchable
/// root while the seams settle.
struct MacRootView: View {
    @State private var selection: AppTab = .dashboards

    /// Injected now, before any real screen arrives, because ~25 shared
    /// screens read it non-optionally and the first one Task 4 mounts would
    /// otherwise trap.
    @State private var openDetails = OpenDetails()

    var body: some View {
        TabView(selection: $selection) {
            sidebarSections
            tabItems(for: AppTab.utility)
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(openDetails)
    }

    /// Written as `@TabContentBuilder<AppTab>` members rather than inline, for
    /// the reason `RootView` writes its own that way: the builder cannot infer
    /// one tab value type across a `ForEach` of sections and a `ForEach` of
    /// loose tabs, and naming it is what keeps the two shapes one `TabView`.
    @TabContentBuilder<AppTab>
    private var sidebarSections: some TabContent<AppTab> {
        ForEach(AppTab.sections) { section in
            TabSection(section.title) {
                tabItems(for: section.tabs)
            }
        }
    }

    @TabContentBuilder<AppTab>
    private func tabItems(for tabs: [AppTab]) -> some TabContent<AppTab> {
        ForEach(tabs, id: \.self) { tab in
            Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                placeholder(for: tab)
            }
        }
    }

    private func placeholder(for tab: AppTab) -> some View {
        ContentUnavailableView(
            tab.title,
            systemImage: tab.systemImage,
            description: Text("The macOS shell arrives in a later task.")
        )
    }
}
