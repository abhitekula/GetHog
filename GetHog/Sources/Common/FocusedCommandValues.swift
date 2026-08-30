import SwiftUI

// The focus surface the Mac menu bar drives. Task 5's `Commands` read these
// three keys and nothing else; the names below are contract, not convention.
//
//   \.openTab          — published by MacRootView. Go menu (⌘1–⌘9).
//   \.screenRefresh    — published by every root screen through
//                        `screenRefreshable(_:)`, beside its `.refreshable`.
//                        View ▸ Refresh (⌘R); disabled while nil.
//   \.insightCSVExport — published by the insight detail surfaces
//                        (SavedInsightDetailView, the dashboard insight panel)
//                        and the two query tables (Events, the SQL console),
//                        all through `InsightCSVExportAction.routing`, closing
//                        over the window's CSVExportCoordinator.
//                        File ▸ Export CSV (⌘E); disabled while nil.
//
// Menu commands read focused values from the **key window only**, so a tear-off
// `WindowGroup(for: WindowTarget.self)` window publishes no `\.openTab` and no
// `\.screenRefresh`, and the items that read them are correctly disabled while
// one is frontmost. A dashboard tear-off with an insight panel open is the one
// exception: it *does* publish `\.insightCSVExport`, and the File and Edit
// items genuinely work there, because that scene attaches its own
// `insightCSVExporter()` for the save dialog to present from.
//
// Shared rather than Mac-only on purpose: the screens that publish
// `\.screenRefresh` and `\.insightCSVExport` are shared files, and a key that
// existed on one platform only would need an `#if` at every publication site.

/// Navigates the key window's shell to a tab, from a menu command.
struct OpenTabAction {
    let run: @MainActor (AppTab) -> Void

    init(_ run: @escaping @MainActor (AppTab) -> Void) {
        self.run = run
    }

    @MainActor func callAsFunction(_ tab: AppTab) { run(tab) }
}

/// The refresh the key window's frontmost screen would perform — the same
/// work as its `.refreshable`, reachable without a scroll gesture.
struct ScreenRefreshAction {
    let run: @MainActor () async -> Void

    init(_ run: @escaping @MainActor () async -> Void) {
        self.run = run
    }

    @MainActor func callAsFunction() async { await run() }
}

/// The focused insight's CSV, plus the two things a menu can do with it.
/// `save` routes through the window's own `CSVExportCoordinator` (the file
/// dialog must outlive the menu — see `Export.swift`); `copy` applies the
/// same pasteboard budget every other copy path does.
struct InsightCSVExportAction {
    let export: CSVExport
    let save: @MainActor () -> Void
    let copy: @MainActor () -> Void
}

extension InsightCSVExportAction {

    /// The action a screen publishes for its current table: the export, routed
    /// through the window's own coordinator.
    ///
    /// `nil` — which keeps File ▸ Export CSV disabled — when there is no table,
    /// when the table is empty (the same gate `CSVShareMenu` applies with
    /// `.disabled(export.isEmpty)`, because a header with no rows is a file
    /// that says nothing), or when this window never attached `csvExporter()`
    /// and a save would have nowhere to present.
    @MainActor
    static func routing(
        _ export: CSVExport?,
        through exporter: CSVExportCoordinator?
    ) -> InsightCSVExportAction? {
        guard let export, !export.isEmpty, let exporter else { return nil }
        return InsightCSVExportAction(
            export: export,
            save: { exporter.export(export) },
            copy: { exporter.copy(export) }
        )
    }
}

extension FocusedValues {
    @Entry var openTab: OpenTabAction?
    @Entry var screenRefresh: ScreenRefreshAction?
    @Entry var insightCSVExport: InsightCSVExportAction?
}

extension View {

    /// One closure, two entrances: the platform's pull-to-refresh and the Mac
    /// menu bar's View ▸ Refresh (⌘R), which reads `\.screenRefresh` from the
    /// key window. Publishing beside the gesture is the contract above — a
    /// screen cannot gain one entrance without the other, and the two can never
    /// disagree about what "refresh" means.
    ///
    /// Root screens only. A pushed or column detail that also published would
    /// put two values in one scene and leave ⌘R's target to focus-proximity
    /// resolution, which is not an answer a menu item may give. Details keep
    /// their plain `.refreshable`.
    ///
    /// The publication is inert on iOS, where nothing reads the key. That is
    /// the shared-key design recorded above, and it is why there is no `#if`
    /// at any of the call sites.
    ///
    /// Apply this before `.searchable`. Pull-to-refresh belongs to the scrolling
    /// content; wrapping the search modifier makes the refresh transform own
    /// navigation search chrome too, and its overscroll transition can briefly
    /// overlap that chrome with the first row.
    func screenRefreshable(_ action: @escaping @Sendable () async -> Void) -> some View {
        refreshable { await action() }
            .focusedSceneValue(\.screenRefresh, ScreenRefreshAction { await action() })
    }
}
