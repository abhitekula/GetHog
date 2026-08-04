import GetHogKit
import SwiftUI

/// What the iPad detail pane shows before a recording is picked.
///
/// Replaces `ContentUnavailableView("Select a session")`, which held two thirds
/// of an 11-inch canvas — the largest surface in the app spent on a sentence.
///
/// **Cost:** nothing. The page of recordings is already in memory, and every
/// figure here is folded out of it; the rate-limit budget is organisation-wide
/// and an unasked-for summary must not spend any of it.
///
/// Everything is scoped to that page and says so. This screen loads 50
/// recordings, not the project's whole replay history, and a figure captioned
/// "sessions" that silently meant "the 50 we happen to hold" would be a lie
/// wearing an aggregate's clothes.
struct SessionsOverview: View {
    let recordings: [SessionRecording]
    let loadedAt: Date?
    /// The open recording's id. Matches `SessionsRoot.selectedID`.
    @Binding var selection: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var facts: SessionOverviewFacts {
        SessionOverviewFacts(recordings: recordings)
    }

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            summaryScene
            triageSection
            entrySection
            FreshnessLabel(date: loadedAt)
        }
    }

    // MARK: - Sections

    private var summaryScene: some View {
        Card(accent: Theme.SignalChrome.clay) {
            summaryLayout
        }
        .accessibilityIdentifier("gethog.signal-summary.sessions")
        .signalConfirmation(trigger: loadedAt)
    }

    @ViewBuilder
    private var summaryLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            compactSummary
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.xxl) {
                    replayIdentity
                    replayMetrics.frame(maxWidth: .infinity, alignment: .leading)
                }
                compactSummary
            }
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            replayIdentity
            SignalRule(mark: .session)
            replayMetrics
        }
    }

    private var replayIdentity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Replay signal", productMark: .session)

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            Text("Across the \(facts.recordingCount) recordings loaded, not the whole project.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private var replayMetrics: some View {
        StatStrip {
            MetricTile(label: "Recordings", value: "\(facts.recordingCount)", compact: true)
            MetricTile(label: "With errors", value: "\(facts.withErrorCount)", compact: true)
            MetricTile(label: "Total time", value: facts.totalDurationText, compact: true)
            // Stated up front rather than discovered one failed load at a
            // time: mobile-source recordings cannot be played by this app at
            // all, and on a mobile-heavy project that is most of the list.
            if facts.notPlayableCount > 0 {
                MetricTile(
                    label: "Not playable",
                    value: "\(facts.notPlayableCount)",
                    compact: true
                )
            }
        }
        .padding(.horizontal, -Theme.Space.l)
    }

    @ViewBuilder
    private var triageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Worth watching", systemImage: "exclamationmark.triangle.fill")

            if facts.withErrors.isEmpty {
                // A clean page is the outcome everyone wants, so it is said as a
                // fact rather than left as an empty gap the reader has to
                // interpret as either "nothing wrong" or "nothing loaded".
                Card {
                    Label(
                        "No console errors in the recordings loaded.",
                        systemImage: "checkmark.circle"
                    )
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("Recordings that logged console errors, noisiest first.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: Theme.Space.s) {
                    ForEach(facts.withErrors) { recording in
                        recordingRow(recording)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var entrySection: some View {
        if !facts.entryPaths.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Where sessions start", systemImage: "arrow.right.to.line")

                VStack(spacing: Theme.Space.s) {
                    ForEach(facts.entryPaths, id: \.path) { entry in
                        Card(padding: Theme.Space.m) {
                            DataRow(
                                glyph: "link",
                                brandGlyph: .session,
                                title: entry.path,
                                footnote: entry.count == 1
                                    ? "1 recording" : "\(entry.count) recordings",
                                accessory: .metric("\(entry.count)")
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func recordingRow(_ recording: SessionRecording) -> some View {
        Button {
            selection = recording.id
        } label: {
            Card(padding: Theme.Space.m) {
                DataRow(
                    glyph: "exclamationmark.triangle.fill",
                    brandGlyph: SessionBrandAppearance.glyph(
                        hasErrors: recording.hasErrors,
                        isReplayable: recording.isReplayable
                    ),
                    tint: Theme.Status.critical,
                    title: recording.personDisplayName,
                    subtitle: recording.pathComponent,
                    footnote: footnote(recording),
                    isSubtitleMonospaced: true,
                    accessory: .metric("\(recording.consoleErrorCount)")
                )
            }
        }
        .buttonStyle(.plain)
        .pointerHighlight(cornerRadius: Theme.Radius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary(recording))
    }

    private func footnote(_ recording: SessionRecording) -> String {
        var parts = [recording.durationText, "\(recording.clickCount) clicks"]
        if !recording.isReplayable { parts.append("Mobile, not playable") }
        if let start = recording.startTime {
            parts.append(start.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        return parts.joined(separator: " · ")
    }

    private func spokenSummary(_ recording: SessionRecording) -> String {
        var parts = [
            recording.personDisplayName,
            "\(recording.consoleErrorCount) console errors",
            "duration \(recording.durationText)",
        ]
        if !recording.isReplayable { parts.append("mobile recording, not playable") }
        return parts.joined(separator: ", ")
    }

}
