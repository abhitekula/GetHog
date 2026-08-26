import GetHogKit
import GetHogUI
import SwiftUI

/// Page 2: a compact pulse of PostHog error-tracking health.
struct WatchHealthView: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                Section("Errors, last \(WatchModel.budget.hours) h") {
                    errorPulse
                }
            }
            .navigationTitle("Health")
        }
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
