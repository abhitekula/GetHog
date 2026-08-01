import SwiftUI

/// GetHog's original brand mark, kept separate from functional interface icons.
struct BrandMarkView: View {
    let size: CGFloat

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}
