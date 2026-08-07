import GetHogKit
import GetHogUI
#if os(iOS)
import SafariServices
#endif
import SwiftUI

struct SessionDetailView: View {
    let recording: SessionRecording

    @Environment(AppModel.self) private var model

    @State private var timeline = SessionTimelineStore()
    @State private var summary = SessionSummaryStore()
    @State private var loader = ReplayLoader()
    @State private var player = ReplayPlayerController()
    @State private var webLink: WebLink?
    #if os(macOS) || os(visionOS)
    /// Neither the Mac nor Vision Pro has an in-app Safari to present; the web
    /// fallback opens the default browser instead — a real browsing window,
    /// which on Vision is the better answer anyway.
    @Environment(\.openURL) private var openURL
    #endif
    @State private var summaryGenerationTask: Task<Void, Never>?
    #if os(macOS)
    /// The diagnostics column starts **closed**, and the toolbar's
    /// `sidebar.trailing` button opens it.
    ///
    /// The spec offers this pane "at wide widths", and the window's own default
    /// is 1,280 × 820 — which is not one. Starting open gave the page ~450pt for
    /// a 16:10 replay stage on the display this app is developed against, which
    /// is the evidence made unreadable to show the evidence beside it.
    @State private var showsDiagnosticsPane = false
    #endif

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
                    summary: summary.detail,
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
                //
                // This adjacency is real now: the console and network cards
                // used to ride inside `ReplayPlayerView` and silently wedge
                // ~1,500pt of diagnostics in between, which no comment here
                // ever chose. They render below the timeline instead — the
                // story first, the evidence after.
                SessionSummaryCard(
                    store: summary,
                    // rrweb counts from its first snapshot, not from
                    // `session_start_time`, so the chapter offsets are re-based
                    // onto whichever origin the player is actually using. Same
                    // origin the timeline seeks on, for the same reason.
                    origin: loader.replayStart ?? recording.startTime,
                    canSeek: player.isReady,
                    onSeek: { offset in player.seek(to: offset, resume: true) },
                    onGenerate: {
                        guard summaryGenerationTask == nil else { return }
                        summaryGenerationTask = Task { @MainActor in
                            await generateSummary()
                            summaryGenerationTask = nil
                        }
                    },
                    onRetry: { Task { await loadSummary() } }
                )
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

                // Inline on iOS and visionOS. The Mac's trailing pane below is
                // the same content in a place only a resizable window has, so
                // it stays macOS-only; Vision would otherwise have no console
                // or network diagnostics at all, and the loader still fetches
                // and parses there even while the stage is a placeholder.
                #if os(iOS) || os(visionOS)
                ReplayDiagnosticsSection(
                    loader: loader,
                    controller: player,
                    duration: recording.recordingDuration ?? loader.bufferedSeconds,
                    onSeek: { offset in player.seek(to: offset, resume: true) }
                )
                .padding(.horizontal, Theme.Space.l)
                #endif

                watchInPostHogCard
                    .padding(.horizontal, Theme.Space.l)

                FreshnessLabel(date: timeline.loadedAt)
            }
            .padding(.vertical, Theme.Space.l)
        }
        .pageSurface()
        .navigationTitle(recording.personDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        // The strongest case in the app for continuing elsewhere: this screen
        // already offers "watch in PostHog" three times over, because a replay
        // is the thing a phone is worst at and a large screen is best at.
        .handoff(webURL: replayWebURL, title: recording.personDisplayName)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsDiagnosticsPane.toggle()
                } label: {
                    Label("Replay Diagnostics", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the console and network panes")
                .accessibilityLabel("Toggle replay diagnostics")
            }
            #endif
            if let replayWebURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: replayWebURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share a link to this session")
                }
            }
        }
        #if os(macOS)
        .replayDiagnosticsPane(isPresented: $showsDiagnosticsPane) {
            ReplayDiagnosticsPane(
                loader: loader,
                controller: player,
                duration: recording.recordingDuration ?? loader.bufferedSeconds,
                onSeek: { offset in player.seek(to: offset, resume: true) }
            )
        }
        #endif
        .task(id: recording.id) { await loadTimeline() }
        .task(id: recording.id) { await startReplay() }
        // A separate request, made when the screen opens. Most sessions have no
        // summary and answer 404, which the store reads as absence rather than
        // as failure — so this costs the screen nothing when there is nothing.
        .task(id: recording.id) { await loadSummary() }
        .onDisappear {
            summaryGenerationTask?.cancel()
            summaryGenerationTask = nil
        }
        // Both in flight at once: they are different endpoints against different
        // rate-limit categories, and serialising them would double how long a
        // pull-to-refresh spins for no benefit.
        .refreshable {
            async let events: Void = loadTimeline()
            async let narrative: Void = loadSummary()
            _ = await (events, narrative)
        }
        #if os(iOS)
        .sheet(item: $webLink) { link in
            SessionSafariView(url: link.url).ignoresSafeArea()
        }
        #else
        .onChange(of: webLink?.id) { _, _ in
            guard let link = webLink else { return }
            openURL(link.url)
            webLink = nil
        }
        #endif
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

    private func generateSummary() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await summary.generate(
            client: client,
            projectID: projectID,
            sessionID: recording.id
        )
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

