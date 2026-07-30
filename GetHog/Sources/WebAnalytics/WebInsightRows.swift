import GetHogKit
import SwiftUI

/// One entry in the "where to look first" ranking.
///
/// The row is built around `impact_score` and the current figure because those
/// are the fields PostHog actually varies. The period-over-period percentage is
/// shown only when there is a real previous period behind it — see
/// `WebNotableChange.comparablePercentChange` for why that guard exists.
struct WebNotableChangeRow: View {
    let change: WebNotableChange
    let rank: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    StatusPill(text: change.displayDimension, tint: dimensionTint)
                    Text(change.displayValue)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Text("\(change.currentValue.compactFormatted) \(change.metric)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                comparison
            }

            Spacer(minLength: Theme.Space.m)

            VStack(alignment: .trailing, spacing: 1) {
                Text(change.impactScore.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("impact")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// The absence is drawn as its own state rather than left as a blank gap, so
    /// a row with nothing to compare reads as answered rather than unfinished.
    ///
    /// One limitation to know about: `DeltaOrAbsence` tints purely by direction,
    /// so it would paint a rising bounce rate green. That is latent rather than
    /// live — PostHog returns a zero previous value on every row today, so the
    /// badge never renders — but it is why the spoken summary below derives its
    /// verdict from `isImprovement`, which does account for metrics that improve
    /// by falling.
    private var comparison: some View {
        DeltaOrAbsence(
            current: change.currentValue,
            previous: change.previousValue,
            absenceReason: "No prior period"
        )
    }

    /// Colour follows the dimension type's fixed slot, never the row's rank, so
    /// a re-ranked list never repaints itself.
    private var dimensionTint: Color {
        let slots = ["Page", "Referrer", "Device", "Browser", "Country", "Channel"]
        guard let slot = slots.firstIndex(of: change.dimensionType) else { return .secondary }
        return SeriesPalette.color(at: slot)
    }

    private var spokenSummary: String {
        var parts = [
            "Rank \(rank)",
            "\(change.dimensionType) \(change.displayValue)",
            "\(change.currentValue.formatted(.number.precision(.fractionLength(0)))) \(change.metric)",
            "impact score \(change.impactScore.formatted(.number.precision(.fractionLength(0...1))))",
        ]
        if let percent = change.comparablePercentChange, percent != 0 {
            let magnitude = (abs(percent) / 100)
                .formatted(.percent.precision(.fractionLength(0...1)))
            var phrase = "\(percent > 0 ? "up" : "down") \(magnitude) versus the previous period"
            if let improvement = change.isImprovement {
                phrase += improvement ? ", an improvement" : ", a regression"
            }
            parts.append(phrase)
        } else {
            // Said per row as well as per section: VoiceOver reaches the row long
            // after the section footnote has been read and forgotten.
            parts.append("no comparable previous period")
        }
        return parts.joined(separator: ", ")
    }
}

/// One outbound destination and the traffic that left through it.
struct WebExternalClickRowView: View {
    let row: WebExternalClickRow
    let rank: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            summary
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spokenSummary)

            if let destination = row.destination {
                Link(destination: destination) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.body)
                }
                .accessibilityLabel("Open \(row.host ?? row.url)")
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.host ?? "Unknown destination")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Truncated in the middle, not the end: what distinguishes two
                // tracked outbound URLs is usually in the query string, which
                // sits at the very tail.
                Text(row.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Space.m)

            // Direct labels rather than a header row, which would scroll away.
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(row.clicks.compactFormatted) clicks")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("\(row.visitors.compactFormatted) visitors")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var spokenSummary: String {
        """
        Rank \(rank), \(row.host ?? row.url), \
        \(row.clicks.formatted(.number.precision(.fractionLength(0)))) clicks, \
        \(row.visitors.formatted(.number.precision(.fractionLength(0)))) visitors
        """
    }
}
