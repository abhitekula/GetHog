import Foundation
import GetHogKit
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
        detail: SessionSummaryDetail?,
        origin: Date?,
        duration: TimeInterval
    ) -> [Self] {
        guard let detail else { return [] }
        var seen = Set<String>()
        let upperBound = max(0, duration)

        return detail.chapters
            .flatMap(\.events)
            .compactMap { event -> Self? in
                let rawOffset: TimeInterval?
                if let origin, let timestamp = event.timestamp {
                    rawOffset = (timestamp.timeIntervalSince(origin) * 1_000).rounded() / 1_000
                } else {
                    rawOffset = event.offset
                }
                guard let rawOffset, rawOffset.isFinite else { return nil }
                guard seen.insert(event.id).inserted else { return nil }
                let label = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let kind: Kind = if event.exception != nil {
                    .exception
                } else if event.confusion == true || event.abandonment == true {
                    .struggle
                } else {
                    .keyAction
                }
                return Self(
                    id: event.id,
                    offset: min(upperBound, max(0, rawOffset)),
                    label: label.isEmpty ? (event.event ?? "Key event") : label,
                    kind: kind
                )
            }
            .sorted { left, right in
                left.offset == right.offset ? left.id < right.id : left.offset < right.offset
            }
    }

    static func active(in markers: [Self], at position: TimeInterval) -> Self? {
        markers.last { $0.offset <= position }
    }

    static func previous(in markers: [Self], before position: TimeInterval) -> Self? {
        guard let active = active(in: markers, at: position) else { return nil }
        return markers.last { $0.offset < active.offset - 0.001 }
    }

    static func next(in markers: [Self], after position: TimeInterval) -> Self? {
        markers.first { $0.offset > position + 0.001 }
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
