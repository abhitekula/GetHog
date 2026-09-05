import Foundation
import Testing

@testable import GetHogUI

@Suite("Platform control metrics")
struct PlatformControlMetricsTests {
    @Test("pointer and touch floors stay exact")
    func inputFloors() {
        #expect(PlatformControlMetrics.pointerMinimumInteractiveLength == 28)
        #expect(PlatformControlMetrics.touchMinimumInteractiveLength == 44)
        #if os(macOS)
        #expect(PlatformControlMetrics.minimumInteractiveLength == 28)
        #else
        #expect(PlatformControlMetrics.minimumInteractiveLength == 44)
        #endif
    }

    @Test("interactive source uses the platform floor instead of a touch literal")
    func interactiveSourceHasNoLiteralTouchFloor() throws {
        let scan = try Self.literalFrames()
        let approved = Set([
            // Documentation of the measured broken outer-frame pattern, not executable UI.
            SourceLiteral(
                path: "GetHog/Sources/Alerts/InsightAlertsView.swift",
                source: ".frame(minHeight: 44)"
            ),
            // Read-only identity row; the combined accessibility element has no action.
            SourceLiteral(
                path: "GetHog/Sources/Insights/InsightDrillDown.swift",
                source: ".frame(minHeight: 44)"
            ),
            // The primary transport control deliberately remains the larger visual circle.
            SourceLiteral(
                path: "GetHog/Sources/Player/ReplayPlayerView.swift",
                source: ".frame(width: 44, height: 44)"
            ),
            // Decorative initials avatar, hidden from accessibility and never interactive.
            SourceLiteral(
                path: "GetHog/Sources/Sessions/SessionDetailView.swift",
                source: ".frame(width: 44, height: 44)"
            ),
            // Read-only heatmap cell; tvOS focus only scrolls it into view and invokes no action.
            SourceLiteral(
                path: "GetHogUI/Sources/GetHogUI/HogQLVisualizationView.swift",
                source: ".frame(width: 58, height: 44)"
            ),
        ])

        #expect(scan.sourceFileCount > 100, "only scanned \(scan.sourceFileCount) source files")
        #expect(
            scan.literals == approved,
            "Touch-floor literals require an explicit noninteractive or documentation allowlist; interactive controls use PlatformControlMetrics. Drift: \(scan.literals.symmetricDifference(approved))"
        )
    }

    private static func literalFrames() throws -> (literals: Set<SourceLiteral>, sourceFileCount: Int) {
        let roots = [
            repositoryRoot.appending(path: "GetHog/Sources"),
            repositoryRoot.appending(path: "GetHogUI/Sources"),
        ]
        var literals: Set<SourceLiteral> = []
        var sourceFileCount = 0
        let pattern = try NSRegularExpression(
            pattern: #"(?s)\.frame\([^)]*(?:minWidth|minHeight|width|height)\s*:\s*44[^)]*\)"#
        )
        for root in roots {
            let enumerator = try #require(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                "couldn't read \(root.path)"
            )
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                sourceFileCount += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in pattern.matches(in: text, range: range) {
                    guard let swiftRange = Range(match.range, in: text) else { continue }
                    let source = text[swiftRange]
                        .split(whereSeparator: \Character.isWhitespace)
                        .joined(separator: " ")
                    literals.insert(
                        SourceLiteral(
                            path: url.path.replacingOccurrences(
                                of: repositoryRoot.path + "/",
                                with: ""
                            ),
                            source: source
                        )
                    )
                }
            }
        }
        return (literals, sourceFileCount)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct SourceLiteral: Hashable, CustomStringConvertible {
    let path: String
    let source: String

    var description: String { "\(path): \(source)" }
}
