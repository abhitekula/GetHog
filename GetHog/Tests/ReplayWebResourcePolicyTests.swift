import Foundation
import Network
import Testing
import WebKit

@testable import GetHog

@Suite("Replay WebKit resource policy", .serialized)
struct ReplayWebResourcePolicyTests {
    @Test("the offline resource policy compiles as a WebKit content rule list")
    @MainActor
    func policyCompiles() async throws {
        let rules = try await ReplayWebResourcePolicy.compile()

        #expect(rules.identifier == ReplayWebResourcePolicy.identifier)
    }

    @Test("a policy-install failure never authorizes the local replay shell")
    @MainActor
    func installationFailurePreventsLoad() async {
        let loader = ReplayWebDocumentLoader()
        var didLoadDocument = false
        var failureMessage: String?

        loader.start(
            installPolicy: { throw SyntheticPolicyError.installationFailed },
            loadDocument: { didLoadDocument = true },
            reportFailure: { failureMessage = $0 }
        )
        await loader.waitUntilIdle()

        #expect(!didLoadDocument)
        #expect(failureMessage == ReplayWebResourcePolicy.failureMessage)
    }

    @Test("teardown cancellation cannot load a shell after policy compilation returns")
    @MainActor
    func cancellationPreventsLateLoad() async {
        let gate = SyntheticPolicyGate()
        let loader = ReplayWebDocumentLoader()
        var didLoadDocument = false
        var failureMessage: String?

        loader.start(
            installPolicy: { await gate.wait() },
            loadDocument: { didLoadDocument = true },
            reportFailure: { failureMessage = $0 }
        )
        await gate.waitUntilInstallationStarts()
        loader.cancel()
        await gate.release()
        await loader.waitUntilIdle()

        #expect(!didLoadDocument)
        #expect(failureMessage == nil)
    }

    @Test("a protected local document cannot reach a recorded remote asset handler")
    @MainActor
    func remoteAssetIsBlockedBeforeRequest() async throws {
        let probe = try await SyntheticLoopbackHTTPProbe.start()
        defer { probe.stop() }

        let bridge = SyntheticPageBridge()
        let configuration = WKWebViewConfiguration()
        let rules = try await ReplayWebResourcePolicy.compile()
        configuration.userContentController.add(rules)
        configuration.userContentController.add(bridge, name: "policyTest")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let html = """
            <!doctype html>
            <meta charset="utf-8">
            <img id="recorded-asset"
                 src="http://127.0.0.1:\(probe.port)/recorded-page.png">
            <script>
              const image = document.getElementById("recorded-asset");
              image.onload = () => window.webkit.messageHandlers.policyTest.postMessage("loaded");
              image.onerror = () => window.webkit.messageHandlers.policyTest.postMessage("blocked");
            </script>
            """

        webView.loadHTMLString(
            html,
            baseURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
        let outcome = await bridge.nextMessage()
        try await Task.sleep(for: .milliseconds(250))

        #expect(outcome == "blocked")
        #expect(probe.requestCount == 0)
        configuration.userContentController.removeScriptMessageHandler(forName: "policyTest")
    }
}

private enum SyntheticPolicyError: Error {
    case installationFailed
}

private actor SyntheticPolicyGate {
    private var didStart = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func waitUntilInstallationStarts() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func wait() async {
        didStart = true
        startWaiter?.resume()
        startWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class SyntheticPageBridge: NSObject, WKScriptMessageHandler {
    private var message: String?
    private var waiter: CheckedContinuation<String, Never>?

    func nextMessage() async -> String {
        if let message { return message }
        return await withCheckedContinuation { waiter = $0 }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let value = message.body as? String else { return }
        self.message = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}

private final class SyntheticLoopbackHTTPProbe: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.gethog.tests.replay-resource-probe")
    private let lock = NSLock()
    private var requests = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    static func start() async throws -> SyntheticLoopbackHTTPProbe {
        let probe = SyntheticLoopbackHTTPProbe(
            listener: try NWListener(using: .tcp, on: .any)
        )
        try await probe.startListening()
        return probe
    }

    func stop() {
        listener.cancel()
    }

    private func startListening() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.requests += 1 }
            connection.cancel()
        }

        try await withCheckedThrowingContinuation { continuation in
            let resumeGate = SyntheticOneShotGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeGate.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard resumeGate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

private final class SyntheticOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }
}
