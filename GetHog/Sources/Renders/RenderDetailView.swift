import AVKit
import GetHogKit
import SwiftUI

/// One render: what state it is in, and — when it is in the only state that
/// allows it — the video itself.

// MARK: - Playback

@MainActor
@Observable
final class RenderPlaybackController {
    private(set) var player: AVPlayer?
    private(set) var isResolving = false
    /// Set only by a failure to *resolve*. A render that failed to render never
    /// reaches this controller at all — the screen refuses to offer it a play
    /// button — so anything reported here is genuinely worth retrying.
    private(set) var failure: String?

    /// Whether idle stretches are skipped during playback.
    ///
    /// Off by default: the render is a document of what happened, and silently
    /// jumping the playhead is a change to that document the viewer has to have
    /// asked for.
    var skipsInactivity = false

    /// Held so a second press does not spend another redirect on a link that is
    /// still signed.
    private var resolved: ResolvedRenderURL?
    private var idleSpans: [Range<TimeInterval>] = []
    private var timeObserver: Any?
    private let resolver = RenderURLResolver()

    /// Resolves the storage URL and starts playing.
    ///
    /// Called from the play button and nowhere else. The presigned link PostHog
    /// hands back is signed for an hour, so resolving when the list loads would
    /// spend one request per row to produce links that are dead before anyone
    /// picks a row.
    func play(export: RecordingExport, credential: StoredCredential, projectID: Int) async {
        #if DEBUG
        // Demo mode drives the UI from recorded JSON. The fixtures carry a
        // render's metadata but no video file, and the demo credential is the
        // literal string "demo" — resolving would send it to PostHog and come
        // back with an auth error that says nothing true about this screen.
        if DemoTransport.isEnabled {
            failure = "Playback isn't available in demo mode: the recorded responses "
                + "carry each render's metadata but no video file."
            return
        }
        #endif

        if let resolved, resolved.isUsable(asOf: Date()), player != nil {
            player?.play()
            return
        }

        isResolving = true
        failure = nil
        defer { isResolving = false }

        do {
            let link = try await resolver.resolve(
                credential: credential,
                projectID: projectID,
                exportID: export.id
            )
            resolved = link
            start(url: link.url, periods: export.context?.inactivityPeriods ?? [])
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func start(url: URL, periods: [ExportInactivityPeriod]) {
        // The idle half is what "skip inactivity" is made of; the active half is
        // already where playback wants to be.
        idleSpans = periods
            .filter { !$0.isActive && $0.duration > 0 }
            .map { $0.startSeconds..<$0.endSeconds }
            .sorted { $0.lowerBound < $1.lowerBound }

        let player = AVPlayer(url: url)
        self.player = player

        // Half a second is fine enough that a skipped stretch never plays for
        // long enough to be noticed, and coarse enough that the observer costs
        // nothing. A boundary observer would be exact but would have to be
        // rebuilt on every seek.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.skipIdle(at: time.seconds)
            }
        }

        player.play()
    }

    private func skipIdle(at seconds: TimeInterval) {
        guard skipsInactivity, let player, seconds.isFinite else { return }

        // The tail exclusion is what stops a skip that lands a hair short of the
        // boundary from being detected as "still idle" and seeking forever.
        guard let span = idleSpans.first(where: {
            $0.contains(seconds) && seconds < $0.upperBound - 0.5
        }) else { return }

        // Zero tolerance *before* the target: an approximate seek that landed
        // early would be inside the same idle stretch it just left.
        player.seek(
            to: CMTime(seconds: span.upperBound, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
        )
    }
}

// MARK: - Detail

struct RenderDetailView: View {
    let export: RecordingExport
    /// Passed down rather than re-read, so the detail cannot contradict the row
    /// that opened it — a render that expired between the two would otherwise
    /// show one status in the list and another on the screen it pushed.
    let asOf: Date

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controller = RenderPlaybackController()

    private var state: RecordingExportState { export.state(asOf: asOf) }

    private var replayWebURL: URL? {
        export.sessionRecordingID.flatMap { model.webURL(path: "replay/\($0)") }
    }

    var body: some View {
        PageScaffold {
            header

            switch state {
            case .ready: playerCard
            case .pending: pendingCard
            case .failed(let reason): failedCard(reason: reason)
            case .expired: expiredCard
            }

            if state.isPlayable, let context = export.context, !context.inactivityPeriods.isEmpty {
                activityCard(context: context)
            }

            detailsCard
            sourceCard
        }
        .navigationTitle(export.filename ?? "Render \(export.id)")
        .navigationBarTitleDisplayMode(.inline)
        // The player holds a periodic time observer, which keeps the `AVPlayer`
        // alive and the video decoding after the screen is gone. `deinit` cannot
        // do this — it is not main-actor isolated — so the screen does it.
        .onDisappear { controller.teardown() }
    }

