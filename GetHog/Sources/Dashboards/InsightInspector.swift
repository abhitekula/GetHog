import GetHogKit
import SwiftUI

/// Insight detail shown beside a dashboard rather than over it.
///
/// This started as SwiftUI's `.inspector`, which is the obvious fit and was in
/// the plan. On iOS 18.2 it presents as a dimming modal overlay on iPad instead
/// of taking a column — verified on an 11-inch and a 13-inch iPad, attached to
/// the detail column, to the `NavigationSplitView` itself, and to a bare
/// `NavigationStack` with no tab bar around it. All four dimmed the grid and
/// clipped the tile underneath, which is precisely what a side panel is for
/// avoiding. An explicit split is duller but it actually sits beside the data.
struct InsightSidePanel: View {
    let tile: Tile
    let onClose: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            InsightDetailBody(tile: tile, webURL: webURL)
        }
        .background(Theme.pageBackground)
    }

    /// Drawn by hand rather than by a nested `NavigationStack`.
    ///
    /// A stack here hoisted its own toolbar items into the dashboard's
    /// navigation bar and pushed the dashboard's title out of it, leaving the
    /// panel with no header and the grid with no name.
    ///
    /// Centre-aligned rather than on the first text baseline, which is what it
    /// was while the controls were bare glyphs the size of a word. Both are now
    /// 44pt boxes, and hanging a 44pt box off a baseline sets the row's height
    /// from the gap between the glyph's baseline and the title's rather than
    /// from either of them — taller than the controls, and taller again when a
    /// long insight name wraps to its second line.
    private var header: some View {
        HStack(spacing: 8) {
            Text(tile.title)
                .font(.headline)
                // An insight's name off the API, not prose, so a hyphen invented
                // here would misstate what the tile is called. `zxx` is the ISO
                // code for "no linguistic content"; same idiom as `SectionLabel`
                // and the scope chips.
                //
                // **A guard, and the honest scope of it.** This was briefed as
                // the site where `My App Dashboard` sets as `My App` /
                // `Dashboar` / `d`. Not reproduced: rendered through
                // `ImageRenderer` in this header's exact configuration —
                // `.font(.headline)`, `.lineLimit(2)` — and swept from 90pt to
                // 420pt at five type sizes up to AX5, the `zxx` and non-`zxx`
                // renders of that string are **byte-identical at every point**.
                // A title with a space in it breaks at the space, and the
                // `lineLimit(2)` truncates the tail rather than hyphenating it.
                // `Daily active users (DAUs)`, the demo fixture's title, differs
                // at exactly one width in the whole sweep (110pt at AX5), which
                // is far narrower than this panel is ever granted.
                //
                // What the same sweep does show is the case this is here for: a
                // **single long token**, which is what an insight named
                // `weekly_active_users` or `UnhandledRejection` is. In this
                // header's configuration that string hyphenates across the whole
                // 90–420pt band at AX3 and AX5, and across 90–160pt at the
                // default size. So the modifier is not decorative — it is just
                // not observable on the title the demo happens to carry.
                .typesettingLanguage(Locale.Language(identifier: "zxx"))
                .lineLimit(2)

            Spacer(minLength: 8)

            InsightShareMenu(title: tile.title, model: tile.renderModel)

            // The glyph is the whole button, so without a frame the tap target
            // *is* the glyph: measured from the running app on iPad, this
            // accessibility frame was 19.0 × 19.0 against a 44 × 44 HIG minimum.
            // It is also the panel's only dismissal — there is no swipe and no
            // background tap, because the panel sits in a split beside the grid
            // rather than over it — so a miss is not a retry, it is a reader
            // stuck on one insight.
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close insight")
        }
        .padding(.horizontal, 16)
        // The controls bring their own 44pt height now, so the padding only has
        // to keep the row off the title bar above and the divider below.
        .padding(.vertical, 6)
    }

    private var webURL: URL? {
        guard let insight = tile.insight else { return nil }
        return model.webURL(path: "insights/\(insight.id)")
    }
}

/// Sheet presentation, which resolves the insight's web URL the same way the
/// panel does.
private struct SheetInsightDetail: View {
    let tile: Tile
    let onClose: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        InsightDetailView(tile: tile, webURL: webURL, onClose: onClose)
            // Its own exporter, not the one at the window root. This screen is
            // presented as a sheet on iPhone, and asking the root to raise a
            // file picker over a live sheet is a nested presentation SwiftUI can
            // simply decline — the menu item would do nothing at all.
            .insightCSVExporter()
    }

    private var webURL: URL? {
        guard let insight = tile.insight else { return nil }
        return model.webURL(path: "insights/\(insight.id)")
    }
}

