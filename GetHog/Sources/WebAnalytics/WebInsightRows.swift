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
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // The score keeps its word: this column is the whole reason the list
            // is ordered the way it is, and a bare number trailing every row
            // would leave that to be guessed.
            DataRow(
                glyph: dimensionGlyph,
                title: change.displayValue,
                subtitle: "\(change.currentValue.compactFormatted) \(change.metric)",
                footnote: change.displayDimension,
                accessory: .metric(
                    "\(change.impactScore.formatted(.number.precision(.fractionLength(0...1)))) impact"
                )
            )
            .truncationMode(.middle)

            comparison
                // Aligned under the row's text column rather than its glyph
                // (32pt tile plus the row's own gap), so the badge reads as part
                // of this entry and not as a new one.
                .padding(.leading, 32 + Theme.Space.m)
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

    /// The glyph follows the dimension type, never the row's rank, so a
    /// re-ranked list never redraws a row as a different kind of thing.
    ///
    /// It used to be a colour taken from `SeriesPalette`, which was wrong twice
    /// over: that palette belongs to chart series, and borrowing it for chrome
    /// implied a relationship between a row and a plotted line that does not
    /// exist. Shape carries the distinction instead, and the type is still
    /// spelled out in the row's footnote.
    ///
    /// `Device` is the exception, and it is a correction: the dimension's own
    /// glyph was a phone, so the ranking's `Desktop` row — the second entry in
    /// the demo capture, and routinely the largest in a real project — drew a
    /// phone next to the word "Desktop". Every other dimension here names a
    /// thing no symbol can state (a path, a domain, a country), so its glyph
    /// stays a label for the *type*; a device value is a form factor and the
    /// glyph has to agree with it. Shared with the breakdown table's rows rather
    /// than restated, so the two lists cannot drift apart.
    private var dimensionGlyph: String {
        switch change.dimensionType {
        case "Page": "doc.text"
        case "Referrer": "arrow.turn.down.right"
        case "Device": WebStatsDimension.deviceGlyph(for: change.displayValue)
        case "Browser": "safari"
        case "Country": "globe"
        case "Channel": "arrow.triangle.branch"
        default: "square.grid.2x2"
        }
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

    /// Direct labels rather than a header row, which would scroll away.
    private var summary: some View {
        DataRow(
            glyph: "arrow.up.forward.square",
            title: row.host ?? "Unknown destination",
            subtitle: row.url,
            footnote: "\(row.visitors.compactFormatted) visitors",
            // A URL is an identifier, and character alignment is what makes two
            // near-identical destinations comparable down the column.
            isSubtitleMonospaced: true,
            accessory: .metric("\(row.clicks.compactFormatted) clicks")
        )
        // Truncated in the middle, not the end: what distinguishes two tracked
        // outbound URLs is usually in the query string, which sits at the very
        // tail.
        .truncationMode(.middle)
    }

    private var spokenSummary: String {
        """
        Rank \(rank), \(row.host ?? row.url), \
        \(row.clicks.formatted(.number.precision(.fractionLength(0)))) clicks, \
        \(row.visitors.formatted(.number.precision(.fractionLength(0)))) visitors
        """
    }
}
