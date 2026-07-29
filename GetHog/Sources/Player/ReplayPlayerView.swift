import Observation
import GetHogKit
import SwiftUI
import WebKit

// MARK: - Bundled assets

/// Locates the offline rrweb-player bundle.
///
/// Nothing here may be fetched at runtime — the app is expected to replay a
/// session with no network at all — so the only question is *where in the
/// bundle* the files landed. Depending on how the resource folder is added to
/// the target, they are either in an `rrweb-player` subdirectory or flattened
/// into the bundle root, so both are checked.
enum ReplayAssets {
    static let scriptName = "rrweb-player.min.js"

    static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "rrweb-player")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }

    /// The player only works if the vendored library sits next to `index.html`.
    static var isComplete: Bool {
        guard let indexURL else { return false }
        let script = indexURL.deletingLastPathComponent().appendingPathComponent(scriptName)
        return FileManager.default.fileExists(atPath: script.path)
    }
}

// MARK: - Controller

/// Drives the embedded rrweb player and mirrors its state back into SwiftUI.
///
/// Every command is a one-line JS call and every state change arrives as a
/// `WKScriptMessage`, which keeps the native transport controls authoritative:
/// the web view renders pixels, it does not own playback.
@MainActor
@Observable
final class ReplayPlayerController {

    private(set) var isDocumentReady = false
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var didFinish = false

    /// Playhead in seconds from the first snapshot event.
    private(set) var currentTime: TimeInterval = 0
    /// Duration the player currently knows about — grows as chunks arrive.
    private(set) var playerDuration: TimeInterval = 0

    /// Fatal for the player only. The session header and timeline are unaffected.
    private(set) var failure: String?

    private(set) var speed: Double = 1
    private(set) var skipInactive = false

    var isScrubbing = false
    var scrubPosition: TimeInterval = 0

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var hasBooted = false
    @ObservationIgnored private var reduceMotion = false

    // MARK: Wiring

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func reportAssetMissing() {
        failure = "The bundled replay player is missing from this build."
    }

    func teardown() {
        guard webView != nil else { return }
        evaluate("window.GetHogReplay && window.GetHogReplay.teardown();")
        webView = nil
        hasBooted = false
        isDocumentReady = false
        isReady = false
        isPlaying = false
    }

    /// Wipes player state so a retry starts from a clean web view.
    func resetForRetry() {
        failure = nil
        hasBooted = false
        isReady = false
        isPlaying = false
        didFinish = false
        currentTime = 0
        playerDuration = 0
    }

    // MARK: Feeding events

    /// Boots the player on the first batch, then appends every later chunk
    /// in place so progressive loading never restarts playback.
    func submit(events: [SnapshotEvent], reduceMotion: Bool) {
        guard !events.isEmpty, isDocumentReady, failure == nil else { return }
        self.reduceMotion = reduceMotion

        let booting = !hasBooted
        hasBooted = true

        Task { [weak self] in
            // Encoding a megabyte of rrweb JSON is real work; keep it off the
            // main actor so the timeline stays scrollable while a chunk lands.
            let payload = await Task.detached(priority: .userInitiated) {
                Self.encode(events)
            }.value

            guard let self, let payload else {
                self?.failure = "Could not prepare the replay data."
                return
            }
            if booting {
                let options = """
                    {"speed": \(self.speed), \
                    "skipInactive": \(self.skipInactive), \
                    "mouseTail": \(self.reduceMotion ? "false" : "true"), \
                    "tailColor": "#3EC5CE"}
                    """
                self.evaluate("window.GetHogReplay.boot(\(payload), \(options));")
            } else {
                self.evaluate("window.GetHogReplay.append(\(payload));")
            }
        }
    }

    /// Serialises the rrweb events verbatim — `SnapshotEvent.event` is the whole
    /// original object, so the player sees exactly what the browser recorded.
    private nonisolated static func encode(_ events: [SnapshotEvent]) -> String? {
        let encoder = JSONEncoder()
        // A single non-finite number inside one event must not cost the batch.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "0", negativeInfinity: "0", nan: "0"
        )
        guard let data = try? encoder.encode(events.map(\.event)) else { return nil }

