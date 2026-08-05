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

enum ReplaySubmissionKind: Equatable {
    case boot
    case append
}

/// Accepts renderer submissions synchronously, then runs their asynchronous
/// encoding/evaluation work in that same order.
@MainActor
final class ReplaySubmissionCoordinator {
    private var tail: Task<Void, Never>?
    private var hasAcceptedBoot = false
    private var generation = 0

    func accept(_ operation: @escaping @MainActor (ReplaySubmissionKind) async -> Void) {
        let kind: ReplaySubmissionKind = hasAcceptedBoot ? .append : .boot
        hasAcceptedBoot = true
        let predecessor = tail
        let acceptedGeneration = generation
        tail = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self,
                  !Task.isCancelled,
                  acceptedGeneration == self.generation
            else { return }
            await operation(kind)
        }
    }

    func reset() {
        generation &+= 1
        tail?.cancel()
        tail = nil
        hasAcceptedBoot = false
    }

    func waitUntilIdle() async {
        await tail?.value
    }
}

/// Drives the embedded rrweb player and mirrors its state back into SwiftUI.
///
/// Every command is a one-line JS call and every state change arrives as a
/// `WKScriptMessage`, which keeps the native transport controls authoritative:
/// the web view renders pixels, it does not own playback.
@MainActor
@Observable
final class ReplayPlayerController {

    private struct PendingSeekAcknowledgement {
        static let tolerance: TimeInterval = 0.05
        /// How long rejected ticks may pile up before the gate opens anyway.
        ///
        /// The acknowledgement exists to stop one stale pre-seek tick from
        /// snapping the clock back; it must never become a latch. A backward
        /// seek that resumes can blow straight through its acceptance window —
        /// rrweb lands near the target, plays on, and by the time the first
        /// tick is delivered the position is already past `target + tolerance`,
        /// after which *every* later tick is rejected and the clock is frozen
        /// for the life of the view. One second is ~20 rejected ticks: far more
        /// than one stale frame, far less than a user reaching for the scrubber
        /// to un-stick a dead readout.
        static let patience: TimeInterval = 1.0

        let origin: TimeInterval
        let target: TimeInterval
        let setAt: TimeInterval

        func accepts(_ position: TimeInterval, now: TimeInterval) -> Bool {
            // The patience valve, not a wider window. An earlier fix tried
            // widening the backward-seek acceptance to "anything earlier than
            // origin" instead, and `ReplayCoordinationTests` rejects that
            // rightly: a stale tick can land anywhere between target and
            // origin, and accepting one rolls the clock back — the exact
            // defect this gate exists to stop. Time is the only signal that
            // distinguishes "stale frame being filtered" from "window blown,
            // clock latched dead"; after a second of nothing but rejections,
            // the stream on offer is the only stream there is.
            if now - setAt > Self.patience { return true }
            if target > origin + Self.tolerance {
                return position >= target - Self.tolerance
            }
            if target < origin - Self.tolerance {
                return position <= target + Self.tolerance
            }
            return abs(position - target) <= Self.tolerance
        }
    }

    private(set) var isDocumentReady = false
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var didFinish = false

    /// Playhead in seconds from the first snapshot event.
    ///
    /// Republished at up to 20 Hz. Only views that genuinely need frame-rate
    /// tracking — the transport bar's knob — may read this in `body`;
    /// everything else reads `coarseTime`. Observation tracks the property
    /// *access*, so a view that reads `currentTime` and rounds it still
    /// invalidates twenty times a second; measured: it starved playback
    /// to a frozen clock with the network card expanded.
    private(set) var currentTime: TimeInterval = 0
    /// `currentTime` quantised to half-second steps and mutated only when the
    /// quantised value moves, so a dependent view invalidates at 2 Hz worst
    /// case. This is what the console and network panes lay out against.
    private(set) var coarseTime: TimeInterval = 0
    /// Duration the player currently knows about — grows as chunks arrive.
    private(set) var playerDuration: TimeInterval = 0

    static let coarseQuantum: TimeInterval = 0.5

    /// Fatal for the player only. The session header and timeline are unaffected.
    private(set) var failure: String?

