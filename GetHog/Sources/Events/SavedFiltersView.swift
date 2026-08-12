import GetHogKit
import GetHogUI
import SwiftUI

/// Saving, recalling and curating sets of event search chips.
///
/// PostHog has no API for saved filters, so these live only on this device. The
/// store handles persistence and scoping; this file is only the controls.
struct SavedFiltersMenu: View {
    let projectID: Int?
    @Binding var tokens: [EventFilterToken]

    private let store = SavedEventFilterStore()

    @State private var saved: [SavedEventFilter] = []
    @State private var isNaming = false
    @State private var draftName = ""
    @State private var isManaging = false

    var body: some View {
        Menu {
            Button("Save current filters", systemImage: "bookmark") {
                draftName = ""
                isNaming = true
            }
            .disabled(tokens.isEmpty || projectID == nil)

            if !saved.isEmpty {
                Section("Saved") {
                    ForEach(saved) { filter in
                        Button(filter.name) { tokens = filter.tokens }
                    }
                }
                Button("Manage saved filters", systemImage: "slider.horizontal.3") {
                    isManaging = true
                }
            }
        } label: {
            Label("Saved filters", systemImage: "bookmark")
        }
        .accessibilityLabel("Saved filters")
        .task(id: projectID) { reload() }
        .alert("Name this filter set", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("^[\(tokens.count) filter](inflect: true) will be saved for this project only.")
        }
        .sheet(isPresented: $isManaging) {
            if let projectID {
                ManageSavedFiltersView(
                    projectID: projectID,
                    store: store,
                    filters: $saved
                )
            }
        }
    }

    private func reload() {
        guard let projectID else { return saved = [] }
        saved = store.filters(projectID: projectID)
    }

    private func save() {
        guard let projectID else { return }
        store.add(name: draftName, tokens: tokens, projectID: projectID)
        reload()
    }
}

/// Rename and delete, kept off the quick-apply menu.
///
/// A menu that both applies and destroys on tap is a mis-tap away from losing
/// something the user made, so editing lives behind its own sheet.
struct ManageSavedFiltersView: View {
    let projectID: Int
    let store: SavedEventFilterStore
    @Binding var filters: [SavedEventFilter]

    @Environment(\.dismiss) private var dismiss

    @State private var renaming: SavedEventFilter?
    @State private var renameText = ""
    @State private var pendingDeletion: SavedEventFilter?

    var body: some View {
        NavigationStack {
            Group {
                if filters.isEmpty {
                    EmptyStateView(
                        title: "No saved filters",
                        systemImage: "bookmark",
                        message:
                            "Add search chips on the Events screen, then choose Save current filters to keep them here."
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Saved filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename filter set", isPresented: isRenamingBinding) {
                TextField("Name", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            // A saved set is something the user wrote, not derived data, so it
            // never disappears on a single tap.
            .confirmationDialog(
                "Delete \(pendingDeletion?.name ?? "this filter set")?",
                isPresented: isConfirmingDeletionBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { commitDeletion() }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This only removes the saved set. Your events are untouched.")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(filters) { filter in
                DataRow(
                    glyph: "bookmark.fill",
                    title: filter.name,
                    subtitle: filter.tokens.map(\.displayText).joined(separator: " · "),
                    // The chip line truncates, so the count is spelled out here
                    // rather than left as a bare number on the trailing edge.
                    footnote: summary(filter),
                    // Chips read as `key: value`, and aligned keys are what make
                    // one saved set comparable with the next.
                    isSubtitleMonospaced: true,
                    // Nothing to push: applying a set happens from the menu that
                    // opened this sheet, not from the row.
                    accessory: .none
                )
                .listRowBackground(
                    Theme.cardBackground
                        .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                        .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
                )
                .listRowSeparator(.hidden)
                #if !os(tvOS)
                // `swipeActions` is unavailable on tvOS — there is nothing to
                // swipe. Nothing is lost: the context menu immediately below
                // carries the same Rename/Delete pair, and a long press on the
                // remote's select button is how it opens.
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        pendingDeletion = filter
                    }
                    Button("Rename", systemImage: "pencil") { beginRename(filter) }
                        .tint(Theme.accent)
                }
                #endif
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { beginRename(filter) }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        pendingDeletion = filter
                    }
                }
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
    }

    private func summary(_ filter: SavedEventFilter) -> String {
        let count = filter.tokens.count
        let chips = "\(count) filter\(count == 1 ? "" : "s")"
        return "\(chips) · saved \(filter.createdAt.formatted(.relative(presentation: .named)))"
    }

    // Alerts want a `Bool` binding while the payload lives in an optional, so
    // presentation is derived from whether that optional is set.
    private var isRenamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isConfirmingDeletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private func beginRename(_ filter: SavedEventFilter) {
        renameText = filter.name
        renaming = filter
    }

    private func commitRename() {
        guard let renaming else { return }
        store.rename(id: renaming.id, to: renameText, projectID: projectID)
        self.renaming = nil
        filters = store.filters(projectID: projectID)
    }

    private func commitDeletion() {
        guard let pendingDeletion else { return }
        store.delete(id: pendingDeletion.id, projectID: projectID)
        self.pendingDeletion = nil
        filters = store.filters(projectID: projectID)
    }
}
