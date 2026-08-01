import SwiftUI

struct BrandMotionValues: Equatable {
    let opacity: Double
    let y: CGFloat
    let scale: CGFloat

    static func illustration(reduceMotion: Bool, appeared: Bool) -> BrandMotionValues {
        if reduceMotion || appeared {
            BrandMotionValues(opacity: 1, y: 0, scale: 1)
        } else {
            BrandMotionValues(opacity: 0, y: 8, scale: 0.98)
        }
    }
}

/// A decorative signal that accompanies the app's existing connection state.
/// The real `ProgressView` remains present and owns all loading semantics.
struct BrandConnectingAccent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(color(at: index))
                    .frame(width: 8, height: height(at: index))
                    .rotationEffect(.degrees(rotation(at: index)))
                    .scaleEffect(
                        x: 1,
                        y: reduceMotion || pulsing ? 1 : 0.72,
                        anchor: .bottom
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12),
                        value: pulsing
                    )
            }
        }
        .frame(width: 56, height: 30)
        .onChange(of: reduceMotion, initial: true) { _, newValue in
            pulsing = !newValue
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func height(at index: Int) -> CGFloat {
        [18, 24, 30][index]
    }

    private func rotation(at index: Int) -> Double {
        [-14, 0, 10][index]
    }

    private func color(at index: Int) -> Color {
        [Theme.accentWarm, Theme.Ink.tertiary, Theme.accent][index]
    }
}
