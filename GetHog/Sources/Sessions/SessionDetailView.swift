import GetHogKit
import SafariServices
import SwiftUI

struct SessionDetailView: View {
    let recording: SessionRecording

    @Environment(AppModel.self) private var model

    @State private var timeline = SessionTimelineStore()
    @State private var summary = SessionSummaryStore()
    @State private var loader = ReplayLoader()
    @State private var player = ReplayPlayerController()
    @State private var webLink: WebLink?

    private var replayWebURL: URL? {
        model.webURL(path: "replay/\(recording.id)")
    }

    /// `nil` when there is no console link to offer, so the replay cards can
    /// simply omit the button rather than showing a dead one.
    private var openInPostHog: (() -> Void)? {
        guard let replayWebURL else { return nil }
        return { webLink = WebLink(url: replayWebURL) }
    }

    var body: some View {
        ScrollView {
            // Padding is per-child rather than on the stack so the stat strip can
            // run to the screen edge: it scrolls horizontally, and a strip that
            // stops short of the bezel reads as a truncated card.
            VStack(spacing: Theme.Space.l) {
                SessionHeaderCard(
                    recording: recording,
                    environment: SessionEnvironment(events: timeline.events, person: recording.person)
                )
                .padding(.horizontal, Theme.Space.l)

                counters

                // The player sits above the timeline even though it is the
                // fragile half: the timeline is unbounded, and burying a video
                // under several hundred rows makes both it and the
                // seek-from-timeline gesture unusable.
                ReplayPlayerView(
                    recording: recording,
                    loader: loader,
                    controller: player,
                    onOpenInPostHog: openInPostHog,
                    onRetry: { retryReplay() }
                )
                .padding(.horizontal, Theme.Space.l)

                // Directly under the player, above the timeline. The chapters
                // are a table of contents *for the thing above them*, and a
                // table of contents that sits below several hundred event rows
                // is not one. It also puts the narrative — a paragraph that is
                // faster to read than the video is to scrub — at the top of what
                // someone actually reads on a phone.
                SessionSummaryCard(
                    store: summary,
                    // rrweb counts from its first snapshot, not from
                    // `session_start_time`, so the chapter offsets are re-based
                    // onto whichever origin the player is actually using. Same
                    // origin the timeline seeks on, for the same reason.
                    origin: loader.replayStart ?? recording.startTime,
                    canSeek: player.isReady,
                    onSeek: { offset in player.seek(to: offset, resume: true) },
                    onRetry: { Task { await loadSummary() } }
                )
                .padding(.horizontal, Theme.Space.l)

                watchInPostHogCard
                    .padding(.horizontal, Theme.Space.l)

                SessionTimelineView(
                    recording: recording,
                    store: timeline,
                    // Once snapshots are loaded their first timestamp is the
                    // exact origin rrweb measures from, so seeking lands on the
                    // right frame rather than a second or two out.
                    origin: loader.replayStart ?? recording.startTime,
                    canSeek: player.isReady,
                    onSeek: { offset in player.seek(to: offset, resume: true) }
                )
                .padding(.horizontal, Theme.Space.l)

                FreshnessLabel(date: timeline.loadedAt)
            }
            .padding(.vertical, Theme.Space.l)
        }
        .pageSurface()
        .navigationTitle(recording.personDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let replayWebURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: replayWebURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share a link to this session")
                }
            }
        }
        .task(id: recording.id) { await loadTimeline() }
        .task(id: recording.id) { await startReplay() }
        // A separate request, made when the screen opens. Most sessions have no
        // summary and answer 404, which the store reads as absence rather than
        // as failure — so this costs the screen nothing when there is nothing.
        .task(id: recording.id) { await loadSummary() }
        // Both in flight at once: they are different endpoints against different
        // rate-limit categories, and serialising them would double how long a
        // pull-to-refresh spins for no benefit.
        .refreshable {
            async let events: Void = loadTimeline()
            async let narrative: Void = loadSummary()
            _ = await (events, narrative)
        }
        .sheet(item: $webLink) { link in
            SessionSafariView(url: link.url).ignoresSafeArea()
        }
    }

    /// What the session amounted to, before the replay is asked to load.
    private var counters: some View {
        StatStrip {
            metric("Clicks", Double(recording.clickCount).compactFormatted)
            metric("Keypresses", Double(recording.keypressCount).compactFormatted)
            metric("Console errors", Double(recording.consoleErrorCount).compactFormatted)
            if let active = recording.activeSeconds {
                metric("Active", SessionClock.clock(active))
            }
        }
    }

    /// `MetricTile` combines its own children into "label, value". These numbers
    /// were spoken value-first before the strip replaced the hand-rolled
    /// counters, and that is the order they are actually scanned in.
    private func metric(_ label: String, _ value: String) -> some View {
        MetricTile(label: label, value: value, compact: true)
            .accessibilityLabel("\(value) \(label)")
    }

    /// Always present, whatever the native player managed to do. PostHog's own
    /// replay page is the guaranteed fallback for every recording, including the
    /// mobile ones this app deliberately does not try to render.
    @ViewBuilder
    private var watchInPostHogCard: some View {
        if let replayWebURL {
            Card {
                Button {
                    webLink = WebLink(url: replayWebURL)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch in PostHog")
                                .font(.subheadline.weight(.semibold))
                            Text("Full replay with console and network panes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Watch this session in PostHog")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func loadTimeline() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        // The recording carries its own span, so the query never has to scan the
        // whole `events` table to find one session's rows. `start_time` is
        // nullable and `recording_duration` can be absent on a still-processing
        // recording, so a missing bound falls back to a day either side of now —
        // wide enough to be wrong about *which* rows, never wide enough to be
        // the unbounded query that timed out on the events feed.
        let start = recording.startTime ?? Date()
        let end = start.addingTimeInterval(recording.recordingDuration ?? 86_400)
        await timeline.load(
            client: client,
            projectID: projectID,
            sessionID: recording.id,
            window: start...max(end, start)
        )
    }

    private func loadSummary() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        // Keyed by the session id, which is what `SessionRecording.id` already
        // is — no lookup, and no second identifier to keep in step.
        await summary.load(client: client, projectID: projectID, sessionID: recording.id)
    }

    private func startReplay() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await loader.start(client: client, projectID: projectID, recording: recording)
    }

    private func retryReplay() {
        loader.reset()
        player.resetForRetry()
        Task { await startReplay() }
    }
}

