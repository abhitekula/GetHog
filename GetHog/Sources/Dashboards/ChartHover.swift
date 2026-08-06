import Charts
import GetHogKit
import SwiftUI

#if os(macOS)

// MARK: - Hover scrubbing (continuous forms)

/// Pointer scrubbing for a date-axis chart — the Mac spelling of
/// `.chartXSelection`.
///
/// Hover writes the same binding the iOS touch drag writes, so everything
/// downstream — nearest-point resolution, rule mark, readout, drill — is one
/// code path with two front doors, and the tooltip a hover shows is the
/// readout a finger reaches, byte for byte. Three deliberate choices:
///
/// - **The plot frame is the boundary.** `ChartScrubMath.plotX` rejects
///   locations over the axis labels, the legend, or the scale padding, where
///   a scrub would resolve to a point nobody is pointing at.
/// - **The last value persists when the pointer exits** — `.ended` clears
///   nothing. That mirrors the touch path, where a selection outlives the
///   finger that made it, and it is load-bearing for the drill affordance:
///   reaching the readout button means leaving the plot, and a tooltip that
///   dies on exit takes the button with it.
/// - **No snapping before storing.** The stored date is the pointer's own,
///   continuous; `selectedPoints` snaps to the nearest sample exactly as it
///   does for touch. Snapping twice would let the two paths disagree at the
///   margins.
private struct ChartHoverSelection: ViewModifier {
    @Binding var selection: Date?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    // Not an element: a clear rectangle over every chart
                    // would otherwise be a stop on the VoiceOver tour. The
                    // chart's own descriptor is the accessible reading, and
                    // the rotor needs no pointer.
                    .accessibilityHidden(true)
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase,
                              let anchor = proxy.plotFrame,
                              let x = ChartScrubMath.plotX(of: location, in: geo[anchor])
                        else { return }
                        let hovered = proxy.value(atX: x, as: Date.self)
                        // Hover fires per pixel; only real changes may touch
                        // the state a whole chart subtree re-renders from.
                        if hovered != selection { selection = hovered }
                    }
            }
        }
    }
}

extension View {
    /// Hover-driven twin of `.chartXSelection(value:)` for macOS call sites.
    func chartHoverSelection(_ selection: Binding<Date?>) -> some View {
        modifier(ChartHoverSelection(selection: selection))
    }
}
#endif

// MARK: - Hover highlighting (discrete forms)

/// Hover emphasis for a discrete chart row — a funnel step. A quiet wash
/// behind the row on macOS; identity on iOS, where there is no resting
/// pointer to answer and iPad pointer emphasis belongs to `hoverEffect` on
/// the row's own button.
///
/// `.quaternary`, not a palette hue: hover is chrome, and this app's chrome
/// stays monochrome — colour is reserved for series and status. The same
/// hierarchical style already draws every capsule track in this module.
struct ChartHoverHighlightModifier: ViewModifier {
    #if os(macOS)
    @State private var isHovered = false
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        // The rows are set flush; a wash that hugs the text
                        // reads as a rendering artifact rather than a state.
                        .padding(-Theme.Space.xs)
                }
            }
            .onHover { isHovered = $0 }
        #else
        content
        #endif
    }
}

/// Hover emphasis for a tinted cell — a retention cell — where a wash behind
/// it would vanish into its own fill: a hairline of `.primary` around the
/// hovered cell instead, legible over every step of the ramp in both modes.
struct ChartHoverOutlineModifier: ViewModifier {
    var cornerRadius: CGFloat = 3

    #if os(macOS)
    @State private var isHovered = false
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.4), lineWidth: 1)
                }
            }
            .onHover { isHovered = $0 }
        #else
        content
        #endif
    }
}

extension View {
    /// macOS hover highlight for a discrete chart row; no-op on iOS.
    func chartHoverHighlight() -> some View {
        modifier(ChartHoverHighlightModifier())
    }

    /// macOS hover outline for a filled cell; no-op on iOS.
    func chartHoverOutline(cornerRadius: CGFloat = 3) -> some View {
        modifier(ChartHoverOutlineModifier(cornerRadius: cornerRadius))
    }
}
