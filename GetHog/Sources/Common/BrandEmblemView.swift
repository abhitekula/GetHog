import SwiftUI

enum BrandEmblem: String, CaseIterable, Equatable {
    case analyze
    case monitor
    case data
    case experiment
    case workspace

    init?(sectionTitle: String) {
        switch sectionTitle {
        case "Analyze": self = .analyze
        case "Monitor": self = .monitor
        case "Data": self = .data
        case "Experiment": self = .experiment
        case "Workspace": self = .workspace
        default: return nil
        }
    }
}

/// A tiny, passive signature mark for each of GetHog's product families.
///
/// These intentionally use only SwiftUI geometry. They are visual wayfinding,
/// not controls, so interactive affordances continue to use familiar SF Symbols.
struct BrandEmblemView: View {
    let emblem: BrandEmblem
    var size: CGFloat = 16

    private var color: Color {
        switch emblem {
        case .analyze, .data, .workspace: Theme.accent
        case .monitor, .experiment: Theme.accentWarm
        }
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: max(1.5, size * 0.11),
            lineCap: .round,
            lineJoin: .round
        )
    }

    var body: some View {
        Group {
            switch emblem {
            case .analyze: analyze
            case .monitor: monitor
            case .data: data
            case .experiment: experiment
            case .workspace: workspace
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
    }

    private var analyze: some View {
        HStack(alignment: .bottom, spacing: size * 0.07) {
            ForEach([0.42, 0.68, 0.94], id: \.self) { proportion in
                Capsule(style: .continuous)
                    .frame(width: size * 0.19, height: size * proportion)
            }
        }
        .frame(width: size, height: size, alignment: .bottom)
    }

    private var monitor: some View {
        ZStack {
            Circle()
                .stroke(style: strokeStyle)
                .frame(width: size * 0.82, height: size * 0.82)

            Path { path in
                path.move(to: point(0.12, 0.55))
                path.addLine(to: point(0.38, 0.55))
                path.addLine(to: point(0.48, 0.28))
                path.addLine(to: point(0.60, 0.76))
                path.addLine(to: point(0.88, 0.45))
            }
            .stroke(style: strokeStyle)
        }
    }

    private var data: some View {
        ZStack {
            Path { path in
                path.move(to: point(0.35, 0.32))
                path.addLine(to: point(0.65, 0.32))
                path.move(to: point(0.50, 0.47))
                path.addLine(to: point(0.50, 0.64))
            }
            .stroke(style: strokeStyle)

            roundedSquare(x: 0.19, y: 0.17)
            roundedSquare(x: 0.66, y: 0.17)
            roundedSquare(x: 0.425, y: 0.65)
        }
    }

    private var experiment: some View {
        ZStack {
            Path { path in
                path.move(to: point(0.50, 0.82))
                path.addLine(to: point(0.50, 0.48))
                path.addLine(to: point(0.20, 0.20))
                path.move(to: point(0.50, 0.48))
                path.addLine(to: point(0.80, 0.20))
            }
            .stroke(style: strokeStyle)

            endpoint(x: 0.20, y: 0.20)
            endpoint(x: 0.80, y: 0.20)
            endpoint(x: 0.50, y: 0.82)
        }
    }

    private var workspace: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array([0.0, 0.10, 0.20].enumerated()), id: \.offset) { index, offset in
                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .fill(index == 2 ? color : color.opacity(0.34 + Double(index) * 0.18))
                    .frame(width: size * 0.68, height: size * 0.74)
                    .offset(x: size * offset, y: size * offset)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    private func roundedSquare(x: CGFloat, y: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
            .frame(width: size * 0.30, height: size * 0.30)
            .position(point(x, y))
    }

    private func endpoint(x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .frame(width: size * 0.18, height: size * 0.18)
            .position(point(x, y))
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: size * x, y: size * y)
    }
}
