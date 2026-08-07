import Charts
import GetHogKit
import GetHogUI
import Observation
import SwiftUI
import UIKit

/// Which pinned metric is on screen, and how the cycle moves between them.
///
/// Kept apart from the view so the cycling rules can be tested without a
/// running screen and without waiting out a real interval — the alternative is
/// an auto-advance that only a twelve-second stopwatch can disagree with.
@MainActor
@Observable
final class TVAmbientCycler {

    /// How long one metric holds the screen.
    ///
    /// Twelve seconds is long enough to read a number, a delta and a sparkline
    /// without hurrying, and short enough that a six-tile dashboard comes back
    /// around inside about a minute. It is a constant rather than a preference
    /// because there is no settings surface on this platform to change it from
    /// — see `SettingsRoot`, which does not mount its navigation section here.
    static let interval: Duration = .seconds(12)

    private(set) var metrics: [SharedSnapshot.Metric]
    private(set) var index = 0

    init(metrics: [SharedSnapshot.Metric] = []) {
        self.metrics = metrics
    }

    var isEmpty: Bool { metrics.isEmpty }

    /// `nil` rather than a crash when there is nothing pinned. An empty
    /// dashboard is a state this screen has to render, not an impossible one.
    var current: SharedSnapshot.Metric? {
        guard metrics.indices.contains(index) else { return nil }
        return metrics[index]
    }

    func replace(metrics: [SharedSnapshot.Metric]) {
        self.metrics = metrics
        // Not clamped to the old index: a snapshot that shrank would otherwise
        // leave the screen pointing past the end until the next tick.
        index = 0
    }

    /// One step forward, wrapping. What the tick calls.
    func advance() {
        guard !metrics.isEmpty else { return }
        index = (index + 1) % metrics.count
    }

    /// One step in either direction, wrapping — what the remote's left and
    /// right calls. Backwards from the first lands on the last, which is what
    /// a ring means.
    func skip(_ direction: MoveCommandDirection) {
        guard !metrics.isEmpty else { return }
        switch direction {
        case .left: index = (index - 1 + metrics.count) % metrics.count
        case .right: index = (index + 1) % metrics.count
        default: break
        }
    }
}

/// The wallboard.
///
/// A first-class sidebar destination rather than a screensaver: an Apple TV in
/// a team's room is most often *left* on a number, and the platform's own idle
/// behaviour — dimming, then the system screen saver — is the one thing that
/// would defeat that. Hence `isIdleTimerDisabled`, re-asserted on every tick
/// rather than set once: the flag is per-application and the system is free to
/// reset it when the app resigns and resumes activity, so a single write at
/// `onAppear` is a claim about a moment rather than about the session.
struct TVAmbientView: View {
    /// Where select and Menu both land. The shell passes the destination back
    /// to Dashboards, so leaving the wallboard is one press either way.
    let exit: () -> Void

    @State private var cycler = TVAmbientCycler()
    /// Bumped to restart the tick clock, so a manual skip gets a full interval
    /// rather than whatever was left of the last one.
    @State private var clock = 0

    var body: some View {
        Button(action: exit) {
            content
        }
        .buttonStyle(.plain)
        .background(Theme.pageBackground)
        .onExitCommand(perform: exit)
        .onMoveCommand { direction in
            cycler.skip(direction)
            clock += 1
        }
        .onAppear {
            cycler.replace(metrics: Self.pinnedMetrics())
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            // Leaving the wallboard gives the idle timer back. A flag left set
            // by a screen nobody is looking at is how an Apple TV ends up never
            // sleeping.
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task(id: clock) {
            while !Task.isCancelled {
                try? await Task.sleep(for: TVAmbientCycler.interval)
                guard !Task.isCancelled else { return }
                cycler.advance()
                // The periodic re-assert. See the type's doc comment: one write
                // at `onAppear` claims the flag for a moment, and this claims it
                // for as long as the screen is up.
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    /// The pinned dashboard's tiles, as the phone and the watch already reduce
    /// them — the same App Group snapshot the Top Shelf reads, so the wallboard
    /// and the shelf can never disagree about what is pinned.
    private static func pinnedMetrics() -> [SharedSnapshot.Metric] {
        SharedSnapshotStore.shared.loadOrNil()?.metrics ?? []
    }

    @ViewBuilder
    private var content: some View {
        if let metric = cycler.current {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(metric.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Ink.secondary)

                Text(Self.headline(metric))
                    .font(.system(size: 160, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)

                if let delta = Self.deltaPhrase(metric) {
                    Text(delta)
                        .font(Theme.Typography.title)
                        .foregroundStyle(
                            metric.direction == .down ? Theme.Status.criticalInk : Theme.Status.goodInk
                        )
                }

                sparkline(metric)

                pageIndicator
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.spoken(metric))
        } else {
            ContentUnavailableView(
                "Nothing pinned yet",
                systemImage: "pin.slash",
                description: Text("Pinned insights appear here once a dashboard has loaded.")
            )
        }
    }

    @ViewBuilder
    private func sparkline(_ metric: SharedSnapshot.Metric) -> some View {
        if metric.sparkline.count > 1 {
            Chart(Array(metric.sparkline.enumerated()), id: \.offset) { point in
                LineMark(
                    x: .value("Point", point.offset),
                    y: .value("Value", point.element)
                )
                .foregroundStyle(SeriesPalette.color(at: 0))
                .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 180)
            // Decorative beside a number that is already spoken; a chart with no
            // axes has nothing more to tell a screen reader.
            .accessibilityHidden(true)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(cycler.metrics.indices, id: \.self) { position in
                Circle()
                    .fill(position == cycler.index ? Theme.accent : Theme.Ink.tertiary)
                    .frame(width: 12, height: 12)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Wording

    static func headline(_ metric: SharedSnapshot.Metric) -> String {
        let value = metric.value.compactFormatted
        guard let unit = metric.unit, !unit.isEmpty else { return value }
        return "\(value) \(unit)"
    }

    /// `nil` when there is no comparison period — the same contract
    /// `SharedSnapshot.Metric.previous` documents, where nil means "not known"
    /// rather than "no change".
    static func deltaPhrase(_ metric: SharedSnapshot.Metric) -> String? {
        guard let fraction = metric.deltaFraction else { return nil }
        let percent = abs(fraction).formatted(.percent.precision(.fractionLength(0)))
        switch metric.direction {
        case .up: return "Up \(percent)"
        case .down: return "Down \(percent)"
        default: return "No change"
        }
    }

    static func spoken(_ metric: SharedSnapshot.Metric) -> String {
        [metric.title, headline(metric), deltaPhrase(metric)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
