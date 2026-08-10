import GetHogKit
import GetHogUI
import SwiftUI

/// One endpoint's non-destructive recovery, shared by the three peer pages.
/// The page keeps any carried rows visible and adds this explanation beside
/// them; only retryable failures offer another five-request attempt.
struct WatchSectionFailureView: View {
    let failure: WatchSectionFailure
    let isRefreshing: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.accentWarm)
            if failure.canRetry {
                if isRefreshing {
                    Button {} label: {
                        HStack(spacing: Theme.Space.xs) {
                            ProgressView()
                                .accessibilityHidden(true)
                            Text("Refreshing…")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                } else {
                    Button {
                        retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// The phases that must expose the on-watch credential form.
///
/// Kept as a pure mapping so a rejected nonblank key cannot regress into a
/// failure-only screen with no path to replace it.
enum WatchCredentialEntryState: Equatable {
    case missing
    case replacement(message: String, region: PostHogRegion)

    init?(
        phase: WatchModel.Phase,
        refreshGuidance: WatchRefreshGuidance? = nil,
        refreshFailure: WatchRefreshFailure? = nil,
        credentialRegion: PostHogRegion? = nil
    ) {
        // A network failure is not evidence that the key is wrong. Offering a
        // replacement form here would send the user toward a destructive and
        // unrelated remedy instead of the paired iPhone named by the error.
        guard refreshGuidance == nil else { return nil }
        switch phase {
        case .needsKey:
            self = .missing
        case .failed(let message) where refreshFailure?.permitsCredentialReplacement == true:
            guard let credentialRegion else { return nil }
            self = .replacement(message: message, region: credentialRegion)
        case .failed, .loading, .ready:
            return nil
        }
    }
}

/// The Metrics page's mutually exclusive primary content.
///
/// Kept pure because `Phase.ready` means at least one best-effort section
/// answered, not that a metric exists. In particular, Activity can succeed
/// while Metrics and Flags return a permission error. Choosing from `phase`
/// alone used to turn that truthful error into the unrelated "No metrics"
/// empty state.
enum WatchMetricsContentState: Equatable {
    case offline(String)
    case credential(WatchCredentialEntryState)
    case failure(String)
    case loading
    case headline
    case noMetrics

    init(
        phase: WatchModel.Phase,
        hasHeadline: Bool,
        refreshGuidance: WatchRefreshGuidance?,
        refreshFailure: WatchRefreshFailure?,
        refreshFailureMessage: String?,
        credentialRegion: PostHogRegion?
    ) {
        if !hasHeadline, let refreshGuidance {
            self = .offline(refreshGuidance.message)
            return
        }
        if let entry = WatchCredentialEntryState(
            phase: phase,
            refreshGuidance: refreshGuidance,
            refreshFailure: refreshFailure,
            credentialRegion: credentialRegion
        ) {
            self = .credential(entry)
            return
        }
        if !hasHeadline, let refreshFailureMessage {
            self = .failure(refreshFailureMessage)
            return
        }
        if !hasHeadline, case .failed(let message) = phase {
            self = .failure(message)
            return
        }
        if !hasHeadline, phase == .loading {
            self = .loading
            return
        }
        self = hasHeadline ? .headline : .noMetrics
    }
}

/// Page 1: the headline metric — big number, delta, a trend, and an honest age
/// stamp.
///
/// The trend has two forms and `trend(for:)` explains the choice: the compact
/// `InsightChartView` over the tile's own dated series while this process still
/// holds one, so the phone and the wrist draw the same chart with the same
/// rules; and the snapshot's persisted `sparkline` as a plain shape once it
/// does not, which is what a throttled relaunch has.
struct WatchMetricsView: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let snapshot = model.snapshot {
                        Text(snapshot.projectName)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    switch WatchMetricsContentState(
                        phase: model.phase,
                        hasHeadline: model.headlineMetric != nil,
                        refreshGuidance: model.refreshGuidance,
                        refreshFailure: model.refreshFailure,
                        refreshFailureMessage: model.refreshFailureMessage,
                        credentialRegion: model.credentialRegion
                    ) {
                    case .offline(let message):
                        ContentUnavailableView(
                            "iPhone offline",
                            systemImage: "wifi.exclamationmark",
                            description: Text(message)
                        )
                    case .credential(let entry):
                        WatchManualKeyEntryView(state: entry)
                    case .failure(let message):
                        ContentUnavailableView(
                            "Couldn't refresh",
                            systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                            description: Text(message)
                        )
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    case .headline, .noMetrics:
                        headline
                    }

                    if model.canRetryRefresh {
                        if model.isExplicitRefreshInFlight {
                            Button {} label: {
                                HStack(spacing: Theme.Space.xs) {
                                    ProgressView()
                                        .accessibilityHidden(true)
                                    Text("Refreshing…")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                            .accessibilityIdentifier("watch-refresh-retry")
                        } else {
                            Button {
                                Task { await model.retry() }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("watch-refresh-retry")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Metrics")
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
                // The visible caption immediately before this value already
                // supplies its context. Repeating it here made VoiceOver say the
                // title twice before reaching the delta and trend.
                .accessibilityLabel(metric.value.compactFormatted)
            deltaLine(metric)
            trend(for: metric)
            if let snapshot = model.snapshot {
                ageStamp(snapshot)
            }
            if let guidance = model.refreshGuidance {
                Label(guidance.message, systemImage: "wifi.exclamationmark")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.accentWarm)
            } else if let message = model.refreshFailureMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.accentWarm)
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

    /// The dated chart when this process still has one, and the snapshot's own
    /// sparkline when it does not.
    ///
    /// The fallback is not a nicety — it is the *common* path. `renders` is
    /// in-memory only, and a refresh inside the 15-minute throttle window
    /// spends no requests, so every glance-again launch had the headline
    /// number, its delta and then nothing where the trend belongs. The
    /// snapshot's `sparkline` is persisted for exactly this, and drawing it
    /// makes the second glance look like the first.
    ///
    /// A shape rather than a chart, because that is all the data supports: a
    /// sparkline is values without days, so there is no axis to label and none
    /// is drawn. Inventing dates to reach `InsightChartView`'s dated form
    /// would put a time axis under numbers whose times were never stored.
    @ViewBuilder private func trend(for metric: SharedSnapshot.Metric) -> some View {
        if let render = model.headlineRender {
            InsightChartView(model: render, compact: true, title: metric.title)
        } else if metric.sparkline.count > 1 {
            WatchSparkline(values: metric.sparkline)
                .frame(height: 44)
                .accessibilityLabel("\(metric.title) trend, \(metric.sparkline.count) points")
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

/// The independent-install fallback for a watch that cannot receive the
/// iPhone hand-off yet. The `SecureField` owns the plaintext only while the
/// user is entering it and clears it before every save attempt.
struct WatchManualCredentialDraft: Equatable {
    let region: WatchManualRegion
    let selfHostedURL: String

    init(region: WatchManualRegion, selfHostedURL: String) {
        self.region = region
        self.selfHostedURL = selfHostedURL
    }

    init(state: WatchCredentialEntryState) {
        switch state {
        case .missing:
            self.init(region: .usCloud, selfHostedURL: "")
        case .replacement(_, let existingRegion):
            switch existingRegion {
            case .usCloud:
                self.init(region: .usCloud, selfHostedURL: "")
            case .euCloud:
                self.init(region: .euCloud, selfHostedURL: "")
            case .selfHosted(let url):
                self.init(region: .selfHosted, selfHostedURL: url.absoluteString)
            }
        }
    }
}

private struct WatchManualKeyEntryView: View {
    let state: WatchCredentialEntryState

    @State private var key = ""
    @State private var region = WatchManualRegion.usCloud
    @State private var selfHostedURL = ""
    @State private var error: String?

    init(state: WatchCredentialEntryState) {
        self.state = state
        let draft = WatchManualCredentialDraft(state: state)
        _region = State(initialValue: draft.region)
        _selfHostedURL = State(initialValue: draft.selfHostedURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch state {
            case .missing:
                ContentUnavailableView(
                    "No key yet",
                    systemImage: "key.radiowaves.forward",
                    description: Text("Open GetHog on your iPhone to send its key, or enter one here.")
                )
            case .replacement(let message, _):
                ContentUnavailableView(
                    "Couldn't refresh",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
                Text(
                    "Endpoint retained below. You can edit it before replacing the API key, "
                        + "or send it again from your iPhone."
                )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            SecureField("API key", text: $key)

            Picker("Region", selection: $region) {
                ForEach(WatchManualRegion.allCases) { region in
                    Text(region.title).tag(region)
                }
            }
            .pickerStyle(.navigationLink)

            if region == .selfHosted {
                TextField("Server URL", text: $selfHostedURL)
            }

            Button {
                let enteredKey = key
                // A failed keychain write must not leave a bearer credential
                // sitting in view state while the user reads the error.
                key = ""
                guard let resolvedRegion = region.resolve(selfHostedURL: selfHostedURL) else {
                    error = "Enter a valid server URL."
                    return
                }
                guard WatchManualKeyEntry.save(key: enteredKey, region: resolvedRegion) else {
                    error = "Enter your API key."
                    return
                }
                error = nil
            } label: {
                Label("Save API key", systemImage: "key")
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Status.criticalInk)
            }
        }
    }
}

enum WatchManualRegion: String, CaseIterable, Identifiable {
    case usCloud
    case euCloud
    case selfHosted

    var id: Self { self }

    var title: String {
        switch self {
        case .usCloud: "US Cloud"
        case .euCloud: "EU Cloud"
        case .selfHosted: "Self-hosted"
        }
    }

    func resolve(selfHostedURL: String) -> PostHogRegion? {
        switch self {
        case .usCloud: return PostHogRegion.usCloud
        case .euCloud: return PostHogRegion.euCloud
        case .selfHosted:
            guard let url = URL(string: selfHostedURL),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil
            else { return nil }
            return .selfHosted(url)
        }
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

/// The persisted sparkline, drawn as a shape.
///
/// GetHogUI has no sparkline component and `InsightChartView`'s forms all want
/// a `Series`, whose `Point` derives its date from a day string — a sparkline
/// has no day strings, so reaching that type means either inventing days or
/// handing the chart an undated series and letting it fall back to a
/// categorical axis on a 46mm screen. Neither is worth it for a trace with no
/// axis, no legend and no scrub.
struct WatchSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let fractions = WatchSparklineMath.fractions(values)
                guard fractions.count > 1, proxy.size.width > 0, proxy.size.height > 0
                else { return }
                let step = proxy.size.width / CGFloat(fractions.count - 1)
                let point = { (index: Int, fraction: Double) in
                    CGPoint(
                        x: CGFloat(index) * step,
                        y: proxy.size.height - CGFloat(fraction) * proxy.size.height
                    )
                }
                path.move(to: point(0, fractions[0]))
                for (index, fraction) in fractions.enumerated().dropFirst() {
                    path.addLine(to: point(index, fraction))
                }
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .accessibilityElement()
    }
}

/// The sparkline's arithmetic, outside the view that draws it.
///
/// Separate for a measured reason, not for tidiness: naming `WatchSparkline`
/// from `GetHogWatchTests` crashed the watchOS test host on the first
/// expectation that touched it — `NSMapGet … map table argument is NULL`, then
/// a restart, repeatedly. Merely referencing a SwiftUI `View` type from a
/// non-UI test on this platform is enough to do it. A plain enum has no such
/// metadata to initialise, so the part worth testing is testable and the view
/// keeps only the drawing.
enum WatchSparklineMath {

    /// Values to vertical fractions — 0 at the bottom of the strip, 1 at the
    /// top, oldest first. A zero range draws down the middle rather than
    /// dividing by it, and non-finite values are dropped before the bounds are
    /// taken: a malformed tile decodes to infinity without complaint, and one
    /// infinite bound would put every other point off the strip.
    static func fractions(_ values: [Double]) -> [Double] {
        let usable = values.filter(\.isFinite)
        guard usable.count > 1 else { return [] }
        let lowest = usable.min() ?? 0
        let highest = usable.max() ?? 0
        let range = highest - lowest
        guard range != 0 else { return Array(repeating: 0.5, count: usable.count) }
        return usable.map { ($0 - lowest) / range }
    }
}
