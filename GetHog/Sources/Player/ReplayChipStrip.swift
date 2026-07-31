import SwiftUI

/// The filter chips above the console and network panes, in a strip that says
/// when it has more in it.
///
/// The chips have always scrolled horizontally. What they did not do is admit
/// it: inside a `Card` the strip is bounded by the card's own padding, so the
/// last chip that fits is sliced off flush against an edge that looks like the
/// card's edge. Measured on the network pane at the default type size, with the
/// screen not scrolled and nothing overlapping it: `Documents` was cut through
/// the middle of its capsule, with no indicator, no fade and no bounce — a
/// control that is reachable and looks broken, which is worse than one that is
/// merely out of sight.
///
/// So the strip draws a short wash of the card's own colour over whichever end
/// still has content behind it. It is the standard idiom for the shape, it costs
/// no height in a card that has none to spare, and — because it is painted from
/// the background colour rather than masked — it cannot take a chip's tap
/// target with it.
///
/// Both panes' strips are built here rather than each configuring its own
/// `ScrollView`: they were already identical down to the 8pt spacing and the
/// hidden indicators, and a scroll affordance that only one of them has is the
/// same defect with a different filter above it.
struct ReplayChipStrip<Content: View>: View {
    /// What the wash fades from. The strips both sit on a card; a caller that
    /// puts one somewhere else has to say what it is standing on, because a
    /// gradient to the wrong colour is a smudge rather than an affordance.
    var background: Color = Theme.cardBackground
    @ViewBuilder var content: Content

    /// Wide enough to read as a fade rather than a hairline, narrow enough that
    /// the chip underneath is still legible and still obviously tappable.
    private static var fadeWidth: CGFloat { 24 }

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// How much of the strip is off-screen. Zero when everything fits, and the
    /// whole reason the fades are conditional: a strip of three chips on a wide
    /// phone has nothing hidden and must not imply that it does.
    private var overflow: CGFloat { max(contentWidth - containerWidth, 0) }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                content
            }
            .padding(.vertical, 1)
            // `onGeometryChange` rather than a `GeometryReader` writing state
            // from `onAppear`: it is coalesced into the layout pass that
            // produced the value, so a strip cannot spend a frame settling on
            // every appearance. Neither width feeds back into the layout — they
            // only decide whether a wash is drawn — so this cannot loop.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        // Measured rather than assumed, so the fade tracks the scroll: once the
        // reader has reached the end there is nothing behind that edge and the
        // wash would be claiming there is.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            offset = x
        }
        .overlay(alignment: .leading) { fade(.leading, visible: offset > 1) }
        .overlay(alignment: .trailing) {
            fade(.trailing, visible: overflow > 1 && offset < overflow - 1)
        }
    }

    private func fade(_ edge: HorizontalEdge, visible: Bool) -> some View {
        LinearGradient(
            colors: [background, background.opacity(0)],
            startPoint: edge == .leading ? .leading : .trailing,
            endPoint: edge == .leading ? .trailing : .leading
        )
        .frame(width: Self.fadeWidth)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible)
        // Chrome over a row of controls. It must never eat the tap that lands on
        // the chip it is drawn across.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
