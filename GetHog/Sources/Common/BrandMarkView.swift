import SwiftUI

/// GetHog's original brand mark, kept separate from functional interface icons.
struct BrandMarkView: View {
    let size: CGFloat
    var animatesEntrance = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .scaleEffect(animatesEntrance && !reduceMotion && !appeared ? 0.96 : 1)
            .onAppear {
                guard animatesEntrance, !reduceMotion else {
                    appeared = true
                    return
                }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    appeared = true
                }
            }
            .onDisappear {
                appeared = false
            }
            .accessibilityHidden(true)
    }
}