    // MARK: Header

    private var header: some View {
        Card(accent: state.tint) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    // The format's own glyph, not the state's: the state has a
                    // glyph of its own on the card below, and an icon saying
                    // "failed" beside the words "MP4 video" reads as neither.
                    Label(export.format.title, systemImage: "film")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: Theme.Space.s)
                    StatusPill(text: export.statusText(asOf: asOf), tint: state.tint)
                }

                Text(export.summary)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)

                if let created = export.createdAt {
                    Text("Queued \(created.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Ready

    private var playerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Video", systemImage: "play.rectangle")

                if let player = controller.player {
                    // The ratio is carried by a `Color` with the player laid over
                    // it, not by the player itself: `VideoPlayer` has no intrinsic
                    // size, so an aspect ratio applied straight to it has nothing
                    // to work from. Black is also the right letterbox — the render
                    // is 16:9 only by convention and a portrait session will bar
                    // itself, which is what `AVPlayerLayer` does underneath anyway.
                    Color.black
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay { VideoPlayer(player: player) }
                        .clipShape(.rect(cornerRadius: Theme.Radius.small, style: .continuous))
                        // `VideoPlayer` brings the system transport, which labels
                        // its own controls; this names what is being played.
                        .accessibilityLabel("Rendered video of this session recording")
                } else if controller.isResolving {
                    resolvingPlaceholder
                } else if let failure = controller.failure {
                    // Resolution failed, not the render — so a retry is honest
                    // here in a way it never is on a failed or expired row.
                    notice(
                        icon: "wifi.exclamationmark",
                        title: "Couldn't get the video",
                        detail: failure,
                        tint: Theme.Status.critical
                    )
                    Button("Try again") { startPlayback() }
                        .buttonStyle(.glassProminent)
                } else {
                    poster
                }
            }
        }
    }

    private var poster: some View {
        VStack(spacing: Theme.Space.m) {
            Button {
                startPlayback()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
            }
            .buttonStyle(.glassProminent)

            Text("PostHog signs a fresh link for each play. They stop working about an hour after they're issued, so this one is fetched when you press play rather than when the list loaded.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }

    private var resolvingPlaceholder: some View {
        VStack(spacing: Theme.Space.s) {
            ProgressView()
            Text("Asking PostHog where the video lives…")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }

    // MARK: Pending

    /// A render still in flight.
    ///
    /// Explicitly not a bare spinner: `has_content: false` is also what a crashed
    /// render looks like, and the two were separated in `RecordingExportState`
    /// precisely so this screen never shows a permanent failure as something that
    /// is about to finish.
    private var pendingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    // The one thing on this screen that animates on its own, and
                    // therefore the one thing Reduce Motion has any business
                    // touching: an indefinite "still working" pulse with no end
                    // date. It does not gate the video — that is content the
                    // viewer asked for by pressing play, not interface motion.
                    Image(systemName: "hourglass")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text("Still rendering")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                Text("PostHog hasn't finished this render, so there is no file to play yet. Pull to refresh the list to check again.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                if let webURL = replayWebURL {
                    Link(destination: webURL) {
                        Label("Watch the session in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.medium))
                    }
                }
            }
        }
    }

    // MARK: Failed

    /// A render that crashed.
    ///
    /// No play button and no retry anywhere on this card. `exception` is
    /// permanent — the render produced no file and re-asking for one that was
    /// never made would fail identically — so offering "retry playback" would be
    /// a lie about what the button could do. The only real next step is queuing a
    /// fresh render, which happens in PostHog.
    private func failedCard(reason: String) -> some View {
        Card(accent: Theme.Status.critical) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Render failed", systemImage: "exclamationmark.triangle.fill")

                Text(reason)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: Theme.Radius.small))
                    .accessibilityLabel("PostHog reported: \(reason)")

                Text("PostHog reported this while producing the video. It never wrote a file, so there is nothing to play — queue a new render from the replay player if you still need it.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)

                if let webURL = replayWebURL {
                    Link(destination: webURL) {
                        Label("Open the session in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.medium))
                    }
                }
            }
        }
    }

    // MARK: Expired

    /// A render that was produced correctly and then cleaned up.
    ///
    /// Deliberately not the failure treatment: this one worked. The record
    /// survives `expires_after`, and `has_content` stays true long after the file
    /// is gone, which is why expiry outranks readiness in `state(asOf:)` — a
    /// "Play" button here would resolve to a dead link and fail inside `AVPlayer`
    /// as an opaque media error.
    private var expiredCard: some View {
        Card(accent: Theme.accentWarm) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Video deleted", systemImage: "clock.badge.xmark")

                Text(expiryExplanation)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)

                if let webURL = replayWebURL {
                    Link(destination: webURL) {
                        Label("Re-export from PostHog", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.medium))
                    }
                }
            }
        }
    }

    private var expiryExplanation: String {
        guard let expires = export.expiresAfter else {
            return "PostHog has deleted this render's file. The record survives; the video does not."
        }
        let when = expires.formatted(.relative(presentation: .named))
        return "PostHog deleted the file \(when), at the end of its retention window. "
            + "The render itself succeeded — export the session again to get a fresh video."
    }

    // MARK: Activity

    /// What `export_context.inactivityPeriods` is actually good for.
    ///
    /// The offsets are measured in the *rendered* video rather than the original
    /// recording, which is what makes them directly seekable: the toggle below
    /// hands `ts_to_s` straight to `AVPlayer`.
    private func activityCard(context: ExportRenderContext) -> some View {
        @Bindable var controller = controller

        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(
                    title: "Activity",
                    systemImage: "waveform.path.ecg",
                    subtitle: "Where somebody was doing something"
                )

                ActivityStrip(periods: context.inactivityPeriods)

                HStack(spacing: Theme.Space.l) {
                    activityLegend(
                        label: "Active",
                        seconds: context.activeDuration,
                        tint: Theme.accent
                    )
                    activityLegend(
                        label: "Idle",
                        seconds: context.idleDuration,
                        tint: .secondary
                    )
                    Spacer(minLength: 0)
                }

                // Offered only when there is something to skip. A toggle over a
                // render with no idle stretches in it would be a control that
                // could never do anything, which is worse than its absence.
                if context.idleDuration > 0 {
                    Toggle(isOn: $controller.skipsInactivity) {
                        Label(
                            "Skip inactivity (\(RenderFormat.duration(context.idleDuration)))",
                            systemImage: "forward.end.alt"
                        )
                        .font(Theme.Typography.body)
                    }
                }
            }
        }
    }

    private func activityLegend(label: String, seconds: TimeInterval, tint: Color) -> some View {
        // A filled dot *and* the word, never the dot alone.
        Label {
            Text("\(label) \(RenderFormat.duration(seconds))")
                .font(Theme.Typography.caption)
                .monospacedDigit()
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(tint)
        }
        .accessibilityLabel("\(label) for \(RenderFormat.duration(seconds))")
    }

    // MARK: Details

    private var detailsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Render", systemImage: "info.circle")
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(detailRows, id: \.label) { row in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Text(row.label)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: Theme.Space.s)
                            Text(row.value)
                                .font(Theme.Typography.caption)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.label), \(row.value)")
                    }
                }
            }
        }
    }

    private struct DetailRow {
        let label: String
        let value: String
    }

    private var detailRows: [DetailRow] {
        var rows: [DetailRow] = [DetailRow(label: "Export ID", value: String(export.id))]
        if let context = export.context {
            if let duration = context.duration {
                rows.append(DetailRow(label: "Video length", value: RenderFormat.duration(duration)))
            }
            if let bytes = context.fileSizeBytes {
                rows.append(DetailRow(label: "File size", value: RenderFormat.fileSize(bytes)))
            }
            if let speed = context.playbackSpeed {
                rows.append(DetailRow(label: "Rendered at", value: "\(speed.formatted())× speed"))
            }
            if let fps = context.recordingFPS {
                rows.append(DetailRow(label: "Frame rate", value: "\(fps) fps"))
            }
            if context.truncated {
                // Worth its own row: a truncated render is shorter than the
                // session it came from, and nothing else on this screen says so.
                rows.append(DetailRow(label: "Truncated", value: "PostHog cut this render short"))
            }
        }
        if let expires = export.expiresAfter {
            rows.append(DetailRow(
                label: export.hasExpired(asOf: asOf) ? "Deleted" : "Expires",
                value: expires.formatted(.dateTime.year().month().day())
            ))
        }
        if let level = export.userAccessLevel {
            rows.append(DetailRow(label: "Your access", value: level.capitalized))
        }
        return rows
    }

    // MARK: Source

    /// The session this render was made from.
    @ViewBuilder
    private var sourceCard: some View {
        if let recordingID = export.sessionRecordingID {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    CardHeader(title: "Source session", systemImage: "rectangle.stack")

                    NavigationLink(value: LinkedSession(recordingID: recordingID)) {
                        DataRow(
                            glyph: "rectangle.stack",
                            title: "Open the session",
                            subtitle: recordingID,
                            isSubtitleMonospaced: true
                        )
                    }
                    .buttonStyle(.plain)

                    if let webURL = replayWebURL {
                        Link(destination: webURL) {
                            Label("Watch the replay in PostHog", systemImage: "arrow.up.forward.square")
                                .font(.footnote.weight(.medium))
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func startPlayback() {
        guard let projectID = model.projectID,
              let credential = try? model.store.load()
        else { return }
        Task { await controller.play(export: export, credential: credential, projectID: projectID) }
    }

    private func notice(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Activity strip

/// Active and idle stretches, to scale.
///
/// Colour is never the only encoding: the legend beside it names both bands and
/// gives each its total, and the strip itself reads as one summary sentence to
/// VoiceOver rather than as a row of anonymous rectangles.
struct ActivityStrip: View {
    let periods: [ExportInactivityPeriod]

    private var total: TimeInterval {
        max(periods.reduce(0) { $0 + $1.duration }, 0.001)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
                    Rectangle()
                        .fill(period.isActive ? Theme.accent : Color.secondary.opacity(0.28))
                        .frame(width: proxy.size.width * period.duration / total)
                }
            }
        }
        .frame(height: 12)
        .clipShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        let active = periods.filter(\.isActive).reduce(0) { $0 + $1.duration }
        let idle = periods.filter { !$0.isActive }.reduce(0) { $0 + $1.duration }
        return "Activity: \(RenderFormat.duration(active)) active, \(RenderFormat.duration(idle)) idle, "
            + "across \(periods.count) stretch\(periods.count == 1 ? "" : "es")."
    }
}

// MARK: - Source session

/// Identity for the push to a render's source recording.
///
/// A wrapper rather than a bare `String` so the stack's `navigationDestination`
/// for this screen cannot collide with any other string a pushed screen wants to
/// carry.
struct LinkedSession: Hashable {
    let recordingID: String
}

/// The session a render was made from, fetched on demand.
///
/// `SessionDetailView` takes a whole `SessionRecording` and a render carries only
/// an id, so something has to fetch it. One request, and only when the row is
/// tapped.
///
/// This is deliberately not `DetachedWindowView`'s `DetachedRecordingView`, which
/// resolves the same id the same way. The difference is the failure: a torn-off
/// window is opened from a recording the user was just looking at, so "couldn't
/// load this recording" is the whole story there. Here the likely failure is
/// specific and worth naming — renders are kept for around ninety days (the
/// observed gap between `created_at` and `expires_after`), longer than many
/// projects keep the recordings themselves, so a video routinely outlives the
/// session it was made from and this link dead-ends through no fault of anyone's.
struct LinkedSessionView: View {
    let recordingID: String

    @Environment(AppModel.self) private var model
    @State private var recording: SessionRecording?
    @State private var failure: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let recording {
                SessionDetailView(recording: recording)
            } else if isLoading {
                ProgressView("Loading the session…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.pageBackground)
            } else {
                EmptyStateView(
                    title: "Session not available",
                    systemImage: "rectangle.stack.badge.minus",
                    message: failure ?? "PostHog no longer has this recording. Renders outlive the sessions they were made from, so the video can survive after the recording has aged out.",
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
                .background(Theme.pageBackground)
            }
        }
        .task(id: recordingID) { await load() }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            recording = try await client.send(
                PostHogAPI.sessionRecording(projectID: projectID, recordingID: recordingID)
            )
            failure = nil
        } catch {
            failure = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Formatting

/// The two formats `RecordingExport.summary` builds its row subtitle from, for the
/// places on this screen that need one without the other.
///
/// Repeated rather than reused because `RecordingExport.durationText` and
/// `fileSizeText` are internal to GetHogKit — deliberately, since the model's
/// public surface is the joined `summary`. Kept identical, and identical for the
/// same reason: hand-rolled rather than `Duration.formatted` so a column of
/// figures does not shift with the locale.
enum RenderFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func fileSize(_ bytes: Int) -> String {
        guard bytes >= 1000 else { return "\(bytes) bytes" }
        var value = Double(bytes)
        var unit = 0
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }
}
