import SwiftUI

enum BrandObjectGlyph: String, CaseIterable, Equatable {
    case dashboard
    case generatedDashboard
    case event
    case screenEvent
    case exceptionEvent
    case featureFlagEvent
    case session
    case mobileSession
    case errorSession
    case flag
    case multivariateFlag
    case archivedFlag

    var product: BrandProductMark {
        switch self {
        case .dashboard, .generatedDashboard: .dashboard
        case .event, .screenEvent, .exceptionEvent, .featureFlagEvent: .event
        case .session, .mobileSession, .errorSession: .session
        case .flag, .multivariateFlag, .archivedFlag: .flag
        }
    }
}

struct BrandObjectGlyphView: View {
    let glyph: BrandObjectGlyph
    var size: CGFloat = 22
    var tint: Color = Theme.SignalChrome.teal

    var body: some View {
        ZStack(alignment: .topTrailing) {
            BrandProductMarkView(mark: glyph.product, size: size, tint: tint)
            modifier
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var modifier: some View {
        switch glyph {
        case .dashboard, .event, .session, .flag:
            EmptyView()
        case .generatedDashboard:
            QuillCuts(size: size * 0.34, tint: Theme.SignalChrome.coral)
        case .screenEvent:
            RoundedRectangle(cornerRadius: size * 0.06)
                .stroke(Theme.SignalChrome.clay, lineWidth: max(1, size * 0.07))
                .frame(width: size * 0.34, height: size * 0.27)
        case .exceptionEvent, .errorSession:
            Circle()
                .fill(Theme.Status.critical)
                .frame(width: size * 0.24, height: size * 0.24)
        case .featureFlagEvent, .multivariateFlag:
            Circle()
                .fill(Theme.SignalChrome.coral)
                .frame(width: size * 0.22, height: size * 0.22)
        case .mobileSession:
            Capsule()
                .stroke(Theme.SignalChrome.clay, lineWidth: max(1, size * 0.07))
                .frame(width: size * 0.20, height: size * 0.34)
        case .archivedFlag:
            Rectangle()
                .fill(Theme.SignalChrome.ink)
                .frame(width: size * 0.30, height: max(1.5, size * 0.08))
        }
    }
}
