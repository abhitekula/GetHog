import Foundation
import GetHogKit
import GetHogUI
import SwiftUI

struct SessionReplayMarker: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyAction
        case struggle
        case exception
    }

    let id: String
    let offset: TimeInterval
    let label: String
    let kind: Kind

    static func make(
        summary: ReplayVisionSummary?,
        duration: TimeInterval
    ) -> [Self] {
        guard let summary else { return [] }
        let upperBound = max(0, duration)
        var seenMilliseconds = Set<Int>()
        var pendingText = ""
        var markers: [Self] = []

        for segment in summary.summarySegments {
            switch segment {
            case .text(let text):
                pendingText += text
            case .citation(let milliseconds):
                guard seenMilliseconds.insert(milliseconds).inserted else {
                    pendingText = ""
                    continue
                }
                let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
                markers.append(Self(
                    id: "summary-citation-\(markers.count)",
                    offset: min(
                        upperBound,
                        max(0, TimeInterval(milliseconds) / 1_000)
                    ),
                    label: trimmed.isEmpty ? "Summary citation" : trimmed,
                    kind: .keyAction
                ))
                pendingText = ""
            case .unknown:
                continue
            }
        }

        return markers.sorted { left, right in
            left.offset == right.offset ? left.id < right.id : left.offset < right.offset
        }
    }

    static func active(in markers: [Self], at position: TimeInterval) -> Self? {
        activeIndex(in: markers, at: position).map { markers[$0] }
    }

    static func previous(in markers: [Self], before position: TimeInterval) -> Self? {
        guard let activeIndex = activeIndex(in: markers, at: position),
              activeIndex > markers.startIndex else { return nil }
        return markers[markers.index(before: activeIndex)]
    }

    static func next(in markers: [Self], after position: TimeInterval) -> Self? {
        guard let activeIndex = activeIndex(in: markers, at: position) else {
            return markers.first
        }
        let nextIndex = markers.index(after: activeIndex)
        guard nextIndex < markers.endIndex else { return nil }
        return markers[nextIndex]
    }

    static func accessibilityCountDescription(_ count: Int) -> String {
        "\(count) key \(count == 1 ? "event" : "events")"
    }

    private static func activeIndex(in markers: [Self], at position: TimeInterval) -> Int? {
        markers.lastIndex { $0.offset <= position }
    }
}

struct ReplayMarkerTrack: View {
    let markers: [SessionReplayMarker]
    let duration: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let usableWidth = max(0, proxy.size.width - 28)
            ZStack(alignment: .leading) {
                ForEach(markers) { marker in
                    Capsule()
                        .fill(tint(for: marker.kind))
                        .frame(width: 3, height: 12)
                        .offset(
                            x: 14 + usableWidth * marker.offset / max(duration, 1)
                        )
                }
            }
        }
        // A GeometryReader is maximally greedy on both axes and this one uses
        // the proxy for width alone — unconstrained, it claimed every free
        // point the expanded player's VStack had, splitting the screen 50/50
        // with the stage and marooning the scrubber in ~300pt of blank card.
        // The markers are 12pt tall; that is the track's height.
        .frame(height: 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tint(for kind: SessionReplayMarker.Kind) -> Color {
        switch kind {
        case .keyAction: Theme.accent
        case .struggle: Theme.accentWarm
        case .exception: Theme.Status.critical
        }
    }
}