extension View {
    /// Presents insight detail the way the width allows: beside the content when
    /// there is room, as a sheet when there isn't.
    ///
    /// The compact branch is a sheet rather than a push because the grid is not
    /// a list — there is no navigation stack here to push onto, and a modal
    /// keeps the tile the user tapped one dismissal away.
    ///
    /// `namespace` is the grid's, not this modifier's: see `tileTransition`.
    func insightDetail(tile: Binding<Tile?>, isWide: Bool, in namespace: Namespace.ID) -> some View {
        modifier(InsightDetailPresentation(tile: tile, isWide: isWide, namespace: namespace))
    }
}

private struct InsightDetailPresentation: ViewModifier {
    @Binding var tile: Tile?
    let isWide: Bool
    /// Where the grid registered its tiles as transition sources.
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isWide {
            // Still a hand-rolled split, and `.inspector` is still not usable
            // here.
            //
            // Re-tested on **iPadOS 26** after raising the deployment floor,
            // because the original rejection was measured on iOS 18.2 and it
            // seemed likely to have been fixed. It has not: `.inspector` again
            // presented as a dimming overlay *on top of* the grid, greying the
            // tiles and clipping them mid-chart, rather than taking a column
            // beside them. Same failure, two OS generations apart.
            //
            // What did change is the squeeze this split used to cause. The grid
            // no longer collapses to an unreadable strip, because
            // `MasonryLayout` now derives its column count from the width it is
            // granted, and the sidebar collapses while the panel is open — see
            // `insightPanelOpen`.
            HStack(spacing: 0) {
                content
                if let tile {
                    Divider()
                    InsightSidePanel(tile: tile) { self.tile = nil }
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.25), value: tile?.id)
            // Lets the enclosing split view give up its sidebar while an
            // insight is open: on an 11-inch iPad the sidebar and the panel
            // cannot both be afforded, and the dashboard list is the one you do
            // not need while reading a single chart.
            .preference(key: InsightPanelOpenKey.self, value: tile != nil)
            // No zoom on this branch, and no attempt to build one. A zoom
            // transition is a property of a *presentation* — a push, a sheet, a
            // full-screen cover — and this branch presents nothing: the panel is
            // a second view in an `HStack`, deliberately, because everything that
            // does present here dims and clips the grid it is supposed to sit
            // beside. Reshaping that into a presentation to earn an animation
            // would trade the layout for the effect.
        } else {
            content.sheet(item: $tile) { tile in
                // The sheet has room for a real navigation bar, so it uses one
                // rather than the panel's hand-drawn header.
                zoomed(from: tile.id) {
                    NavigationStack {
                        SheetInsightDetail(tile: tile) { self.tile = nil }
                    }
                }
            }
        }
    }

    /// The destination half of the zoom, when the reader wants motion.
    ///
    /// Two branches rather than a ternary because there is no ternary to write:
    /// `.zoom(sourceID:in:)` and `.automatic` are different concrete
    /// `NavigationTransition` types, so the choice has to be made in the view
    /// tree and not in the argument.
    ///
    /// Reduce Motion drops back to the sheet's own slide, which is what this
    /// screen did before and is still a transition — the setting asks for less
    /// motion, not for none, and a detail that simply appeared would lose the
    /// spatial cue rather than soften it. This matches how the rest of the app
    /// reads the same setting: `InsightChartView` passes `nil` to `.animation`
    /// for its zoom and selection, and `ReplayPlayerView` turns the player's
    /// mouse tail off, in both cases leaving the underlying change in place.
    @ViewBuilder
    private func zoomed(from sourceID: Int, @ViewBuilder content: () -> some View) -> some View {
        if reduceMotion {
            content()
        } else {
            content().navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}

/// Reports upward that an insight panel is open beside the grid.
///
/// A preference rather than shared state because the two views are on opposite
/// sides of a `NavigationSplitView`: the panel is owned deep inside the detail
/// column, and the sidebar it needs to displace is owned by the root. Threading
/// a binding down through the dashboard list to get there would couple the list
/// to a panel it knows nothing about.
struct InsightPanelOpenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
