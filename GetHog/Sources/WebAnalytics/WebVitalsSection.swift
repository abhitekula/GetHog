import GetHogKit
import SwiftUI

/// The percentile a vitals breakdown is aggregated at.
///
/// Restricted to what the API accepts. There is deliberately no median option:
/// a median LCP looks reassuring and describes nobody's slow experience, and
/// offering it beside Google's bands would invite exactly that misreading.
enum WebVitalPercentile: String, CaseIterable, Identifiable, Hashable {
    case p75, p90, p99

    var id: String { rawValue }

    var title: String { rawValue }

    var spokenTitle: String {
        switch self {
        case .p75: "75th percentile"
        case .p90: "90th percentile"
        case .p99: "99th percentile"
        }
    }
}

extension WebVitalBand {
    /// Warm amber for the middle band rather than a third traffic-light hue —
    /// and every use of this is paired with the band's name, never colour alone.
    var tint: Color {
        switch self {
        case .good: Theme.Status.good
        case .needsImprovement: Theme.accentWarm
        case .poor: Theme.Status.critical
        }
    }
}

/// Core Web Vitals for one metric, at one stated percentile.
///
/// The percentile is displayed as prominently as the numbers because it changes
/// what the numbers mean: "LCP is 2.9s" is not a claim until you know whether
/// that is the median visitor or the slowest tenth. It defaults to p75 because
/// that is where Google defines the good/poor boundaries this screen draws
/// against — reading a p90 value against a p75 band overstates how bad a page is.
struct WebVitalsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var metric: WebVitalMetric
    @Binding var percentile: WebVitalPercentile
    let breakdown: WebVitalsBreakdown?
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void

    private var entries: [WebVitalEntry] { breakdown?.allEntries ?? [] }

    /// Worst first, so the pages worth fixing are the ones on screen.
    private var visibleEntries: [WebVitalEntry] { Array(entries.prefix(15)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Core Web Vitals", systemImage: "gauge.with.needle")

            pickers
            claimLine

            if entries.isEmpty && !isLoading {
                emptyOrError
            } else {
                bandSummary
                pageList
            }
        }
    }

    // MARK: Controls

    private var pickers: some View {
        VStack(spacing: Theme.Space.s) {
            adaptivelyStyled(
                Picker("Metric", selection: $metric) {
                    ForEach(WebVitalMetric.allCases) { option in
                        Text(option.rawValue)
                            .accessibilityLabel(option.title)
                            .tag(option)
                    }
                }
            )

            Picker("Percentile", selection: $percentile) {
                ForEach(WebVitalPercentile.allCases) { option in
                    Text(option.title)
                        .accessibilityLabel(option.spokenTitle)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func adaptivelyStyled(_ picker: some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    /// States the whole claim in one sentence: which metric, at which
    /// percentile, against which boundaries.
    private var claimLine: some View {
        Text(claimText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(spokenClaim)
    }

    private var claimText: String {
        """
        \(metric.title) at the \(percentile.title) — good under \
        \(metric.format(metric.thresholds[0])), poor over \(metric.format(metric.thresholds[1])).
        """
    }

    private var spokenClaim: String {
        """
        \(metric.title) at the \(percentile.spokenTitle). Good is under \
        \(metric.format(metric.thresholds[0])), poor is over \(metric.format(metric.thresholds[1])).
        """
    }

    // MARK: States

    @ViewBuilder
    private var emptyOrError: some View {
        if let error {
            ContentUnavailableView {
                Label("Couldn't load vitals", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again", action: onRetry)
            }
        } else {
            ContentUnavailableView(
                "No \(metric.rawValue) data",
                systemImage: "gauge.with.needle",
                description: Text(
                    """
                    No pages reported \(metric.title) in this window. \
                    Core Web Vitals need performance capture switched on in the PostHog browser SDK.
                    """
                )
            )
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Content

    /// How the site splits across the three bands, before any individual page.
    private var bandSummary: some View {
        // Ordered worst-first explicitly rather than by the band's own rank,
        // which GetHogKit keeps internal.
        HStack(spacing: Theme.Space.s) {
            ForEach([WebVitalBand.poor, .needsImprovement, .good], id: \.self) { band in
                let count = entries.filter { $0.band == band }.count
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count)")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text(band.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
                .background(band.tint.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(count) pages \(band.title.lowercased())")
            }
        }
        .skeleton(isLoading && entries.isEmpty)
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Card(accent: entries.first?.band?.tint) {
                VStack(spacing: 0) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().padding(.vertical, Theme.Space.s)
                        }
                        WebVitalEntryRow(entry: entry, metric: metric)
                    }
                }
            }
            .skeleton(isLoading && entries.isEmpty)

            if entries.count > visibleEntries.count {
                Text("Showing the \(visibleEntries.count) worst of \(entries.count) pages.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct WebVitalEntryRow: View {
    let entry: WebVitalEntry
    let metric: WebVitalMetric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                // Middle truncation: these paths share long prefixes, so the tail
                // is what tells two of them apart.
                Text(entry.path)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)

                if let band = entry.band {
                    StatusPill(text: band.title, tint: band.tint)
                }
            }

            Spacer(minLength: Theme.Space.s)

            Text(metric.format(entry.value))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            """
            \(entry.path), \(metric.format(entry.value))\
            \(entry.band.map { ", \($0.title)" } ?? "")
            """
        )
    }
}
