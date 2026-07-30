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
    @Binding var selection: SessionRecording?

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            header
            triageSection
            entrySection
            FreshnessLabel(date: loadedAt)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Session replay", systemImage: "rectangle.stack")

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip {
                MetricTile(label: "Recordings", value: "\(recordings.count)", compact: true)
                MetricTile(label: "With errors", value: "\(withErrors.count)", compact: true)
                MetricTile(label: "Total time", value: totalDurationText, compact: true)
                // Stated up front rather than discovered one failed load at a
                // time: mobile-source recordings cannot be played by this app at
                // all, and on a mobile-heavy project that is most of the list.
                if notPlayable > 0 {
                    MetricTile(label: "Not playable", value: "\(notPlayable)", compact: true)
                }
            }
            .padding(.horizontal, -Theme.Space.l)

            Text("Across the \(recordings.count) recordings loaded, not the whole project.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var triageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Worth watching", systemImage: "exclamationmark.triangle.fill")

            if withErrors.isEmpty {
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
                    ForEach(withErrors) { recording in
                        recordingRow(recording)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var entrySection: some View {
        if !entryPaths.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Where sessions start", systemImage: "arrow.right.to.line")

                VStack(spacing: Theme.Space.s) {
                    ForEach(entryPaths, id: \.path) { entry in
                        Card(padding: Theme.Space.m) {
                            DataRow(
                                glyph: "link",
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
            selection = recording
        } label: {
            Card(padding: Theme.Space.m) {
                DataRow(
                    glyph: "exclamationmark.triangle.fill",
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

    // MARK: - Data

    private var withErrors: [SessionRecording] {
        Array(
            recordings
                .filter(\.hasErrors)
                .sorted { $0.consoleErrorCount > $1.consoleErrorCount }
                .prefix(5)
        )
    }

    private var notPlayable: Int {
        recordings.filter { !$0.isReplayable }.count
    }

    private var totalDurationText: String {
        let total = Int(recordings.reduce(0) { $0 + ($1.recordingDuration ?? 0) })
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Entry paths by how many recordings began there.
    ///
    /// Recordings with no start URL are dropped rather than bucketed under "—":
    /// a placeholder that tops the chart says nothing about where anyone landed.
    private var entryPaths: [(path: String, count: Int)] {
        var counts: [String: Int] = [:]
        for recording in recordings where recording.startURL != nil {
            counts[recording.pathComponent, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { (path: $0.key, count: $0.value) }
    }
}
