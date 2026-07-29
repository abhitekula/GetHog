import GetHogKit
import SafariServices
import SwiftUI

struct SessionDetailView: View {
    let recording: SessionRecording

    @Environment(AppModel.self) private var model

    @State private var timeline = SessionTimelineStore()
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
            VStack(spacing: 16) {
                SessionHeaderCard(
                    recording: recording,
                    environment: SessionEnvironment(events: timeline.events, person: recording.person)
                )

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

                watchInPostHogCard

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

                FreshnessLabel(date: timeline.loadedAt)
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
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
        .refreshable { await loadTimeline() }
        .sheet(item: $webLink) { link in
            SessionSafariView(url: link.url).ignoresSafeArea()
        }
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
        await timeline.load(client: client, projectID: projectID, sessionID: recording.id)
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
                counters
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

            if !recording.isReplayable {
                StatusPill(text: "Mobile", tint: .secondary)
            }
            if recording.ongoing {
                StatusPill(text: "Live", tint: Theme.Status.good)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var counters: some View {
        HStack(alignment: .top, spacing: 0) {
            counter(
                value: Double(recording.clickCount).compactFormatted,
                label: "Clicks",
                tint: .primary
            )
            counter(
                value: Double(recording.keypressCount).compactFormatted,
                label: "Keypresses",
                tint: .primary
            )
            counter(
                value: Double(recording.consoleErrorCount).compactFormatted,
                label: "Console errors",
                // Colour is a reinforcement here, never the only signal: the
                // label always says what the number is.
                tint: recording.consoleErrorCount > 0 ? Theme.Status.critical : .primary
            )
            if let active = recording.activeSeconds {
                counter(value: SessionClock.clock(active), label: "Active", tint: .primary)
            }
        }
    }

    private func counter(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
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