#if os(macOS)
// MARK: - Mac diagnostics pane

extension View {
    /// The trailing diagnostics column, as an explicit split rather than
    /// SwiftUI's `.inspector`.
    ///
    /// **`.inspector` resizes the window, and does it whether or not it is
    /// showing.** Measured on this screen against a clean 1,280 × 820 frame on a
    /// 1,512pt display, by gating each part of the page behind a launch
    /// environment variable and reading the window frame after the session
    /// opened:
    ///
    /// | on the screen | window |
    /// |---|---|
    /// | every card, no `.inspector` | **1,280** — no growth |
    /// | every card, `.inspector` present but *closed* | **1,739** |
    /// | every card, `.inspector` open (what shipped) | **2,102** |
    /// | no cards at all, `.inspector` closed | **1,473** |
    ///
    /// So the page's own content asks for nothing the default window cannot
    /// give; attaching the modifier is the whole of it, and 193 of those points
    /// arrive on an *empty* page. `inspectorColumnWidth` does not reach it
    /// either — `min: 0`, a flat `320`, and dropping the modifier entirely all
    /// left the same 1,739. A window 590pt wider than the display puts the
    /// toolbar's trailing search field off the right edge, where nothing can
    /// click it, and AppKit then autosaves that frame for the next launch.
    ///
    /// An `HStack` is what `InsightDetailPresentation` already reached for, one
    /// screen over, after `.inspector` presented as a dimming overlay there.
    /// Same conclusion, a different symptom: it is not a column on this
    /// platform's terms, and asking it to be one costs the window.
    func replayDiagnosticsPane(
        isPresented: Binding<Bool>,
        @ViewBuilder pane: () -> some View
    ) -> some View {
        HStack(spacing: 0) {
            self
            if isPresented.wrappedValue {
                Divider()
                pane()
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: isPresented.wrappedValue)
    }
}

/// The console and network cards the iPhone stacks after the timeline, in the
/// trailing column a Mac window has the width for. Same cards, same stores,
/// same seek callback — only the placement is the Mac's.
private struct ReplayDiagnosticsPane: View {
    let loader: ReplayLoader
    let controller: ReplayPlayerController
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                if loader.availability == .ready {
                    ReplayDiagnosticsSection(
                        loader: loader,
                        controller: controller,
                        duration: duration,
                        onSeek: onSeek
                    )
                } else {
                    ContentUnavailableView(
                        "No replay diagnostics",
                        systemImage: "waveform.and.magnifyingglass",
                        description: Text("Console and network activity appear once a replay loads.")
                    )
                    .padding(.top, Theme.Space.xl)
                }
            }
            .padding(Theme.Space.l)
        }
        .pageSurface()
        // The same band `InsightSidePanel` takes, for the same reason: wide
        // enough for a URL and a status beside it, never wide enough to become
        // the screen. A plain frame rather than `inspectorColumnWidth`, which
        // only speaks to the modifier this pane no longer uses.
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
    }
}
#endif

// MARK: - Header