// MARK: - Header

struct SessionHeaderCard: View {
    let recording: SessionRecording
    let environment: SessionEnvironment

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                identity
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detailRows, id: \.label) { row in
                        detailRow(row)
                    }
                }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Text(recording.person?.initials ?? "?")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.15), in: .circle)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.personDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(recording.durationText)
                        .monospacedDigit()
                    if let start = recording.startTime {
                        Text(start, format: .dateTime.month().day().hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if recording.hasErrors {
                // The stat strip below states this number plainly, and
                // `MetricTile` is deliberately untinted — so the alarm the red
                // counter used to raise is carried here as a word instead.
                StatusPill(
                    text: "\(recording.consoleErrorCount) errors",
                    tint: Theme.Status.critical
                )
            }
            if !recording.isReplayable {
                StatusPill(text: "Mobile", tint: .secondary)
            }
            if recording.ongoing {
                StatusPill(text: "Live", tint: Theme.Status.good)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private struct DetailRow {
        let label: String
        let value: String?
        let icon: String
        var selectable = false
    }

    private var detailRows: [DetailRow] {
        [
            DetailRow(
                label: "Started",
                value: recording.startTime.map {
                    $0.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())
                },
                icon: "clock"
            ),
            DetailRow(label: "Start URL", value: recording.startURL, icon: "link", selectable: true),
            DetailRow(label: "Device", value: environment.summary, icon: "desktopcomputer"),
        ].filter { $0.value != nil }
    }

    private func detailRow(_ row: DetailRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(row.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // `.enabled` and `.disabled` are distinct types, so this cannot be a
            // ternary — the modifier has to be applied conditionally instead.
            Group {
                if row.selectable {
                    Text(row.value ?? "—").textSelection(.enabled)
                } else {
                    Text(row.value ?? "—")
                }
            }
            .font(.caption)
            .multilineTextAlignment(.trailing)
            .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(row.value ?? "unknown")")
    }
}

// MARK: - Derived environment

/// Browser / OS / device, recovered from whatever the session's events carry.
///
/// The recordings endpoint doesn't return these, so they are read off the first
/// event that happens to have them rather than costing an extra request.
struct SessionEnvironment {
    var browser: String?
    var os: String?
    var device: String?

    var summary: String? {
        let parts = [device?.capitalized, os, browser].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init(events: [EventRow], person: Person?) {
        for event in events {
            guard let properties = event.properties else { continue }
            if browser == nil { browser = Self.versioned(properties, "$browser", "$browser_version") }
            if os == nil { os = Self.versioned(properties, "$os", "$os_version") }
            if device == nil { device = properties["$device_type"]?.stringValue }
            if browser != nil, os != nil, device != nil { break }
        }
        if let properties = person?.properties {
            if browser == nil { browser = Self.versioned(properties, "$browser", "$browser_version") }
            if os == nil { os = Self.versioned(properties, "$os", "$os_version") }
            if device == nil { device = properties["$device_type"]?.stringValue }
        }
    }

    private static func versioned(_ properties: JSONValue, _ key: String, _ versionKey: String) -> String? {
        guard let name = properties[key]?.stringValue, !name.isEmpty else { return nil }
        guard let version = properties[versionKey]?.stringValue, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }
}

// MARK: - Web fallback

/// `URL` isn't `Identifiable`, and a sheet needs an identity to key off.
struct WebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// In-app Safari, so the PostHog session stays signed in and the user never
/// leaves GetHog to watch a replay it couldn't render itself.
struct SessionSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