        var text = String(decoding: data, as: UTF8.self)
        // Legal in JSON, historically illegal in JS source: escape before the
        // array is injected as a JavaScript expression.
        if text.contains("\u{2028}") || text.contains("\u{2029}") {
            text = text
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        return text
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard isReady else { return }
        if didFinish {
            didFinish = false
            seek(to: 0, resume: true)
            return
        }
        evaluate("window.GetHogReplay.play();")
    }

    func pause() {
        guard isReady else { return }
        evaluate("window.GetHogReplay.pause();")
    }

    func seek(to seconds: TimeInterval, resume: Bool? = nil) {
        guard isReady else { return }
        let target = max(0, seconds)
        currentTime = target
        didFinish = false
        let shouldResume = resume ?? isPlaying
        evaluate("window.GetHogReplay.seek(\(Int(target * 1000)), \(shouldResume));")
    }

    func setSpeed(_ value: Double) {
        speed = value
        guard isReady else { return }
        evaluate("window.GetHogReplay.setSpeed(\(value));")
    }

    func setSkipInactive(_ value: Bool) {
        skipInactive = value
        guard isReady else { return }
        evaluate("window.GetHogReplay.setSkipInactive(\(value));")
    }

    // MARK: Bridge

    func handle(message body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "loaded":
            isDocumentReady = true
            if body["hasPlayerAsset"] as? Bool == false {
                reportAssetMissing()
            }

        case "ready":
            isReady = true
            failure = nil
            if let total = body["totalTime"] as? Double { playerDuration = total / 1000 }

        case "meta":
            if let total = body["totalTime"] as? Double { playerDuration = total / 1000 }

        case "time":
            guard !isScrubbing, let ms = body["currentTime"] as? Double else { return }
            let seconds = ms / 1000
            // rrweb ticks on every animation frame; quantising keeps SwiftUI from
            // re-rendering the whole detail screen 60 times a second.
            if abs(seconds - currentTime) >= 0.05 { currentTime = seconds }

        case "state":
            isPlaying = (body["state"] as? String) == "playing"

        case "finish":
            isPlaying = false
            didFinish = true

        case "error":
            let message = body["message"] as? String ?? "The replay player failed."
            // Once frames are on screen a stray script error is not worth
            // replacing a working player with an error card.
            if !isReady { failure = message }

        default:
            break
        }
    }

    func reportWebProcessCrash() {
        failure = "The replay renderer ran out of memory and stopped."
        isReady = false
        isPlaying = false
    }

    private func evaluate(_ script: String) {
        guard let webView else { return }
        // The trailing `null` keeps WebKit from complaining about `undefined`
        // results it cannot bridge back to Swift. Failures are not read from the
        // completion handler on purpose — the shim wraps every entry point in
        // try/catch and reports through the message bridge, which carries a far
        // more useful description than "a JavaScript exception occurred".
        webView.evaluateJavaScript(script + "\nnull;", completionHandler: nil)
    }
}

// MARK: - Web view

/// Forwards `window.webkit.messageHandlers.player` messages to the controller.
///
/// Kept separate from `ReplayPlayerController` because `WKUserContentController`
/// retains its message handlers strongly; this holds the controller weakly so
/// leaving the screen actually releases it.
@MainActor
final class ReplayWebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var controller: ReplayPlayerController?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        controller?.handle(message: body)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        controller?.handle(message: ["type": "error", "message": error.localizedDescription])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        controller?.reportWebProcessCrash()
    }
}

/// Hosts the offline rrweb player. Renders frames only — the transport controls
/// live outside, in SwiftUI.
struct WKWebViewRepresentable: UIViewRepresentable {
    let controller: ReplayPlayerController

    func makeCoordinator() -> ReplayWebBridge { ReplayWebBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let bridge = context.coordinator
        bridge.controller = controller
        configuration.userContentController.add(bridge, name: "player")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = bridge
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif

        controller.attach(webView)

        guard ReplayAssets.isComplete, let index = ReplayAssets.indexURL else {
            controller.reportAssetMissing()
            return webView
        }
        // Read access is scoped to the folder holding the shim so the page can
        // pull in its sibling script and stylesheet, and nothing else.
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ReplayWebBridge) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        coordinator.controller?.teardown()
    }
}

