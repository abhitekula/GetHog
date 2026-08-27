import Foundation
import GetHogKit
import GetHogUI
import SwiftUI

struct SessionQuickPreviewPresentation: Equatable {
    let identity: String
    let startPath: String?
    let relativeStart: String
    let duration: String
    let activeTime: String
    let activity: String
    let source: String
    let playability: String
    let digest: String?

    init(recording: SessionRecording, digest: ReplayVisionSummaryDigest?) {
        identity = Self.identity(for: recording)
        startPath = Self.startPath(for: recording.startURL)
        relativeStart = recording.startTime?
            .formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            ?? "Unknown start time"
        duration = Self.clock(recording.recordingDuration)
        activeTime = Self.clock(recording.activeSeconds)
        activity = [
            Self.count(recording.clickCount, singular: "click"),
            Self.count(recording.keypressCount, singular: "keypress", plural: "keypresses"),
            Self.count(recording.consoleErrorCount, singular: "console error"),
        ].joined(separator: " · ")
        source = switch recording.snapshotSource?.lowercased() {
        case "web": "Web"
        case "mobile": "Mobile"
        default: "Unknown source"
        }
        playability = recording.isReplayable ? "Playable" : "Not playable"
        self.digest = Self.digest(from: digest)
    }

    var accessibilitySummary: String {
        var parts = [identity]
        if let startPath { parts.append("Start path \(startPath)") }
        parts.append(relativeStart)
        parts.append("Duration \(duration)")
        parts.append("Active time \(activeTime)")
        parts.append(activity)
        parts.append(source)
        parts.append(playability)
        if let digest { parts.append("Replay Vision. \(digest)") }
        return parts.joined(separator: ". ")
    }

    private static func identity(for recording: SessionRecording) -> String {
        let candidates = [
            recording.person?.name,
            recording.person?.distinctIDs?.first,
            recording.distinctID,
        ]
        return candidates.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? "Anonymous"
    }

    private static func startPath(for rawValue: String?) -> String? {
        guard let rawValue = singleLine(rawValue), !rawValue.isEmpty else { return nil }
        guard let url = URL(string: rawValue) else { return rawValue }
        if !url.path.isEmpty { return url.path }
        return url.host == nil ? rawValue : "/"
    }

    private static func clock(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = max(0, Int(seconds))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private static func count(
        _ value: Int,
        singular: String,
        plural: String? = nil
    ) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    private static func digest(from digest: ReplayVisionSummaryDigest?) -> String? {
        guard let digest else { return nil }
        if let summary = singleLine(digest.cardSummary), !summary.isEmpty {
            return summary
        }
        if let friction = singleLine(digest.frictionPoints.first), !friction.isEmpty {
            return "Friction: \(friction)"
        }
        if let outcome = singleLine(digest.outcome), !outcome.isEmpty {
            return "Outcome: \(outcome)"
        }
        return nil
    }

    private static func singleLine(_ value: String?) -> String? {
        value?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

struct SessionQuickPreview: View {
    let recording: SessionRecording
    let digest: ReplayVisionSummaryDigest?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: SessionQuickPreviewPresentation {
        SessionQuickPreviewPresentation(recording: recording, digest: digest)
    }

    var body: some View {
        QuickPreviewCard(
            title: presentation.identity,
            subtitle: presentation.startPath,
            systemImage: recording.isReplayable ? "play.rectangle" : "iphone",
            accessibilitySummary: presentation.accessibilitySummary
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(presentation.relativeStart, systemImage: "clock")
                    .font(.caption.monospaced())

                adaptiveFacts {
                    Label("Duration \(presentation.duration)", systemImage: "timer")
                    Label("Active \(presentation.activeTime)", systemImage: "figure.walk")
                }

                Text(presentation.activity)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)

                adaptiveFacts {
                    Label(presentation.source, systemImage: "display")
                    Label(
                        presentation.playability,
                        systemImage: recording.isReplayable ? "play.circle" : "play.slash"
                    )
                }

                if let digest = presentation.digest {
                    Divider()
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Label("Replay Vision", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(digest)
                            .font(.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityIdentifier("gethog.quick-preview.session.\(recording.id)")
    }

    private func adaptiveFacts<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let layout = if QuickPreviewLayout.factsAxis(for: dynamicTypeSize) == .vertical {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.m))
        }
        return layout { content() }
    }
}
