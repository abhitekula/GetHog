import Observation

/// Where a secondary screen keeps the detail it currently has open.
///
/// A secondary screen is hosted **twice**. Above the size-class boundary it is
/// a `Tab` of its own, because `sidebarSections` is declared only there; below
/// it, that `Tab` does not exist and the screen is a destination pushed on the
/// search tab's stack. Crossing the boundary swaps hosts, so SwiftUI builds
/// `TabRootView` — and every `@State` in the screen underneath it — from
/// scratch.
///
/// Moving between size classes rebuilds the secondary host. Without shared
/// state, the open detail disappears in both directions while primary tabs,
/// which retain one host, keep their selection. That localises the fault to the
/// double-hosting boundary rather than to split-view navigation itself.
///
/// This object is owned by `RootView`, which straddles the boundary, so the two
/// hosts can hand the open detail to each other. `AnyHashable` because every
/// screen in `AppTab.secondary` has a detail type of its own and this file must
/// not know any of them.
///
/// **One box, two presenters.** Every secondary screen keeps its open detail
/// here; what differs is who turns that value back into a visible screen.
///
/// * A screen that *pushes* presents it itself, with
///   `navigationDestination(item:)` bound to this box. The destination lives in
///   whichever stack currently hosts the screen, and it is rebuilt from the
///   value on the far side of a resize. Tearing down the stack does **not** write
///   `nil` through the item binding, so the value survives the host swap.
/// * A screen that shows a **sheet** cannot present it itself. A sheet is a
///   presented view controller, its dismissal is a real event, and the resize
///   dismisses it — writing `nil` back through whatever drove it and destroying
///   the record meant to survive. Those four screens only *write* here;
///   `RootView` does the presenting, from above the boundary, where nothing
///   tears the presentation down.
///
/// `level` exists for the one screen that nests: Groups pushes a group type and
/// then a group inside it, and both have to come back.
@MainActor
@Observable
final class OpenDetails {
    private struct Slot: Hashable {
        let tab: AppTab
        let level: Int
    }

    private var byTab: [Slot: AnyHashable] = [:]

    /// Dashboard range and inspector state crosses the same double-hosting
    /// boundary as the selected dashboard id. Keeping the sessions in this
    /// root-owned box lets both structural hosts resolve the same store after a
    /// resize instead of rebuilding Saved/no-inspector defaults.
    let dashboardStores = DashboardDetailStorePool()

    subscript(tab: AppTab) -> AnyHashable? {
        get { byTab[Slot(tab: tab, level: 0)] }
        set { byTab[Slot(tab: tab, level: 0)] = newValue }
    }

    /// A deeper push on the same screen. Level 0 is the screen's own detail and
    /// is what the subscript above reaches.
    subscript(tab: AppTab, level level: Int) -> AnyHashable? {
        get { byTab[Slot(tab: tab, level: level)] }
        set { byTab[Slot(tab: tab, level: level)] = newValue }
    }

    /// Ends the ownership of every project-bound selection and detail session.
    /// Called synchronously when the selected project becomes a different
    /// security scope, including the `project -> nil` leg of sign-out.
    func reset() {
        byTab.removeAll()
        dashboardStores.removeAll()
    }
}