// MARK: - Section

/// The replay section of the session screen.
///
/// Structured so that every unhappy path is a compact card and the surrounding
/// screen keeps working: mobile recordings never attempt playback, a failed
/// internal endpoint degrades to an explanation, and the "Watch in PostHog"
/// escape hatch is always one tap away.
struct ReplayPlayerView: View {
    let recording: SessionRecording
    let loader: ReplayLoader
    let controller: ReplayPlayerController
    var onOpenInPostHog: (() -> Void)?
    var onRetry: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingSeek: TimeInterval?

    /// The recording's own duration is the honest total. The other two are
    /// fallbacks for the rare recording that reports no duration: the player and
    /// the buffer both only know about what has been streamed so far, so the
    /// scrubber grows rather than lying about a short session.
    private var duration: TimeInterval {
        max(recording.recordingDuration ?? 0, max(controller.playerDuration, loader.bufferedSeconds))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header

                switch loader.availability {
                case .mobileOnly:
                    mobileNotice
                case .noData:
                    notice(
                        icon: "film.slash",
                        title: "No replay stored",
                        detail: "PostHog has no snapshot data for this session."
                    )
                case .unavailable(let message):
                    unavailable(message)
                case .idle, .preparing:
                    if let failure = controller.failure {
                        unavailable(failure)
                    } else {
                        preparing
                    }
                case .ready:
                    if let failure = controller.failure {
                        unavailable(failure)
                    } else {
                        stage
                        PlayerTransportBar(
                            controller: controller,
                            duration: duration,
                            buffered: loader.bufferedSeconds,
                            onScrubCommitted: { seek(to: $0) }
                        )
                        streamingFootnote
                    }
                }
            }
        }
        .onChange(of: loader.pendingCount, initial: true) { _, _ in feedPlayer() }
        .onChange(of: controller.isDocumentReady, initial: true) { _, _ in feedPlayer() }
        .onChange(of: controller.currentTime) { _, now in
            loader.ensureCoverage(upTo: now + ReplayLoader.prefetchLead)
        }
        .onChange(of: loader.bufferedSeconds) { _, buffered in
            // A scrub past the buffer is honoured once the data lands, rather
            // than silently clamping and leaving the playhead somewhere else.
            guard let target = pendingSeek, buffered >= target else { return }
            pendingSeek = nil
            controller.seek(to: target)
        }
    }

    private var header: some View {
        HStack {
            Label("Replay", systemImage: "play.rectangle")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if loader.isFetching {
                ProgressView().controlSize(.small)
            }
            if let onOpenInPostHog {
                Button(action: onOpenInPostHog) {
                    Label("Open", systemImage: "arrow.up.forward.square")
                        .font(.caption)
                }
                .accessibilityLabel("Watch this replay in PostHog")
            }
        }
    }

    private var stage: some View {
        WKWebViewRepresentable(controller: controller)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.9))
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                if !controller.isReady {
                    ProgressView().tint(.white)
                }
            }
            .accessibilityLabel("Session replay")
            .accessibilityHint("Playback is controlled by the buttons below.")
    }

    private var preparing: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(loader.rangeCount > 0
                 ? "Loading replay \(loader.loadedRangeCount) of \(loader.rangeCount)…"
                 : "Looking for replay data…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var mobileNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Mobile recording", systemImage: "iphone")
                .font(.footnote.weight(.medium))
            Text(
                """
                This session was recorded by a mobile SDK. Playing it back needs a \
                transform PostHog has not open-sourced, so GetHog can't render it.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let onOpenInPostHog {
                Button(action: onOpenInPostHog) {
                    Label("Watch in PostHog", systemImage: "arrow.up.forward.square")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Replay unavailable", systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Status.critical)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("The event timeline below is unaffected.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                if let onRetry {
                    Button("Try again", action: onRetry)
                        .font(.footnote.weight(.medium))
                }
                if let onOpenInPostHog {
                    Button(action: onOpenInPostHog) {
                        Label("Watch in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.medium))
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.medium))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let onOpenInPostHog {
                Button(action: onOpenInPostHog) {
                    Label("Watch in PostHog", systemImage: "arrow.up.forward.square")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var streamingFootnote: some View {
        if let streamingError = loader.streamingError {
            Text("Stopped loading more of this session: \(streamingError)")
                .font(.caption2)
                .foregroundStyle(Theme.Status.critical)
        } else if !loader.isComplete {
            Text("Buffered \(SessionClock.clock(loader.bufferedSeconds)) of \(SessionClock.clock(duration))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(
                    "Buffered \(SessionClock.spoken(loader.bufferedSeconds)) of \(SessionClock.spoken(duration))"
                )
        }
    }

    private func feedPlayer() {
        guard controller.isDocumentReady, loader.canBoot, controller.failure == nil else { return }
        let batch = loader.drainPending()
        guard !batch.isEmpty else { return }
        controller.submit(events: batch, reduceMotion: reduceMotion)
    }

    /// Seeks within the buffer immediately and pulls the rest in behind it.
    private func seek(to seconds: TimeInterval) {
        let target = max(0, seconds)
        if target > loader.bufferedSeconds, !loader.isComplete {
            pendingSeek = target
            loader.ensureCoverage(upTo: target + ReplayLoader.prefetchLead)
            controller.seek(to: max(0, loader.bufferedSeconds - 1))
        } else {
            pendingSeek = nil
            controller.seek(to: target)
        }
    }
}

// MARK: - Transport

/// Native playback controls. Deliberately outside the web view: rrweb's own
/// controller is disabled so scrubbing, speed and skip-inactive feel like the
/// rest of the app rather than an embedded web page.
struct PlayerTransportBar: View {
    let controller: ReplayPlayerController
    let duration: TimeInterval
    let buffered: TimeInterval
    let onScrubCommitted: (TimeInterval) -> Void

    private static let speeds: [Double] = [1, 2, 4]

    private var upperBound: Double { max(duration, 1) }

    private var position: Binding<Double> {
        Binding(
            get: { controller.isScrubbing ? controller.scrubPosition : controller.currentTime },
            set: { controller.scrubPosition = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            scrubber

            HStack(spacing: 16) {
                Button {
                    controller.seek(to: max(0, controller.currentTime - 10))
                } label: {
                    Image(systemName: "gobackward.10").font(.title3)
                }
                .accessibilityLabel("Back 10 seconds")

                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent.opacity(0.15), in: .circle)
                }
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                Button {
                    controller.seek(to: min(upperBound, controller.currentTime + 10))
                } label: {
                    Image(systemName: "goforward.10").font(.title3)
                }
                .accessibilityLabel("Forward 10 seconds")

                Spacer()

                speedPicker
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(!controller.isReady)

            Toggle(isOn: Binding(
                get: { controller.skipInactive },
                set: { controller.setSkipInactive($0) }
            )) {
                Text("Skip inactive time").font(.footnote)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .accessibilityLabel("Skip inactive time")
        }
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: position, in: 0...upperBound) { editing in
                controller.isScrubbing = editing
                if editing {
                    controller.scrubPosition = controller.currentTime
                } else {
                    onScrubCommitted(controller.scrubPosition)
                }
            }
            .tint(Theme.accent)
            .disabled(!controller.isReady)
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(SessionClock.spoken(position.wrappedValue)) of \(SessionClock.spoken(duration))"
            )

            HStack {
                Text(SessionClock.clock(position.wrappedValue))
                Spacer()
                Text(SessionClock.clock(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private var speedPicker: some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { controller.speed },
                set: { controller.setSpeed($0) }
            )) {
                ForEach(Self.speeds, id: \.self) { value in
                    Text("\(Int(value))x").tag(value)
                }
            }
        } label: {
            Text("\(Int(controller.speed))x")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.15), in: .capsule)
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue("\(Int(controller.speed)) times")
    }
}
