import SwiftUI

// The focus surface the Mac menu bar drives. Task 5's `Commands` read these
// three keys and nothing else; the names below are contract, not convention.
//
//   \.openTab          — published by MacRootView. Go menu (⌘1–⌘9).
//   \.screenRefresh    — published by each screen beside its `.refreshable`
//                        (Task 5). View ▸ Refresh (⌘R); disabled while nil.
//   \.insightCSVExport — published by insight-detail surfaces closing over the
//                        window's CSVExportCoordinator (Task 5).
//                        File ▸ Export CSV (⌘E); disabled while nil.
//
// Menu commands read focused values from the **key window only**, so a tear-off
// `WindowGroup(for: WindowTarget.self)` window publishes none of these and the
// items that read them are correctly disabled while one is frontmost.
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

extension FocusedValues {
    @Entry var openTab: OpenTabAction?
    @Entry var screenRefresh: ScreenRefreshAction?
    @Entry var insightCSVExport: InsightCSVExportAction?
}
