import GetHogKit
import SwiftUI

// The readout components.
//
// Two rules run through all of them.
//
// **Direction and significance are never carried by colour.** A delta shows an
// arrow that follows the number, and significance is a word — "Significant" /
// "Not significant" — never a green or grey wash on its own. Tint is the second
// encoding everywhere it appears.
//
// **The two statistical engines are never interchanged.** A Bayesian readout
// says "chance to win" and "credible interval"; a frequentist one says "p-value"
// and "confidence interval". They answer different questions, and a screen that
// relabels one as the other is stating something false. Which engine ran is
// taken from the result payload's own `method` field, not from a setting.

// MARK: - Verdict

/// The headline: the one thing this screen exists to say.
struct ExperimentVerdictCard: View {
    let verdict: ExperimentVerdict
    let method: ExperimentStatsMethod?
    let metricName: String?

    var body: some View {
        Card(accent: tint) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    // The symbol differs per state, so the state is legible
                    // before any colour is perceived.
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Status.ink(for: tint))
                        .accessibilityHidden(true)
                    Text(verdict.headline)
                        .font(Theme.Typography.title)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(verdict.explanation)
                    .font(.callout)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let metricName {
                    Text("Measured on \(metricName)")
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let method {
                    // Naming the engine is not decoration. "97.8% chance to win"
                    // and "p = 0.022" are different claims, and a reader who
                    // cannot tell which one they are looking at cannot act on
                    // either.
                    Label(
                        "\(method.displayName) statistics",
                        systemImage: "function"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        [
            verdict.headline,
            verdict.explanation,
            metricName.map { "Measured on \($0)" },
            method.map { "\($0.displayName) statistics" },
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }

    private var symbol: String {
        switch verdict {
        case .significantWin: "checkmark.seal.fill"
        case .significantLoss: "xmark.seal.fill"
        case .noSignificantDifference: "equal.circle"
        case .tooEarly: "hourglass"
        case .noResults: "questionmark.circle"
        case .notStarted: "pencil.circle"
        }
    }

    private var tint: Color {
        switch verdict {
        case .significantWin: Theme.Status.good
        case .significantLoss: Theme.Status.critical
        default: Theme.accentWarm
        }
    }
}

// MARK: - Metric row

/// One metric's delta, interval and per-arm figures.
struct ExperimentMetricSection: View {
    let metric: ExperimentMetric
    let readout: ExperimentReadout
    let didFail: Bool
    let isLoading: Bool
    let webURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if metric.type == nil {
                // The WorldMap lesson: a metric shape this build does not model
                // gets a card that says so. Falling through to a delta computed
                // from sums we cannot interpret would render as a number, and a
                // wrong number is worse than an absent one.
                UnsupportedMetricCard(rawType: metric.rawType, webURL: webURL)
            } else if didFail {
                Label(
                    "Couldn't load results for this metric.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if isLoading {
                Text("Loading results…")
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.secondary)
            } else if readout.comparisons.isEmpty {
                Label(readout.verdict.explanation, systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let baselineKey = readout.baselineKey {
                    Text("Compared with \(baselineKey)")
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                ForEach(readout.comparisons) { comparison in
                    ExperimentComparisonRow(
                        comparison: comparison,
                        method: readout.method,
                        metric: metric
                    )
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }
}

/// One variant measured against the baseline.
struct ExperimentComparisonRow: View {
    let comparison: ExperimentComparison
    let method: ExperimentStatsMethod?
    let metric: ExperimentMetric

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(comparison.variantKey)
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                deltaLabel
            }

            // Significance is a word before it is anything else.
            //
            // Deliberately tinted with the neutral accent rather than
            // `Status.good`: significance says the difference is *real*, not
            // that it is *welcome*. Rendered green it sat beside a red −4.3%
            // delta on the frequentist fixture and read as "good news" about a
            // result that was a significant loss.
            if comparison.isUsable {
                StatusPill(
                    text: comparison.isSignificant ? "Significant" : "Not significant",
                    tint: comparison.isSignificant ? Theme.accent : Color.secondary
                )
            }

            if let detail = statisticText {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(exposureText)
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)

            ForEach(comparison.validationFailures, id: \.self) { failure in
                Label(failure.explanation, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(Theme.Status.warningInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The delta, or a statement of why there is none.
    @ViewBuilder
    private var deltaLabel: some View {
        if let baseline = comparison.baselineMean, let variant = comparison.variantMean,
           baseline != 0, comparison.isUsable {
            DeltaBadge(
                current: variant,
                previous: baseline,
                // A `decrease` goal means a fall is the improvement. Without
                // this the badge paints a successful reduction as a loss.
                isIncreaseBad: metric.isDecreaseGoal
            )
        } else {
            Label("No comparison", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    /// The engine-specific statistic, always named for the engine that produced
    /// it. Renders nothing rather than guessing when the method is unknown.
    private var statisticText: String? {
        var parts: [String] = []
        switch method {
        case .bayesian:
            if let chance = comparison.chanceToWin {
                parts.append("\(percent(chance)) chance to win")
            }
        case .frequentist:
            if let p = comparison.pValue {
                parts.append("p = \(p.formatted(.number.precision(.fractionLength(0...4))))")
            }
        case nil:
            break
        }
        if let interval = comparison.interval, let method {
            parts.append(
                "95% \(method.intervalName) \(percent(interval.lowerBound)) to \(percent(interval.upperBound))"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var exposureText: String {
        "\(comparison.exposures.formatted()) exposed · baseline \(comparison.baselineExposures.formatted())"
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private var accessibilityText: String {
        var parts = ["Variant \(comparison.variantKey)"]
        if let delta = comparison.relativeDelta, comparison.isUsable {
            let direction = delta >= 0 ? "up" : "down"
            parts.append("\(direction) \(percent(abs(delta))) against the baseline")
        } else {
            parts.append("no comparison available")
        }
        if comparison.isUsable {
            parts.append(comparison.isSignificant ? "statistically significant" : "not statistically significant")
        }
        if let detail = statisticText { parts.append(detail) }
        parts.append(exposureText)
        parts.append(contentsOf: comparison.validationFailures.map(\.explanation))
        return parts.joined(separator: ", ")
    }
}

// MARK: - Exposures

/// Exposure counts, the observed split, and the sample-ratio check.
struct ExperimentExposureSection: View {
    let exposures: ExperimentExposures?
    let isUnavailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if isUnavailable || exposures == nil {
                // Silence here would read as "the split is fine". It is not the
                // same fact.
                Label(
                    "Exposure counts couldn't be loaded, so the traffic split hasn't been checked.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let exposures {
                if exposures.hasSampleRatioMismatch {
                    SampleRatioMismatchBanner(exposures: exposures)
                }
                ForEach(sortedVariants(exposures), id: \.self) { variant in
                    exposureRow(variant: variant, exposures: exposures)
                }
                Text("\(Int(exposures.totalExposures).formatted()) exposed in total")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                if let bias = exposures.multipleVariantPercentage, bias > 0 {
                    Text(
                        "\(bias.formatted(.number.precision(.fractionLength(0...2))))% of users saw more than one variant."
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func sortedVariants(_ exposures: ExperimentExposures) -> [String] {
        exposures.totals.keys.sorted { a, b in
            // Control first when present, then alphabetical — a stable order
            // that does not shuffle as counts change under the reader.
            if a == "control" { return true }
            if b == "control" { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    @ViewBuilder
    private func exposureRow(variant: String, exposures: ExperimentExposures) -> some View {
        let count = exposures.totals[variant] ?? 0
        let observed = exposures.observedSplit[variant]
        let expected = exposures.expectedSplit[variant]
        HStack(alignment: .firstTextBaseline) {
            Text(variant)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Int(count).formatted())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let observed {
                    Text(splitText(observed: observed, expected: expected))
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(variant), \(Int(count).formatted()) exposed"
                + (observed.map { ", \(splitText(observed: $0, expected: expected))" } ?? "")
        )
    }

    private func splitText(observed: Double, expected: Double?) -> String {
        let observedText = observed.formatted(.percent.precision(.fractionLength(0...1)))
        guard let expected else { return "\(observedText) of traffic" }
        return "\(observedText) of traffic, \(expected.formatted(.percent.precision(.fractionLength(0...1)))) expected"
    }
}

/// A mismatched split invalidates everything above it, so it is stated loudly
/// and in words.
struct SampleRatioMismatchBanner: View {
    let exposures: ExperimentExposures

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // Not a `Label`. At AX3 on a 320pt phone the stock label truncated
            // this to "Sample ratio…" — a warning that cannot finish saying what
            // it is warning about. Split into an icon and a text that is allowed
            // to grow vertically instead.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text("Sample ratio mismatch")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Status.criticalInk)
            Text(
                "Traffic did not split the way this experiment expected, so the results above may not be trustworthy."
                + (exposures.sampleRatioPValue.map {
                    " Split test p = \($0.formatted(.number.precision(.fractionLength(0...4))))."
                } ?? "")
            )
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.Status.critical.opacity(0.12),
            in: .rect(cornerRadius: Theme.Radius.small, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Running time

/// Progress against the running-time calculator's own targets.
struct ExperimentProgressSection: View {
    let experiment: Experiment
    let totalExposures: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let days = experiment.daysRunning() {
                row(
                    label: "Running for",
                    value: "\(days.formatted()) \(days == 1 ? "day" : "days")",
                    target: experiment.runningTime?.recommendedRunningTimeDays.map {
                        "target \(Int($0).formatted()) days"
                    }
                )
            }
            if let totalExposures, totalExposures > 0 {
                row(
                    label: "Exposed",
                    value: totalExposures.formatted(),
                    target: experiment.runningTime?.recommendedSampleSize.map {
                        "target \(Int($0).formatted())"
                    }
                )
            }
            if let mde = experiment.runningTime?.minimumDetectableEffect {
                row(
                    label: "Minimum detectable effect",
                    value: "\(mde.formatted(.number.precision(.fractionLength(0...1))))%",
                    target: nil
                )
            }
            if experiment.runningTime == nil {
                Text("No running-time target was set for this experiment.")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    @ViewBuilder
    private func row(label: String, value: String, target: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let target {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)" + (target.map { ", \($0)" } ?? ""))
    }
}

// MARK: - Unsupported

/// A metric shape this build cannot interpret.
///
/// Deliberately not an empty delta. `WorldMap` insights used to fall through to
/// a blank line chart and read as *broken* rather than as unsupported; the same
/// failure here would be worse, because a blank space beside a metric name reads
/// as "no effect" rather than "not drawn".
struct UnsupportedMetricCard: View {
    let rawType: String?
    var webURL: URL?

    private var friendlyName: String {
        guard let rawType, !rawType.isEmpty else { return "This" }
        return rawType.capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(
                "\(friendlyName) metrics aren't read on mobile yet",
                systemImage: "chart.bar.xaxis"
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("GetHog can't interpret this metric's numbers, so it isn't showing a result rather than showing one it can't stand behind.")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        .font(.footnote.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.s)
    }
}
