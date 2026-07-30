import GetHogKit
import SwiftUI

/// What the iPad detail pane shows before an event is picked.
///
/// Replaces `ContentUnavailableView("Select an event")`, which held two thirds
/// of an 11-inch canvas — the largest surface in the app spent on a sentence.
///
/// **Cost:** nothing. This counts the rows the feed is already holding; the
/// rate-limit budget is organisation-wide and an unasked-for summary must not
/// spend a request of it.
///
/// Which also fixes its scope, and every label here says so. The feed holds the
/// most recent page or two, not the project's history, so this describes what is
/// flowing through right now — "how far back does this reach" is stated as a
/// figure precisely so nobody reads these counts as all-time totals.
struct EventsOverview: View {
    let events: [EventRow]
    let loadedAt: Date?

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            header
            frequencySection
            customSection
            FreshnessLabel(date: loadedAt)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Event feed", systemImage: "bolt")

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip {
                MetricTile(label: "Events", value: "\(events.count)", compact: true)
                MetricTile(label: "Kinds", value: "\(counts.count)", compact: true)
                MetricTile(label: "People", value: "\(peopleCount)", compact: true)
                if let reach {
                    MetricTile(label: "Reaching back", value: reach, compact: true)
                }
            }
            .padding(.horizontal, -Theme.Space.l)

            Text("The \(events.count) most recent events, not the project's history.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Most frequent", systemImage: "chart.bar")

            VStack(spacing: Theme.Space.s) {
                ForEach(topEvents, id: \.name) { entry in
                    eventRow(entry.name, count: entry.count)
                }
            }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Instrumented by you", systemImage: "bolt.fill")

            if customEvents.isEmpty {
                // Worth saying rather than leaving as an empty gap: a feed made
                // entirely of PostHog's own autocapture means nobody has
                // instrumented this product yet, which is a finding.
                Card {
                    Label(
                        "Everything in this page is PostHog's own autocapture. No custom event was captured.",
                        systemImage: "info.circle"
                    )
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(customEvents, id: \.name) { entry in
                        eventRow(entry.name, count: entry.count)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func eventRow(_ name: String, count: Int) -> some View {
        Card(padding: Theme.Space.m) {
            DataRow(
                glyph: EventAppearance.glyph(for: name),
                tint: EventAppearance.tint(for: name),
                title: name,
                footnote: share(count),
                accessory: .metric("\(count)")
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(count) of \(events.count) events, \(share(count))")
    }

    private func share(_ count: Int) -> String {
        guard !events.isEmpty else { return "" }
        return (Double(count) / Double(events.count))
            .formatted(.percent.precision(.fractionLength(0))) + " of the feed"
    }

    // MARK: - Data

    private var counts: [String: Int] {
        events.reduce(into: [:]) { totals, event in totals[event.event, default: 0] += 1 }
    }

    private var topEvents: [(name: String, count: Int)] {
        ranked(counts).prefix(6).map { $0 }
    }

    private var customEvents: [(name: String, count: Int)] {
        ranked(counts.filter { EventAppearance.isCustom($0.key) }).prefix(5).map { $0 }
    }

    /// Ties break alphabetically so the order is stable between refreshes —
    /// a list that reshuffles itself when two counts are equal reads as data
    /// changing when nothing has.
    private func ranked(_ counts: [String: Int]) -> [(name: String, count: Int)] {
        counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }

    private var peopleCount: Int {
        Set(events.compactMap(\.distinctID)).count
    }

    /// How far back the loaded page reaches.
    ///
    /// The figure that stops every count above being misread as all-time: 50
    /// events spanning four minutes and 50 spanning four days are the same
    /// number describing very different projects.
    private var reach: String? {
        let stamps = events.compactMap(\.timestamp)
        guard let oldest = stamps.min(), let newest = stamps.max() else { return nil }
        let seconds = Int(newest.timeIntervalSince(oldest))
        guard seconds > 0 else { return nil }
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
