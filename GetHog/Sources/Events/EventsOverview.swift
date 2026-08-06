import GetHogKit
import GetHogUI
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var facts: EventOverviewFacts {
        EventOverviewFacts(events: events)
    }

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            summaryScene
            frequencySection
            customSection
            FreshnessLabel(date: loadedAt)
        }
    }

    // MARK: - Sections

    private var summaryScene: some View {
        Card(accent: Theme.SignalChrome.coral) {
            summaryLayout
        }
        .accessibilityIdentifier("gethog.signal-summary.events")
        .signalConfirmation(trigger: loadedAt)
    }

    @ViewBuilder
    private var summaryLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            compactSummary
        } else {
            ViewThatFits(in: .horizontal) {
                regularSummary
                compactSummary
            }
        }
    }

    private var regularSummary: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            // The iPad 11-inch detail card offers about 439pt after padding.
            // Bound both regions so their truthful readable sizes plus spacing
            // fit that proposal instead of contributing unbounded ideal widths.
            eventIdentity
                .frame(width: 200, alignment: .leading)
            // `StatStrip` already scrolls instead of compressing its labels, so
            // this is a viewport over all four real metrics, not truncation.
            eventMetrics
                .frame(width: 216, alignment: .leading)
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            eventIdentity
            SignalRule(mark: .event)
            eventMetrics
        }
    }

    private var eventIdentity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Event signal", productMark: .event)

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            Text("The \(facts.eventCount) most recent events, not the project's history.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private var eventMetrics: some View {
        StatStrip(stacksAtAccessibilitySizes: true) {
            MetricTile(label: "Events", value: "\(facts.eventCount)", compact: true)
            MetricTile(label: "Kinds", value: "\(facts.kindCount)", compact: true)
            MetricTile(label: "People", value: "\(facts.peopleCount)", compact: true)
            if let reach = facts.reach {
                MetricTile(label: "Reaching back", value: reach, compact: true)
            }
        }
        .padding(.horizontal, -Theme.Space.l)
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
                brandGlyph: EventAppearance.brandGlyph(for: name),
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

    private var topEvents: [(name: String, count: Int)] {
        facts.ranked.prefix(6).map { $0 }
    }

    private var customEvents: [(name: String, count: Int)] {
        facts.custom.prefix(5).map { $0 }
    }
}
