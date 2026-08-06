import GetHogUI
import SwiftUI

enum BrandProductMark: String, CaseIterable, Equatable {
    case dashboard
    case event
    case session
    case flag
    case projectStamp

    fileprivate var lines: [[CGPoint]] {
        switch self {
        case .dashboard:
            [
                [.init(x: 0.12, y: 0.80), .init(x: 0.88, y: 0.80)],
                [.init(x: 0.24, y: 0.70), .init(x: 0.43, y: 0.30)],
                [.init(x: 0.52, y: 0.70), .init(x: 0.72, y: 0.18)],
            ]
        case .event:
            [
                [.init(x: 0.08, y: 0.55), .init(x: 0.28, y: 0.55),
                 .init(x: 0.40, y: 0.22), .init(x: 0.56, y: 0.80),
                 .init(x: 0.70, y: 0.40), .init(x: 0.92, y: 0.40)],
            ]
        case .session:
            [
                [.init(x: 0.50, y: 0.08), .init(x: 0.77, y: 0.18),
                 .init(x: 0.92, y: 0.50), .init(x: 0.77, y: 0.82),
                 .init(x: 0.50, y: 0.92), .init(x: 0.23, y: 0.82),
                 .init(x: 0.08, y: 0.50), .init(x: 0.23, y: 0.18),
                 .init(x: 0.50, y: 0.08)],
            ]
        case .flag:
            [
                [.init(x: 0.25, y: 0.88), .init(x: 0.25, y: 0.16)],
                [.init(x: 0.27, y: 0.20), .init(x: 0.78, y: 0.28),
                 .init(x: 0.61, y: 0.46), .init(x: 0.80, y: 0.62),
                 .init(x: 0.27, y: 0.54)],
            ]
        case .projectStamp:
            []
        }
    }

    fileprivate var dots: [CGPoint] {
        switch self {
        case .session:
            [.init(x: 0.50, y: 0.26), .init(x: 0.68, y: 0.58), .init(x: 0.32, y: 0.58)]
        case .dashboard, .event, .flag, .projectStamp:
            []
        }
    }
}

struct BrandProductMarkView: View {
    let mark: BrandProductMark
    var size: CGFloat = 18
    var tint: Color = Theme.SignalChrome.teal

    var body: some View {
        ZStack {
            if mark == .projectStamp {
                Capsule(style: .continuous)
                    .fill(Theme.SignalChrome.clay.opacity(0.26))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(tint, lineWidth: max(1.5, size * 0.10))
                    }
                    .frame(width: size, height: size * 0.72)
                HStack(spacing: size * 0.22) {
                    Circle().frame(width: size * 0.11, height: size * 0.11)
                    Circle().frame(width: size * 0.11, height: size * 0.11)
                }
                .foregroundStyle(tint)
            } else {
                NormalizedMarkLines(lines: mark.lines)
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: max(1.5, size * 0.10),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                ForEach(Array(mark.dots.enumerated()), id: \.offset) { _, dot in
                    Circle()
                        .fill(tint)
                        .frame(width: size * 0.14, height: size * 0.14)
                        .position(x: dot.x * size, y: dot.y * size)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct NormalizedMarkLines: Shape {
    let lines: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        Path { path in
            for line in lines where line.count > 1 {
                path.move(to: scaled(line[0], in: rect))
                for point in line.dropFirst() {
                    path.addLine(to: scaled(point, in: rect))
                }
            }
        }
    }

    private func scaled(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }
}