    private(set) var speed: Double = 1
    private(set) var skipInactive = false

    @ObservationIgnored var isScrubbing = false

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var colorScheme: ColorScheme = .light
    @ObservationIgnored private var submissionCoordinator = ReplaySubmissionCoordinator()
    @ObservationIgnored private var submissionGeneration = 0
    @ObservationIgnored private var pendingSeekAcknowledgement: PendingSeekAcknowledgement?
    @ObservationIgnored private var interactiveSeekPosition: TimeInterval?
    @ObservationIgnored private var preparedPlayback: (
        position: TimeInterval,
        speed: Double,
        resume: Bool
    )?
    @ObservationIgnored private(set) var didRestorePreparedPlayback = false

    // MARK: Wiring

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func reportAssetMissing() {
        failure = "The bundled replay player is missing from this build."
    }

    func reportResourcePolicyFailure(_ message: String) {
        failure = message
    }

    func preparePlaybackForNextReady(
        position: TimeInterval,
        speed: Double,
        resume: Bool = false
    ) {
        preparedPlayback = (max(0, position), speed, resume)
        didRestorePreparedPlayback = false
        restorePreparedPlaybackIfReady()
    }

    var expansionHandoffPosition: TimeInterval {
        interactiveSeekPosition ?? pendingSeekAcknowledgement?.target ?? currentTime
    }

    func updateInteractiveSeekPosition(_ position: TimeInterval) {
        guard isReady else { return }
        interactiveSeekPosition = max(0, position)
    }

    func finishInteractiveSeek() {
        interactiveSeekPosition = nil
    }

    func cancelInteractiveSeek() {
        interactiveSeekPosition = nil
    }

    func teardown() {
        guard webView != nil else { return }
        evaluate("window.GetHogReplay && window.GetHogReplay.teardown();")
        invalidateSubmissions()
        webView = nil
        isDocumentReady = false
        isReady = false
        isPlaying = false
        pendingSeekAcknowledgement = nil
        interactiveSeekPosition = nil
        preparedPlayback = nil
        didRestorePreparedPlayback = false
    }

    /// Wipes player state so a retry starts from a clean web view.
    func resetForRetry() {
        invalidateSubmissions()
        failure = nil
        isReady = false
        isPlaying = false
        didFinish = false
        currentTime = 0
        coarseTime = 0
        playerDuration = 0
        pendingSeekAcknowledgement = nil
        interactiveSeekPosition = nil
        preparedPlayback = nil
        didRestorePreparedPlayback = false
    }

    /// Clears the current rrweb instance while keeping its loaded document so a
    /// new archive generation can boot in the same representable.
    func restartPlayback() {
        invalidateSubmissions()
        evaluate("window.GetHogReplay && window.GetHogReplay.teardown();")
        failure = nil
        isReady = false
        isPlaying = false
        didFinish = false
        currentTime = 0
        coarseTime = 0
        playerDuration = 0
        pendingSeekAcknowledgement = nil
        interactiveSeekPosition = nil
        preparedPlayback = nil
        didRestorePreparedPlayback = false
    }

    /// Rebuilds rrweb against an archive whose origin moved earlier while
    /// preserving the same absolute moment, speed, and playback intent.
    func restartPlayback(rebasingPlayheadBy adjustment: TimeInterval) {
        let pendingPlayback = preparedPlayback
        let livePosition = expansionHandoffPosition
        let liveSpeed = speed
        let liveResume = isPlaying
        restartPlayback()
        if let pendingPlayback {
            preparePlaybackForNextReady(
                position: pendingPlayback.position + adjustment,
                speed: pendingPlayback.speed,
                resume: pendingPlayback.resume
            )
        } else {
            preparePlaybackForNextReady(
                position: livePosition + adjustment,
                speed: liveSpeed,
                resume: liveResume
            )
        }
    }

    // MARK: Feeding events

