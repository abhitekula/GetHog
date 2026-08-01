import SwiftUI

struct QuillCuts: View {
    var size: CGFloat = 14
    var tint: Color = Theme.SignalChrome.coral

    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(tint)
                    .frame(width: max(1.5, size * 0.13), height: size * 0.64)
                    .rotationEffect(.degrees(-18))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct BrandQuillStitch: View {
    var size: CGFloat = 14

    var body: some View {
        QuillCuts(size: size)
    }
}

struct SignalRule: View {
    var mark: BrandProductMark

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            BrandProductMarkView(mark: mark, size: 16)
            Rectangle()
                .fill(Theme.hairline)
                .frame(maxWidth: .infinity)
                .frame(height: 1)
            BrandQuillStitch(size: 12)
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}
