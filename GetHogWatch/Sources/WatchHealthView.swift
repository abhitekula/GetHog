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
                Section("Errors, last \(WatchModel.budget.hours) h") {
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
        switch WatchHealthCopy.emptyWatches(degraded: model.watchesDegraded) {
        case .degraded(let headline, let detail):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(headline)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.accentWarm)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .accessibilityElement(children: .combine)
        case .none(let detail):
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }

    private func watchRow(_ row: WatchHealth.WatchRow) -> some View {
        VStack(alignment: .leading) {
            Text(row.title)
                .font(Theme.Typography.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.xs) {
                Circle()
                    .fill(row.isFiring ? Theme.Status.critical : Theme.Status.good)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
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
        if let failure = model.healthRefreshFailure {
            WatchSectionFailureView(
                failure: failure,
                isRefreshing: model.isExplicitRefreshInFlight
            ) {
                Task { await model.retry() }
            }
        } else if let pulse = model.health.errorPulse {
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
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
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

/// The two empty states and the one footnote, as values.
///
/// Pure so the branch a degraded hand-off selects is pinned by a test rather
/// than by reading a screenshot — the whole point of `watchesDegraded` is that
/// its two outcomes are indistinguishable in a rendered list unless someone
/// checks which sentence was chosen.
///
/// The wording deliberately never says "a newer iPhone sent this". The kit can
/// tell a version it does not understand from a `Condition` it cannot decode,
/// but this build cannot, and blaming the phone for what may be a malformed
/// payload would send the user to the wrong place.
enum WatchHealthCopy {
    enum EmptyWatches: Equatable {
        case none(detail: String)
        case degraded(headline: String, detail: String)
    }

    static func emptyWatches(degraded: Bool) -> EmptyWatches {
        guard degraded else {
            return .none(detail: "No metric watches. Add them in GetHog on your iPhone.")
        }
        return .degraded(
            headline: "Thresholds didn't transfer",
            detail: """
                This watch app is older than GetHog on your iPhone. \
                Update it, then send the key again.
                """
        )
    }

    static let degradedFooter =
        "This watch app is older than GetHog on your iPhone; some settings didn't transfer."
}
