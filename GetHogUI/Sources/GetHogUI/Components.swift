import SwiftUI

/// Shown when an insight type isn't drawn on mobile yet.
///
/// A deliberate, tappable card beats a broken chart, and it makes the roadmap
/// self-evident inside the app.
public struct UnsupportedInsightCard: View {
    let kind: String
    var webURL: URL?

    public init(kind: String, webURL: URL? = nil) {
        self.kind = kind
        self.webURL = webURL
    }

    private var friendlyName: String {
        kind.replacingOccurrences(of: "Query", with: "")
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(Theme.Ink.tertiary)
            Text("\(friendlyName) insights aren't drawn on mobile yet")
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        .font(.footnote.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// A rounded card that hosts a dashboard tile or detail block.
///
/// Three things stack to make it read as a surface rather than a rectangle: a
/// fill, a hairline, and two shallow shadows. The hairline is load-bearing —
/// the grouped card colour is pure white in light mode, so on any screen not
/// using the grouped background the fill alone makes the card vanish — but on
/// its own it left everything looking like a wireframe. The shadows give the
/// edge somewhere to sit.
public struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    var elevation: Theme.Elevation = .card
    /// Draws a coloured spine down the leading edge.
    ///
    /// Lifted from PostHog's insight cards, and it earns its place: a wall of
    /// identical white rectangles gives the eye nothing to navigate by, and the
    /// stripe lets a tile be recognised by colour and position before a single
    /// word is read. It is chrome keyed to the *kind* of insight, never to a
    /// series — borrowing the data palette here would imply a relationship to
    /// the values that does not exist.
    var accent: Color?
    @ViewBuilder var content: Content

    public init(
        padding: CGFloat = Theme.Space.l,
        elevation: Theme.Elevation = .card,
        accent: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.elevation = elevation
        self.accent = accent
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The spine is painted into the card's background and clipped by
                // the card's own shape, so it can only ever exist where the card
                // does.
                //
                // It used to be an overlay clipping *itself* to a rounded rect of
                // `Theme.Radius.medium`. That looks right and is not: the clip
                // resolves in the spine's own 4pt-wide box, where SwiftUI clamps
                // a 16pt radius to half the smaller dimension — 2pt. So the spine
                // was a 4pt pill with 2pt corners held against a card curving
                // away at 16pt, and near the top and bottom edges it went on
                // painting at x ∈ [0, 4] after the card had already curved
                // inward. The result was a square nub of colour poking out past
                // each leading corner, on every accented card in the app.
                shape
                    .fill(Theme.cardBackground)
                    .overlay(alignment: .leading) {
                        if let accent {
                            accent
                                .frame(width: 4)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .compositingGroup()
            .shadow(
                color: elevation.ambient.color,
                radius: elevation.ambient.radius,
                y: elevation.ambient.y
            )
            .shadow(
                color: elevation.key.color,
                radius: elevation.key.radius,
                y: elevation.key.y
            )
    }
}

/// Formats large counts compactly (12.4K) for tiles and rows.
extension Double {
    public var compactFormatted: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// "1 user", "3 users", "12.4K sessions" — a count with its noun, agreed in
    /// number. Every impact line in the app used to print "1 users"; a client
    /// whose whole job is reporting counts cannot misdecline its counts.
    public func counted(_ noun: String) -> String {
        "\(compactFormatted) \(self == 1 ? noun : noun + "s")"
    }
}
