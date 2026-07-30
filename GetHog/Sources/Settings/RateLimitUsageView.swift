import GetHogKit
import SwiftUI

/// How much of the request budget GetHog has already spent, per category.
///
/// This is not a diagnostics curiosity. PostHog counts rate limits per
/// *organisation*, so every request this app makes is one the user's production
/// integrations can no longer make. The meter is the honest version of that
/// trade-off: it shows what the app is costing its owner, in their own budget.
struct RateLimitUsageView: View {
    let client: PostHogClient?

    @State private var usage: [RateLimitGovernor.Category: Double] = [:]

    /// The governor's windows slide, so a single snapshot is stale within
    /// seconds. Re-reading costs nothing — the governor is an in-memory actor
    /// and no request leaves the device — and the `.task` dies with the view.
    private static let pollInterval: Duration = .seconds(5)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(RateLimitGovernor.Category.allCases, id: \.self) { category in
                meter(for: category)
            }

            // The one part of this consumption nobody is present for. Naming its
            // ceiling is the same honesty the meters above are for: unattended
            // spending should be the easiest number in the app to find.
            Text(backgroundCost)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Background refresh. \(backgroundCost)")
        }
        .padding(.vertical, 4)
        .task { await poll() }
    }

    private func meter(for category: RateLimitGovernor.Category) -> some View {
        let fraction = usage[category] ?? 0
        let tint = Self.tint(for: fraction)
        let percentage = fraction.formatted(.percent.precision(.fractionLength(0)))
        let limits = Self.publishedLimits(for: category)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title(for: category))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                // The number carries the state; colour only reinforces it, so
                // the meter still reads correctly in greyscale.
                Text(percentage)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tint)
            }

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(tint)

            Text(limits)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.title(for: category)) request budget")
        .accessibilityValue("\(percentage) used. \(limits)")
    }

    private func poll() async {
        guard let client else { return }
        while !Task.isCancelled {
            usage = await client.usage()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    // MARK: - Copy

    private var backgroundCost: String {
        let hours = Int(BackgroundRefreshPolicy.minimumInterval / 3_600)
        return """
            Background refresh runs at most once every \(hours) hours, and each run \
            costs \(BackgroundRefreshPolicy.requestsPerRefresh) requests — \
            \(BackgroundRefreshPolicy.maximumRequestsPerDay) a day at the very most.
            """
    }

    /// Named for what the user sees in the app, not for the endpoint families
    /// PostHog groups them into.
    private static func title(for category: RateLimitGovernor.Category) -> String {
        switch category {
        case .analytics: "Insights & recordings"
        case .query: "Event queries"
        case .crud: "Dashboards & flags"
        }
    }

    private static func publishedLimits(for category: RateLimitGovernor.Category) -> String {
        switch category {
        case .analytics:
            "PostHog allows \(PostHogPublishedLimits.analyticsPerMinute.formatted())/min, \(PostHogPublishedLimits.analyticsPerHour.formatted())/hour"
        case .query:
            "PostHog allows \(PostHogPublishedLimits.queryPerHour.formatted())/hour"
        case .crud:
            "PostHog allows \(PostHogPublishedLimits.crudPerMinute.formatted())/min, \(PostHogPublishedLimits.crudPerHour.formatted())/hour"
        }
    }

    private static func tint(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.5: Theme.Status.good
        case ..<0.85: .orange
        default: Theme.Status.critical
        }
    }
}