    /// Boots the player on the first batch, then appends every later chunk
    /// in place so progressive loading never restarts playback.
    @discardableResult
    func submit(events: [SnapshotEvent], reduceMotion: Bool, colorScheme: ColorScheme) -> Bool {
        guard !events.isEmpty, isDocumentReady, failure == nil else { return false }
        self.reduceMotion = reduceMotion
        self.colorScheme = colorScheme
        let acceptedGeneration = submissionGeneration
        let acceptedSpeed = speed
        let acceptedSkipInactive = skipInactive
        let acceptedReduceMotion = reduceMotion
        let acceptedColorScheme = colorScheme

        submissionCoordinator.accept { [weak self] kind in
            // Encoding a megabyte of rrweb JSON is real work; keep it off the
            // main actor so the timeline stays scrollable while a chunk lands.
            let payload = await Task.detached(priority: .userInitiated) {
                Self.encode(events)
            }.value

            guard let self else { return }
            guard acceptedGeneration == self.submissionGeneration else { return }
            guard let payload else {
                self.failure = "Could not prepare the replay data."
                return
            }
            guard self.failure == nil else { return }
            if kind == .boot {
                let options = """
                    {"speed": \(acceptedSpeed), \
                    "skipInactive": \(acceptedSkipInactive), \
                    "mouseTail": \(acceptedReduceMotion ? "false" : "true"), \
                    "rendererGeneration": \(acceptedGeneration), \
                    "tailColor": "\(Self.cssHex(Theme.accent, in: acceptedColorScheme))"}
                    """
                self.evaluate("window.GetHogReplay.boot(\(payload), \(options));")
            } else {
                self.evaluate("window.GetHogReplay.append(\(payload));")
            }
        }
        return true
    }

    private func invalidateSubmissions() {
        submissionGeneration &+= 1
        submissionCoordinator.reset()
    }

