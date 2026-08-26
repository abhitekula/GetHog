import GetHogKit
import GetHogUI
import SwiftUI

/// One recording's current Replay Vision observation.
///
/// The full detail screen can spend space on intent, outcome and friction. The
/// sessions list deliberately does not use this view; it adds at most one line
/// to a row through `ReplayVisionSummaryDigest.cardSummary`.
struct SessionSummaryCard: View {
    let store: ReplayVisionSummaryStore
    var canSeek = false
    var onSeek: ((TimeInterval) -> Void)?
    var onGenerate: (() -> Void)?
    var onRetryLoad: (() -> Void)?
    var onRetryObservation: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header

                switch store.state {
                case .idle, .loading:
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Loading summary…")
                            .font(.footnote)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                case .absent:
                    SectionEmptyState(
                        text: "No summary has been generated for this session.",
                        systemImage: "text.badge.xmark",
                        actionTitle: onGenerate == nil ? nil : "Generate summary",
                        action: onGenerate
                    )
                case .generating:
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("PostHog is generating this session's summary…")
                            .font(.footnote)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                case .retryable(let observation):
                    SectionEmptyState(
                        text: "PostHog couldn't finish this summary.",
                        systemImage: "exclamationmark.triangle",
                        detail: observation.errorReason,
                        actionTitle: onRetryObservation == nil ? nil : "Retry summary",
                        action: onRetryObservation
                    )
                case .generationFailed(let message):
                    SectionEmptyState(
                        text: "Couldn't generate the summary.",
                        systemImage: "exclamationmark.triangle",
                        detail: message,
                        actionTitle: onGenerate == nil ? nil : "Try again",
                        action: onGenerate
                    )
                case .failed(let message):
                    SectionEmptyState(
                        text: "Couldn't load the summary for this session.",
                        systemImage: "exclamationmark.triangle",
                        detail: message,
                        actionTitle: onRetryLoad == nil ? nil : "Try again",
                        action: onRetryLoad
                    )
                case .loaded(let observation):
                    if let summary = observation.summary {
                        summaryBody(summary)
                    }
                }
            }
        }
        .accessibilityIdentifier("gethog.session-summary-card")
    }

    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SectionLabel(text: "Session summary", systemImage: "text.append")
                provenance
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                SectionLabel(text: "Session summary", systemImage: "text.append")
                Spacer(minLength: Theme.Space.s)
                provenance
            }
        }
    }

    @ViewBuilder
    private var provenance: some View {
        if let model = store.observation?.scannerSnapshot?.model, !model.isEmpty {
            Text(model)
                .font(.caption2)
                .typesettingLanguage(Locale.Language(identifier: "zxx"))
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
    }

    private func summaryBody(_ summary: ReplayVisionSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !summary.title.isEmpty {
                Text(summary.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.summary.isEmpty {
                Text(summary.summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.intent.isEmpty || !summary.outcome.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if !summary.intent.isEmpty {
                        labelledText("Intent", summary.intent)
                    }
                    if !summary.outcome.isEmpty {
                        labelledText("Outcome", summary.outcome)
                    }
                }
            }

            if summary.hasFriction {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label("Friction", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Status.ink(for: Theme.accentWarm))
                    ForEach(summary.frictionPoints, id: \.self) { point in
                        Text(point)
                            .font(.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if canSeek, let onSeek, !summary.citationOffsets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(Array(summary.citationOffsets.enumerated()), id: \.offset) { index, offset in
                            Button {
                                onSeek(offset)
                            } label: {
                                Label(
                                    SessionClock.offset(offset),
                                    systemImage: "play.circle"
                                )
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                                .minimumHitTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Play summary citation \(index + 1) at \(SessionClock.spoken(offset))"
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelledText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Ink.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
