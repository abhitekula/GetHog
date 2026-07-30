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
    @ObservationIgnored private var colorScheme: ColorScheme = .light

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
    func submit(events: [SnapshotEvent], reduceMotion: Bool, colorScheme: ColorScheme) {
        guard !events.isEmpty, isDocumentReady, failure == nil else { return }
        self.reduceMotion = reduceMotion
        self.colorScheme = colorScheme

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
                    "tailColor": "\(Self.cssHex(Theme.accent, in: self.colorScheme))"}
                    """
                self.evaluate("window.GetHogReplay.boot(\(payload), \(options));")
            } else {
                self.evaluate("window.GetHogReplay.append(\(payload));")
            }
        }
    }

    /// Flattens a dynamic colour to the CSS hex rrweb's boot options want.
    ///
    /// The tail used to be the literal `#3EC5CE`, which is only `Theme.accent`'s
    /// *dark* value — in light mode the pointer trail was drawn in the dark-mode
    /// teal over a white page. Resolved against a trait collection built from the
    /// view's own scheme rather than `UITraitCollection.current`, which is not
    /// the view's when this runs from a detached encode.
    private static func cssHex(_ color: Color, in scheme: ColorScheme) -> String {
        let resolved = UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        )
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (component: CGFloat) in Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
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
        // Second line of defence for the rule `stage` states: a web view that is
        // itself an accessibility element has no children to walk into, so if a
        // future SwiftUI release ever stops honouring the representation, the
        // recorded page's links still do not become VoiceOver stops. The wording
        // stays on the SwiftUI side so there is only one copy of it.
        webView.isAccessibilityElement = true
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
    /// Handed to the controller because the rrweb mouse tail is drawn by the web
    /// view, which cannot resolve a SwiftUI dynamic colour on its own.
    @Environment(\.colorScheme) private var colorScheme
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
                        // `film.slash` is not a symbol — the film family stops
                        // at `.fill`, `.stack` and `.circle` — so this notice
                        // drew a blank where its glyph should be. `play.slash`
                        // exists and says the same thing more directly: there is
                        // nothing here to play.
                        icon: "play.slash",
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
                    // Caption type in a hand-built header row brings no control
                    // size with it, so the tap target was the two glyphs:
                    // measured at 49.0 × 13.3 against a 44 × 44 minimum.
                    Label("Open", systemImage: "arrow.up.forward.square")
                        .font(.caption)
                        .minimumHitTarget()
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
            // A recording is a picture of a page that has already happened. Its
            // links lead nowhere, its buttons do nothing, and the site is not
            // even this app's — so the stage is one element that says what it
            // is, and nothing inside it is a VoiceOver stop.
            //
            // Labelling a container does not make it a leaf, and neither does
            // `.accessibilityElement(children: .ignore)` here. Measured through
            // XCUITest on this same shape: a bare label leaves 3 web views, 15
            // activatable links and 61 elements; adding `.ignore` leaves 3, 15
            // and 62. WebKit serves the page's elements from the content
            // process, so SwiftUI's ignore never reaches them. Replacing the
            // subtree does: 0 web views, 0 links, one element carrying this
            // label. It has to be replacement rather than suppression because
            // the leak is unbounded — a bigger recorded page contributes
            // arbitrarily more of somebody else's navigation.
            .accessibilityRepresentation {
                Rectangle()
                    .accessibilityLabel("Session replay")
                    .accessibilityHint("Playback is controlled by the buttons below.")
            }
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
                .foregroundStyle(Theme.Status.criticalInk)
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
                .foregroundStyle(Theme.Status.criticalInk)
        } else if !loader.isComplete {
            Text("Buffered \(SessionClock.clock(loader.bufferedSeconds)) of \(SessionClock.clock(duration))")
                .font(.caption2)
                // `.tertiary` is an alpha composite that measures 1.73:1 on
                // `cardBackground` — the app's own ramp exists because of it.
                // This line is the only thing that says the replay is still
                // filling, so it is a poor candidate for text nobody can read.
                .foregroundStyle(Theme.Ink.tertiary)
                .accessibilityLabel(
                    "Buffered \(SessionClock.spoken(loader.bufferedSeconds)) of \(SessionClock.spoken(duration))"
                )
        }
    }

    private func feedPlayer() {
        guard controller.isDocumentReady, loader.canBoot, controller.failure == nil else { return }
        let batch = loader.drainPending()
        guard !batch.isEmpty else { return }
        controller.submit(events: batch, reduceMotion: reduceMotion, colorScheme: colorScheme)
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

            // Was 16. The skip buttons now carry 44pt boxes around 19pt glyphs,
            // so ~12.5pt of each gap is theirs; 4 here puts the visible spacing
            // back where it was rather than pushing the row apart.
            HStack(spacing: 4) {
                Button {
                    controller.seek(to: max(0, controller.currentTime - 10))
                } label: {
                    // Under `.plain` the glyph is the whole button, so the tap
                    // target *was* the glyph: measured at 19.0 × 21.0 against a
                    // 44 × 44 minimum. Play was the only control in this row
                    // that already had a frame, which is why its two
                    // neighbours — the ones you reach for while something is
                    // playing — were the short ones.
                    Image(systemName: "gobackward.10")
                        .font(.title3)
                        .minimumHitTarget()
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
                    Image(systemName: "goforward.10")
                        .font(.title3)
                        .minimumHitTarget()
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
                    Text("\(Int(value))x")
                        .accessibilityLabel(Self.spokenSpeed(value))
                        .tag(value)
                }
            }
        } label: {
            Text("\(Int(controller.speed))x")
                .font(.footnote.weight(.semibold).monospacedDigit())
                // The row's tint is right for the glyphs beside this pill and
                // wrong for a word: `Theme.accent` on a 15% wash of itself is
                // 4.82:1 on a card and 4.24:1 on the page, against a 4.5:1 floor
                // for text this size. `accentInk` is the same hue at 5.70:1 /
                // 5.02:1 — the partner `Theme.Status` documents for exactly this.
                .foregroundStyle(Theme.Status.accentInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.15), in: .capsule)
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Self.spokenSpeed(controller.speed))
    }

    /// The pill reads `1x`, which VoiceOver announced as "1 times". Nobody says
    /// that about a speed control; these are the words a person uses.
    private static func spokenSpeed(_ value: Double) -> String {
        value == 1 ? "Normal speed" : "\(Int(value)) times normal speed"
    }
}