    /// Flattens a dynamic colour to the CSS hex rrweb's boot options want.
    ///
    /// The tail used to be the literal `#3EC5CE`, which is only `Theme.accent`'s
    /// *dark* value — in light mode the pointer trail was drawn in the dark-mode
    /// teal over a white page. Resolved against a trait collection built from the
    /// view's own scheme rather than `UITraitCollection.current`, which is not
    /// the view's when this runs from a detached encode.
    private static func cssHex(_ color: Color, in scheme: ColorScheme) -> String {
        #if os(iOS)
        let resolved = UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        )
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (component: CGFloat) in Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        #else
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let resolved = color.resolve(in: environment)
        let byte = { (component: Float) in Int((min(max(CGFloat(component), 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
        #endif
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

    // `isPlaying` moves optimistically on the transport calls below and is
    // corrected by rrweb's own `state` messages. It used to move only on the
    // messages, which are asynchronous — so between asking to play and rrweb
    // saying "playing", `isPlaying` read false. Anything that captured
    // playback intent in that window captured the wrong one: measured as the
    // expanded player opening paused whenever an archive-origin restart fired
    // during the handoff, because `restartPlayback(rebasingPlayheadBy:)`
    // snapshots `isPlaying` to re-prepare with.

    func play() {
        guard isReady else { return }
        if didFinish {
            didFinish = false
            seek(to: 0, resume: true)
            return
        }
        isPlaying = true
        evaluate("window.GetHogReplay.play();")
    }

    func pause() {
        guard isReady else { return }
        isPlaying = false
        evaluate("window.GetHogReplay.pause();")
    }

    func seek(to seconds: TimeInterval, resume: Bool? = nil) {
        guard isReady else { return }
        let shouldResumeIntent = resume ?? isPlaying
        isPlaying = shouldResumeIntent
        let target = max(0, seconds)
        pendingSeekAcknowledgement = PendingSeekAcknowledgement(
            origin: currentTime,
            target: target,
            setAt: ProcessInfo.processInfo.systemUptime
        )
        currentTime = target
        coarseTime = (target / Self.coarseQuantum).rounded(.down) * Self.coarseQuantum
        didFinish = false
        evaluate("window.GetHogReplay.seek(\(Int(target * 1000)), \(shouldResumeIntent));")
    }

    /// Re-measures the stage and rescales the replay to it.
    ///
    /// The shim listens for `window.resize`, but a WKWebView whose frame is
    /// animated by SwiftUI — the full-screen cover appearing, the cover being
    /// dismissed, a window resize on iPad — can boot or settle at a geometry
    /// the debounced listener never saw. Observed live as a letterboxed sliver
    /// or an entirely black canvas that only a manual seek repainted.
    func refit() {
        guard isReady else { return }
        evaluate("window.GetHogReplay.resize();")
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
        guard type == "loaded" || acceptsRendererMessage(body) else { return }
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
            restorePreparedPlaybackIfReady()

        case "meta":
            if let total = body["totalTime"] as? Double { playerDuration = total / 1000 }

        case "time":
            guard !isScrubbing, let ms = body["currentTime"] as? Double else { return }
            let seconds = ms / 1000
            if let pendingSeekAcknowledgement {
                guard pendingSeekAcknowledgement.accepts(
                    seconds,
                    now: ProcessInfo.processInfo.systemUptime
                ) else { return }
                self.pendingSeekAcknowledgement = nil
            }
            // rrweb ticks on every animation frame; quantising keeps SwiftUI from
            // re-rendering the whole detail screen 60 times a second.
            if abs(seconds - currentTime) >= 0.05 { currentTime = seconds }
            let coarse = (seconds / Self.coarseQuantum).rounded(.down) * Self.coarseQuantum
            if coarse != coarseTime { coarseTime = coarse }

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

    private func restorePreparedPlaybackIfReady() {
        guard isReady, let preparedPlayback else { return }
        self.preparedPlayback = nil
        setSpeed(preparedPlayback.speed)
        seek(to: preparedPlayback.position, resume: preparedPlayback.resume)
        isPlaying = preparedPlayback.resume
        didRestorePreparedPlayback = true
    }

    private func acceptsRendererMessage(_ body: [String: Any]) -> Bool {
        guard body.keys.contains("rendererGeneration") else {
            // Unit tests and manually constructed diagnostics predate the
            // production bridge contract and remain useful without a tag.
            return true
        }
        guard let generation = body["rendererGeneration"] as? NSNumber else { return false }
        return generation.intValue == submissionGeneration
    }
}

// MARK: - Web view

/// WebKit enforcement for the replay renderer's offline-only boundary.
///
/// rrweb restores recorded attributes verbatim, including image, stylesheet,
/// font, media, and websocket URLs. File read scoping protects the app bundle;
/// it does not stop those restored URLs from reaching the network. These rules
/// block remote schemes while leaving the local shell's file URLs and rrweb's
/// data/blob/about URLs untouched.
enum ReplayWebResourcePolicy {
    static let identifier = "app.gethog.replay-offline-resources-v1"
    static let failureMessage =
        "The replay renderer couldn't enforce its offline resource protection."

    private static let encodedRules = #"""
        [
          {
            "trigger": { "url-filter": "^https?://.*" },
            "action": { "type": "block" }
          },
          {
            "trigger": { "url-filter": "^wss?://.*" },
            "action": { "type": "block" }
          }
        ]
        """#

    @MainActor
    static func compile() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRules
            ) { rules, error in
                if let rules {
                    continuation.resume(returning: rules)
                } else {
                    continuation.resume(
                        throwing: error ?? ReplayWebResourcePolicyError.compilationFailed
                    )
                }
            }
        }
    }
}

private enum ReplayWebResourcePolicyError: Error {
    case compilationFailed
}

/// Serializes policy installation before document loading and invalidates late
/// callbacks when SwiftUI tears down or replaces the representable.
@MainActor
final class ReplayWebDocumentLoader {
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(
        installPolicy: @escaping @MainActor () async throws -> Void,
        loadDocument: @escaping @MainActor () -> Void,
        reportFailure: @escaping @MainActor (String) -> Void
    ) {
        cancel()
        let acceptedGeneration = generation
        task = Task { @MainActor [weak self] in
            do {
                try await installPolicy()
                try Task.checkCancellation()
                guard let self, acceptedGeneration == self.generation else { return }
                loadDocument()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      acceptedGeneration == self.generation,
                      !Task.isCancelled
                else { return }
                reportFailure(ReplayWebResourcePolicy.failureMessage)
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
    }

    func waitUntilIdle() async {
        await task?.value
    }
}

/// Forwards `window.webkit.messageHandlers.player` messages to the controller.
///
/// Kept separate from `ReplayPlayerController` because `WKUserContentController`
/// retains its message handlers strongly; this holds the controller weakly so
/// leaving the screen actually releases it.
@MainActor
final class ReplayWebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var controller: ReplayPlayerController?
    let documentLoader = ReplayWebDocumentLoader()

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

#if os(iOS)
/// A WKWebView that tells the shim when native layout moved its frame.
///
/// The shim's own `window.resize` listener is debounced and fires only once
/// the web content process notices the change; a SwiftUI-animated frame — the
/// full-screen cover presenting, an iPad window resize — can settle at a size
/// the listener never reports, leaving the replay scaled to stale geometry.
/// Layout is the one place the native side knows the truth first.
final class ReplayStageWebView: WKWebView {
    var onLayout: ((CGSize) -> Void)?
    private var lastLayoutSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        onLayout?(bounds.size)
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

        let webView = ReplayStageWebView(frame: .zero, configuration: configuration)
        webView.onLayout = { [weak controller] _ in
            controller?.refit()
        }
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
        bridge.documentLoader.start(
            installPolicy: { [weak webView] in
                let rules = try await ReplayWebResourcePolicy.compile()
                try Task.checkCancellation()
                guard let webView else { throw CancellationError() }
                webView.configuration.userContentController.add(rules)
            },
            loadDocument: { [weak webView] in
                guard let webView else { return }
                // Read access is scoped to the folder holding the shim so the
                // page can pull in its sibling script and stylesheet, and
                // nothing else.
                webView.loadFileURL(
                    index,
                    allowingReadAccessTo: index.deletingLastPathComponent()
                )
            },
            reportFailure: { [weak controller] message in
                controller?.reportResourcePolicyFailure(message)
            }
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ReplayWebBridge) {
        coordinator.documentLoader.cancel()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        coordinator.controller?.teardown()
    }
}
#else
/// Temporary macOS stand-in for the rrweb stage. Task 5 replaces this with an
/// `NSViewRepresentable` hosting the same player document; keeping the iOS
/// type name is what lets both call sites compile unchanged until then.
struct WKWebViewRepresentable: View {
    let controller: ReplayPlayerController

    var body: some View {
        ContentUnavailableView(
            "Replay playback isn't on the Mac yet",
            systemImage: "play.slash",
            description: Text("Watch this session in PostHog in your browser.")
        )
    }
}
#endif

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
    var summary: SessionSummaryDetail?
    var onOpenInPostHog: (() -> Void)?
    var onRetry: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Handed to the controller because the rrweb mouse tail is drawn by the web
    /// view, which cannot resolve a SwiftUI dynamic colour on its own.
    @Environment(\.colorScheme) private var colorScheme
    @State private var seekArbiter = ReplaySeekArbiter()
    @State private var isExpanded = false
    @State private var resumeAfterExpansion = false

    /// The recording's own duration is the honest total. The other two are
    /// fallbacks for the rare recording that reports no duration: the player and
    /// the buffer both only know about what has been streamed so far, so the
    /// scrubber grows rather than lying about a short session.
    private var duration: TimeInterval {
        max(recording.recordingDuration ?? 0, max(controller.playerDuration, loader.bufferedSeconds))
    }

    private var markers: [SessionReplayMarker] {
        SessionReplayMarker.make(
            detail: summary,
            origin: loader.replayStart ?? recording.startTime,
            duration: duration
        )
    }

    var body: some View {
        // Just the player card. The console and network panes used to be
        // emitted here as siblings — which silently wedged ~1,500pt of
        // diagnostics between the player and the session narrative, and put
        // both cards inside the player's own invalidation graph. They are now
        // `ReplayDiagnosticsSection`, placed by the session screen after the
        // timeline, where a reader who has finished the story goes looking for
        // evidence.
        playerCard
        .onChange(of: loader.pendingCount, initial: true) { _, _ in feedPlayer() }
        .onChange(of: controller.isDocumentReady, initial: true) { _, _ in feedPlayer() }
        // Coverage prefetch keyed to the half-second playhead, not the 20 Hz
        // one: `prefetchLead` is measured in tens of seconds, so asking forty
        // times a second bought nothing but invalidation.
        .onChange(of: controller.coarseTime) { _, now in
            loader.ensureCoverage(upTo: now + ReplayLoader.prefetchLead)
        }
        .onChange(of: loader.bufferedSeconds) { _, buffered in
            guard case .seek(let target, let resume) = seekArbiter.coverageAdvanced(
                to: buffered
            ) else { return }
            controller.seek(to: target, resume: resume)
        }
        .onChange(of: loader.isComplete) { _, complete in
            guard complete,
                  case .seek(let target, let resume) = seekArbiter.coverageAdvanced(
                    to: duration
                  )
            else { return }
            controller.seek(to: target, resume: resume)
        }
        .fullScreenCover(isPresented: $isExpanded) {
            ExpandedReplayView(
                recording: recording,
                loader: loader,
                initialPosition: controller.expansionHandoffPosition,
                initialSpeed: controller.speed,
                // Expansion used to pause: the cover's controller prepared its
                // playback without a resume flag, so going full screen was
                // silently also pressing pause. Playback intent survives the
                // trip in both directions now.
                initialResume: resumeAfterExpansion,
                markers: markers,
                onClose: { position, wasPlaying in
                    seek(to: position, resume: wasPlaying)
                    // The inline stage sat behind the cover through all of
                    // this; if its frame settled while covered, its scale is
                    // stale — observed as a black canvas until a manual seek.
                    controller.refit()
                }
            )
        }
    }

    private var playerCard: some View {
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
                            buffered: loader.isComplete ? duration : loader.bufferedSeconds,
                            isComplete: loader.isComplete,
                            markers: markers,
                            scrubCancellationToken: seekArbiter.sliderCancellationToken,
                            onPreviewSeek: { controller.seek(to: $0, resume: false) },
                            onCoverageRequested: {
                                loader.ensureCoverage(upTo: $0 + ReplayLoader.prefetchLead)
                            },
                            onScrubCommitted: { target, resume in
                                commitSliderSeek(to: target, resume: resume)
                            },
                            onScrubBegan: {
                                seekArbiter.sliderBegan(generation: $0)
                            },
                            onMarkerSeek: { target in
                                seek(to: target, resume: controller.isPlaying)
                            }
                        )
                        streamingFootnote
                    }
                }
            }
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
            Button {
                expand()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .minimumHitTarget()
            }
            .disabled(!controller.isReady)
            .accessibilityLabel("Expand replay")
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
            .background(Theme.replayStageBackground.opacity(0.9))
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                ZStack {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(.rect)
                        .onTapGesture(perform: expand)
                    if !controller.isReady {
                        ProgressView().tint(.white)
                    }
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
                Button("Session replay", action: expand)
                    .accessibilityHint("Opens the replay full screen.")
                    .disabled(!controller.isReady)
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
        let delivery = loader.drainPendingDelivery()
        guard !delivery.events.isEmpty else { return }
        if delivery.mode == .restart {
            controller.restartPlayback(
                rebasingPlayheadBy: delivery.playheadAdjustment
            )
        }
        controller.submit(
            events: delivery.events,
            reduceMotion: reduceMotion,
            colorScheme: colorScheme
        )
    }

    private func expand() {
        guard controller.isReady, !isExpanded else { return }
        resumeAfterExpansion = controller.isPlaying
        controller.pause()
        isExpanded = true
    }

    /// Seeks within the buffer immediately and pulls the rest in behind it.
    private func seek(to seconds: TimeInterval, resume: Bool? = nil) {
        let target = min(max(0, seconds), max(0, duration))
        let shouldResume = resume ?? controller.isPlaying
        switch seekArbiter.requestProgrammatic(
            target: target,
            resume: shouldResume,
            buffered: loader.bufferedSeconds,
            isComplete: loader.isComplete
        ) {
        case .waiting:
            loader.ensureCoverage(upTo: target + ReplayLoader.prefetchLead)
            controller.seek(to: max(0, loader.bufferedSeconds - 1), resume: false)
        case .seek:
            controller.seek(to: target, resume: shouldResume)
        }
    }

    private func commitSliderSeek(to target: TimeInterval, resume: Bool) {
        guard case .seek(let target, let resume) = seekArbiter.acceptSliderCommit(
            target: target,
            resume: resume
        ) else { return }
        controller.seek(to: target, resume: resume)
    }
}

// MARK: - Diagnostics section

/// Console and network, drawn from rrweb plugin events that arrived in the
/// blobs the player already fetched — no extra request, and no part of the
/// shared rate-limit budget.
///
/// A sibling of the player on the session screen, placed after the timeline:
/// the summary and event story are what a reader wants next to the video, and
/// the waterfall is what they consult afterwards. Being its own view also keeps
/// the playhead dependency out of the player card's body — this subtree reads
/// `coarseTime` and invalidates at 2 Hz worst case, whatever the frame rate.
///
/// Shown whenever snapshot data loaded, including when the web player itself
/// failed: an rrweb crash costs the pixels, not the console.
struct ReplayDiagnosticsSection: View {
    let loader: ReplayLoader
    let controller: ReplayPlayerController
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        if loader.availability == .ready {
            ReplayConsoleCard(
                diagnostics: loader.diagnostics,
                origin: loader.replayStart,
                playhead: controller.coarseTime,
                canSeek: controller.isReady,
                isStreaming: !loader.isComplete && loader.streamingError == nil,
                onSeek: onSeek
            )
            ReplayNetworkCard(
                diagnostics: loader.diagnostics,
                origin: loader.replayStart,
                duration: duration,
                playhead: controller.coarseTime,
                canSeek: controller.isReady,
                isStreaming: !loader.isComplete && loader.streamingError == nil,
                onSeek: onSeek
            )
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
    let isComplete: Bool
    var markers: [SessionReplayMarker] = []
    var positionAccessibilityLabel = "Playback position"
    let scrubCancellationToken: ReplaySliderCancellationToken?
    let onPreviewSeek: (TimeInterval) -> Void
    let onCoverageRequested: (TimeInterval) -> Void
    let onScrubCommitted: (TimeInterval, Bool) -> Void
    let onScrubBegan: (Int) -> Void
    let onMarkerSeek: (TimeInterval) -> Void

    @State private var interaction = ReplayTransportInteraction()
    /// Width of the scrubber row, for tap-to-seek and the buffered underlay.
    @State private var trackWidth: CGFloat = 0

    private static let speeds: [Double] = [1, 2, 4]

    private var upperBound: Double {
        ReplayTransportInteraction.sliderUpperBound(duration: duration)
    }

    private var position: Binding<Double> {
        Binding(
            get: {
                interaction.displayedPosition(current: controller.currentTime)
            },
            set: { target in
                controller.updateInteractiveSeekPosition(target)
                perform(interaction.update(
                    position: target,
                    buffered: buffered,
                    duration: duration,
                    isComplete: isComplete,
                    now: ProcessInfo.processInfo.systemUptime
                ))
            }
        )
    }

    private var activeMarker: SessionReplayMarker? {
        SessionReplayMarker.active(in: markers, at: position.wrappedValue)
    }

    private var previousMarker: SessionReplayMarker? {
        SessionReplayMarker.previous(in: markers, before: position.wrappedValue)
    }

    private var nextMarker: SessionReplayMarker? {
        SessionReplayMarker.next(in: markers, after: position.wrappedValue)
    }

    private var positionAccessibilityValue: String {
        var value = "\(SessionClock.spoken(position.wrappedValue)) of \(SessionClock.spoken(duration))"
        guard !markers.isEmpty else { return value }
        value += ". \(SessionReplayMarker.accessibilityCountDescription(markers.count))"
        if let activeMarker {
            value += ". Current key event: \(activeMarker.label)"
        }
        return value
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
        .onChange(of: buffered) { _, buffered in
            perform(interaction.coverageAdvanced(
                to: buffered,
                duration: duration,
                isComplete: isComplete
            ))
        }
        .onChange(of: isComplete) { _, isComplete in
            perform(interaction.coverageAdvanced(
                to: buffered,
                duration: duration,
                isComplete: isComplete
            ))
        }
        .onChange(of: scrubCancellationToken) { _, token in
            guard let token, interaction.cancel(ifMatching: token) else { return }
            controller.isScrubbing = false
            controller.cancelInteractiveSeek()
        }
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            if let bufferingStatus = interaction.bufferingStatus {
                Text(bufferingStatus)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(Theme.Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Buffering selected moment")
            } else if let active = activeMarker {
                Text(active.label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(Theme.Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack {
                scrubberSlider

                bufferedUnderlay

                ReplayMarkerTrack(markers: markers, duration: duration)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                trackWidth = width
            }
            // Simultaneous, not exclusive: drags still belong to the slider.
            // Before this, the only way to move an 85-minute recording was
            // dragging a 27pt knob — every video player on the platform seeks
            // on a track tap.
            .simultaneousGesture(trackTap)

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

    /// How much of the recording is actually seekable, drawn on the track
    /// itself. The number was always known — it drove the "Buffering selected
    /// moment…" deferral — but it was printed only as a footnote below the
    /// toggle, the one place a thumb on the scrubber is not looking.
    @ViewBuilder
    private var bufferedUnderlay: some View {
        if !isComplete, duration > 0, trackWidth > 28 {
            let fraction = min(1, max(0, buffered / duration))
            Capsule()
                .fill(Theme.accent.opacity(0.25))
                .frame(width: max(0, (trackWidth - 28) * fraction), height: 4)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var trackTap: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard controller.isReady, trackWidth > 28 else { return }
                let fraction = min(1, max(0, (value.location.x - 14) / (trackWidth - 28)))
                markerSeek(to: fraction * upperBound)
            }
    }

    @ViewBuilder
    private var scrubberSlider: some View {
        if let previous = previousMarker, let next = nextMarker {
            slider
                .accessibilityAction(named: Text("Previous key event")) {
                    markerSeek(to: previous.offset)
                }
                .accessibilityAction(named: Text("Next key event")) {
                    markerSeek(to: next.offset)
                }
        } else if let previous = previousMarker {
            slider.accessibilityAction(named: Text("Previous key event")) {
                markerSeek(to: previous.offset)
            }
        } else if let next = nextMarker {
            slider.accessibilityAction(named: Text("Next key event")) {
                markerSeek(to: next.offset)
            }
        } else {
            slider
        }
    }

    private var slider: some View {
        Slider(value: position, in: 0...upperBound, onEditingChanged: editingChanged)
            .tint(Theme.accent)
            .disabled(!controller.isReady)
            .accessibilityLabel(positionAccessibilityLabel)
            .accessibilityValue(positionAccessibilityValue)
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            guard !interaction.isEditing else { return }
            let effects = interaction.begin(
                position: controller.currentTime,
                duration: duration,
                isPlaying: controller.isPlaying
            )
            onScrubBegan(interaction.sliderGeneration)
            controller.isScrubbing = true
            perform(effects)
            return
        }

        guard interaction.isEditing else { return }
        controller.isScrubbing = false
        perform(interaction.end(
            buffered: buffered,
            duration: duration,
            isComplete: isComplete
        ))
    }

    private func markerSeek(to target: TimeInterval) {
        interaction.cancel()
        controller.isScrubbing = false
        controller.cancelInteractiveSeek()
        onMarkerSeek(target)
    }

    private func perform(_ effects: [ReplayTransportEffect]) {
        for effect in effects {
            switch effect {
            case .pause:
                controller.pause()
            case .preview(let target):
                onPreviewSeek(target)
            case .requestCoverage(let target):
                onCoverageRequested(target)
            case .commit(let target, let resume):
                onScrubCommitted(target, resume)
                controller.finishInteractiveSeek()
            }
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
