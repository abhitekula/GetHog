import GetHogKit
import GetHogUI
import SwiftUI

/// Page 2: the user's metric watches, firing or quiet, and the error pulse.
///
/// The watches cost **zero requests**: they are the same `MetricWatch` rules
/// the phone evaluates, run by the kit's own evaluator against the snapshot the
/// model already fetched. PostHog's server-side insight alerts are deliberately
/// not fetched here — they would be a sixth request answering a question this
/// page can answer for free.
struct WatchHealthView: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                Section("Metric watches") {
                    if model.health.rows.isEmpty { emptyWatches }
                    ForEach(model.health.rows) { row in
                        watchRow(row)
                    }
                }
                Section("Errors, last 24 h") {
                    errorPulse
                }
            }
            .navigationTitle("Health")
        }
    }

    /// Two different empty states, because they are two different facts. One is
    /// "you have no thresholds"; the other is "your iPhone sent thresholds this
    /// watch app is too old to read", which the user can fix and which would
    /// otherwise render as a clean bill of health.
    @ViewBuilder private var emptyWatches: some View {
        if model.watchesDegraded {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Thresholds didn't transfer")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.accentWarm)
                Text("This watch app is older than GetHog on your iPhone. Update it, then send the key again.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("No metric watches. Add them in GetHog on your iPhone.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }

    private func watchRow(_ row: WatchHealth.WatchRow) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(row.isFiring ? Theme.Status.critical : Theme.Status.good)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(row.title)
                    .font(Theme.Typography.body)
                    .lineLimit(1)
                Text(row.summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.title), \(row.isFiring ? "firing" : "quiet"), \(row.summary)"
        )
    }

    @ViewBuilder private var errorPulse: some View {
        if let pulse = model.health.errorPulse {
            if pulse.activeCount == 0 {
                Text("No active issues")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Status.good)
            } else {
                VStack(alignment: .leading) {
                    Text(Double(pulse.activeCount).counted("active issue"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Status.critical)
                    if let name = pulse.topIssueName {
                        Text("\(name) · \(pulse.topOccurrences.compactFormatted)×")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            // nil is *not checked* — a different claim from healthy, and the
            // one place a pulse is most likely to mislead.
            Text("Not checked yet")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }
}
