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

    /// Panel width. Wide enough for a legible chart plus its legend, narrow
    /// enough to leave the grid usable on an 11-inch iPad in portrait.
    private let panelWidth: CGFloat = 380

    func body(content: Content) -> some View {
        if isWide {
            HStack(spacing: 0) {
                content
                if let tile {
                    Divider()
                    InsightSidePanel(tile: tile) { self.tile = nil }
                        .frame(width: panelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.25), value: tile?.id)
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
