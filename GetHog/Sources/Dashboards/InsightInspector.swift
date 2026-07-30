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
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tile.title)
                .font(.headline)
                .lineLimit(2)

            Spacer(minLength: 8)

            InsightShareMenu(title: tile.title, model: tile.renderModel)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close insight")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
    func insightDetail(tile: Binding<Tile?>, isWide: Bool) -> some View {
        modifier(InsightDetailPresentation(tile: tile, isWide: isWide))
    }
}

private struct InsightDetailPresentation: ViewModifier {
    @Binding var tile: Tile?
    let isWide: Bool


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
        } else {
            content.sheet(item: $tile) { tile in
                // The sheet has room for a real navigation bar, so it uses one
                // rather than the panel's hand-drawn header.
                NavigationStack {
                    SheetInsightDetail(tile: tile) { self.tile = nil }
                }
            }
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