struct SessionHeaderCard: View {
    let recording: SessionRecording
    let environment: SessionEnvironment

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

    /// Beside the avatar normally, stacked without it at accessibility sizes.
    ///
    /// The same reflow as `FunnelStepRow` and `InsightLegend`, and the same
    /// measured reason. At AX5 this card was the only thing on the screen wider
    /// than the phone: the avatar is a fixed 44pt that does not scale, the
    /// status pills are `.fixedSize()` and refuse to compress at all, and the
    /// duration and the start time each demanded a line of their own — so the
    /// row's minimum width came out past the viewport and took the whole card,
    /// and the page background behind it, with it. The avatar went off the
    /// leading edge; every value ran off the trailing one.
    @ViewBuilder
    private var identity: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                nameAndTime
                // Stacked rather than in a row: a pill refuses compression by
                // design — the word is its only non-colour encoding — so three
                // of them side by side at this size cannot fit and do not try.
                statusPills
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 12) {
                avatar
                nameAndTime
                Spacer()
                statusPills
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Dropped at accessibility sizes, for the reason `InsightActorRow` drops
    /// its own: it is `.accessibilityHidden`, it only ever repeats the initials
    /// of the name printed beside it, and at 44 fixed points it is a quarter of
    /// the row taken from the only part that carries information.
    private var avatar: some View {
        Text(recording.person?.initials ?? "?")
            .font(.headline)
            .frame(width: 44, height: 44)
            .background(Theme.accent.opacity(0.15), in: .circle)
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
    }

    private var nameAndTime: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.personDisplayName)
                .font(.headline)
                // A person's display name here is an email or a distinct id, not
                // prose — see `RowCard`. `zxx` is the ISO code for "no
                // linguistic content", so no hyphenation dictionary applies and
                // the address cannot be given a hyphen it never had.
                .typesettingLanguage(Locale.Language(identifier: "zxx"))
                // Uncapped at accessibility sizes: one line of type that large
                // is a few characters, and `nina.drill.0729…` names nobody.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

            timings
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var timings: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.durationText).monospacedDigit()
                if let start = recording.startTime {
                    Text(start, format: .dateTime.month().day().hour().minute())
                }
            }
        } else {
            HStack(spacing: 8) {
                Text(recording.durationText).monospacedDigit()
                if let start = recording.startTime {
                    Text(start, format: .dateTime.month().day().hour().minute())
                }
            }
        }
    }

    @ViewBuilder
    private var statusPills: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xs) { pillContent }
        } else {
            HStack(spacing: Theme.Space.s) { pillContent }
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        if recording.hasErrors {
            // The stat strip below states this number plainly, and `MetricTile`
            // is deliberately untinted — so the alarm the red counter used to
            // raise is carried here as a word instead.
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

    /// Label and value share a line normally, and stack at accessibility sizes.
    ///
    /// Two columns is what put this card off both edges of the phone. The label
    /// column and the value column each have a minimum width — the widest word
    /// neither can break — and at AX5 `Start URL` beside a URL, or `Device`
    /// beside `Desktop · Mac OS X 10.15.7 · Chrome 150`, add up to more than the
    /// card is allowed to be. Stacked, each line gets the card's whole width to
    /// break in, which is what `FunnelStepRow` and `InsightLegend` already do.
    @ViewBuilder
    private func detailRow(_ row: DetailRow) -> some View {
        let content = Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    detailLabel(row)
                    detailValue(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    detailLabel(row)
                    Spacer(minLength: 8)
                    detailValue(row)
                        .multilineTextAlignment(.trailing)
                }
            }
        }

        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.label), \(row.value ?? "unknown")")
    }

    private func detailLabel(_ row: DetailRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(row.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func detailValue(_ row: DetailRow) -> some View {
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
        // None of these values is prose: a URL, a formatted timestamp, and a
        // browser/OS string. `zxx` is the ISO code for "no linguistic content",
        // so no hyphenation dictionary applies and a line breaks only where the
        // string already allows it — a hyphen invented inside a host name is a
        // different host name.
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
        // Uncapped at accessibility sizes: three lines of type that large is
        // most of a URL, and the tail is the part that says which page.
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
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

#if os(iOS)
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
#endif
