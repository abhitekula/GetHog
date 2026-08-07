import GetHogKit
import GetHogUI
import SwiftUI

/// Page 1: the headline metric — big number, delta, the real GetHogUI chart
/// over the tile's own dated series, and an honest age stamp.
///
/// The chart is `InsightChartView` in its compact form rather than a bespoke
/// wrist sparkline: the phone and the wrist then draw the same series with the
/// same rules, and a shape drawn from `sparkline` alone would have no dates
/// under it to be right or wrong about.
struct WatchMetricsView: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    switch model.phase {
                    case .needsKey:
                        ContentUnavailableView(
                            "No key yet",
                            systemImage: "key.radiowaves.forward",
                            description: Text(
                                "Open GetHog on your iPhone to hand this watch its key."
                            )
                        )
                    case .failed(let message):
                        ContentUnavailableView(
                            "Couldn't refresh",
                            systemImage: "wifi.exclamationmark",
                            description: Text(message)
                        )
                    case .loading where model.headlineMetric == nil:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    default:
                        headline
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(model.snapshot?.projectName ?? "Metrics")
        }
    }

    @ViewBuilder private var headline: some View {
        if let metric = model.headlineMetric {
            Text(metric.title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(2)
            Text(metric.value.compactFormatted)
                .font(Theme.Typography.metric)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("\(metric.title), \(metric.value.compactFormatted)")
            deltaLine(metric)
            if let render = model.headlineRender {
                InsightChartView(model: render, compact: true, title: metric.title)
            }
            if let snapshot = model.snapshot {
                ageStamp(snapshot)
            }
        } else {
            ContentUnavailableView(
                "No metrics",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text(
                    "The pinned dashboard has no tile this watch can reduce to a number."
                )
            )
        }
    }

    private func deltaLine(_ metric: SharedSnapshot.Metric) -> some View {
        Label(
            WatchDeltaText.line(for: metric),
            systemImage: WatchDeltaText.symbol(for: metric)
        )
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Ink.secondary)
    }

    private func ageStamp(_ snapshot: SharedSnapshot) -> some View {
        let stale = snapshot.isStale()
        return Text(WatchAge.stamp(capturedAt: snapshot.capturedAt, now: Date()))
            .font(Theme.Typography.caption)
            .foregroundStyle(stale ? Theme.accentWarm : Theme.Ink.tertiary)
    }
}

/// The delta sentence, pure so its phrasing is pinned by tests.
///
/// Words, not glyphs, reach VoiceOver; the SF Symbol beside them carries the
/// direction visually. Direction is deliberately not painted good or bad — an
/// error count going up is not good news, and nothing at this level can know
/// which kind of number it is holding.
enum WatchDeltaText {
    static func line(for metric: SharedSnapshot.Metric) -> String {
        switch metric.direction {
        case .unknown:
            return "No comparison"
        case .flat:
            return "No change vs previous"
        case .up, .down:
            let word = metric.direction == .up ? "Up" : "Down"
            guard let fraction = metric.deltaFraction else {
                // A delta exists but the baseline was zero, so the percentage
                // would be infinite. State the absolute move instead of a
                // number nobody can act on.
                let delta = metric.delta ?? 0
                return "\(word) \(MetricWatch.format(abs(delta))) vs previous"
            }
            return "\(word) \(MetricWatch.format(abs(fraction * 100)))% vs previous"
        }
    }

    static func symbol(for metric: SharedSnapshot.Metric) -> String {
        switch metric.direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        case .unknown: "minus"
        }
    }
}

/// The age stamp, clamped at zero exactly as `SharedSnapshot.staleness` is:
/// clocks drift, and a snapshot from the future must not read "updated in five
/// minutes".
enum WatchAge {
    static func stamp(capturedAt: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(capturedAt))
        if age < 60 { return "Updated just now" }
        if age < 3600 { return "Updated \(Int(age / 60)) min ago" }
        if age < 48 * 3600 { return "Updated \(Int(age / 3600)) h ago" }
        return "Updated \(Int(age / 86_400)) d ago"
    }
}
