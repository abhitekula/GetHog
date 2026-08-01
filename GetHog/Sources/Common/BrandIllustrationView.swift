import SwiftUI

enum BrandIllustration: String, CaseIterable {
    case dashboard
    case insights
    case sessions
    case experiment
    case workspace
    case allClear

    var assetName: String {
        switch self {
        case .dashboard: "BrandEmptyDashboard"
        case .insights: "BrandEmptyInsights"
        case .sessions: "BrandEmptySessions"
        case .experiment: "BrandEmptyExperiment"
        case .workspace: "BrandEmptyWorkspace"
        case .allClear: "BrandAllClear"
        }
    }
}

struct BrandIllustrationView: View {
    let illustration: BrandIllustration
    var size: CGFloat = 152

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let motion = BrandMotionValues.illustration(
            reduceMotion: reduceMotion,
            appeared: appeared
        )

        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: size * 0.32,
                bottomLeadingRadius: size * 0.40,
                bottomTrailingRadius: size * 0.30,
                topTrailingRadius: size * 0.42,
                style: .continuous
            )
            .fill(Theme.accent.opacity(0.12))
            .rotationEffect(.degrees(-3))

            Image(illustration.assetName)
                .resizable()
                .scaledToFit()
                .padding(size * 0.04)
        }
        .frame(width: size, height: size * 0.84)
        .opacity(motion.opacity)
        .offset(y: motion.y)
        .scaleEffect(motion.scale)
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
        .onDisappear {
            appeared = false
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
