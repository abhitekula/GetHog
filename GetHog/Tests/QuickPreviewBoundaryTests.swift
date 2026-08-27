import Foundation
import GetHogKit
import SwiftUI
import Testing
import UIKit

@testable import GetHog

/// A real-client request recorder shared by Quick Preview lifecycle boundaries.
/// Later metadata-only preview tasks can mount their preview lifecycle against
/// the same zero-default harness and prove that no request was emitted.
private actor QuickPreviewRequestRecorder: HTTPTransport {
    private let response: Data?
    private let fallback: (any HTTPTransport)?
    private var requests: [URLRequest] = []

    init(response: Data) {
        self.response = response
        fallback = nil
    }

    init(forwarding fallback: any HTTPTransport) {
        response = nil
        self.fallback = fallback
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let response {
            return (
                response,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        guard let fallback else { throw PostHogError.transport("Missing synthetic preview response") }
        return try await fallback.send(request)
    }

    func reset() { requests.removeAll() }
    func recordedRequests() -> [URLRequest] { requests }
}

/// Synchronizes a real SwiftUI preview lifecycle before a bounded negative
/// observation interval. The interval is for observing ordinary descendant
/// `.task` scheduling, not for guessing when appearance happens.
private actor QuickPreviewLifecycleProbe {
    private var didAppear = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func appeared() {
        didAppear = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    func waitForAppearance() async {
        guard !didAppear else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct QuickPreviewLifecycleHost<Content: View>: View {
    let probe: QuickPreviewLifecycleProbe
    let content: Content

    init(
        probe: QuickPreviewLifecycleProbe,
        @ViewBuilder content: () -> Content
    ) {
        self.probe = probe
        self.content = content()
    }

    var body: some View {
        content.onAppear {
            Task {
                await probe.appeared()
            }
        }
    }
}

private struct UntrackedRequestPositiveControl: View {
    let recorder: QuickPreviewRequestRecorder

    var body: some View {
        Text("Untracked Quick Preview request control")
            .task {
                let client = PostHogClient(
                    auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
                    transport: recorder
                )
                let _: MeResponse? = try? await client.send(PostHogAPI.me())
            }
    }
}

@Suite("Quick Preview request boundaries")
@MainActor
struct QuickPreviewBoundaryTests {
    private static let observationWindow = Duration.milliseconds(250)

    @Test("the lifecycle host observes an ordinary descendant task request")
    func lifecycleHostObservesUntrackedDescendantRequest() async throws {
        let recorder = QuickPreviewRequestRecorder(forwarding: DemoTransport())
        let probe = QuickPreviewLifecycleProbe()
        let controller = UIHostingController(rootView: AnyView(
            QuickPreviewLifecycleHost(probe: probe) {
                UntrackedRequestPositiveControl(recorder: recorder)
            }
        ))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("The iOS test host has no window scene for the preview lifecycle.")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        await probe.waitForAppearance()
        await Self.observeQuiescence()
        let requests = await recorder.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.path == "/api/users/@me")
        window.isHidden = true
    }

    @Test("an event preview lifecycle emits no requests")
    func eventPreviewEmitsNoRequests() async throws {
        let recorder = QuickPreviewRequestRecorder(forwarding: DemoTransport())
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventQuickPreviewBoundary-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(
            store: InMemoryTokenStore(
                credential: StoredCredential(key: "demo", region: .usCloud)
            ),
            transport: recorder,
            snapshotStore: SharedSnapshotStore(directory: snapshotDirectory)
        )
        defer { try? FileManager.default.removeItem(at: snapshotDirectory) }

        await model.bootstrap()
        #expect(model.client != nil)
        await recorder.reset()

        let probe = QuickPreviewLifecycleProbe()
        let controller = UIHostingController(rootView: AnyView(
            QuickPreviewLifecycleHost(probe: probe) {
                EventQuickPreview(row: Self.event)
                    .environment(model)
            }
        ))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("The iOS test host has no window scene for the preview lifecycle.")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        await probe.waitForAppearance()
        await Self.observeQuiescence()
        #expect(await recorder.recordedRequests().isEmpty)
        window.isHidden = true
    }

    private static func observeQuiescence() async {
        // A negative-observation interval after actual appearance gives normal
        // SwiftUI descendant tasks an execution opportunity without blocking
        // the main actor or treating elapsed time as appearance evidence.
        try? await ContinuousClock().sleep(for: observationWindow)
    }

    @Test("insight activation emits one cached detail request and nothing else")
    func insightUsesOnlyCachedDetailRequest() async throws {
        let recorder = QuickPreviewRequestRecorder(response: Self.cachedInsight)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: recorder
        )
        let store = InsightQuickPreviewStore()
        let scope = InsightPreviewScope(
            authority: ResourceRequestAuthority(
                projectID: 1_001,
                region: .usCloud,
                authSessionID: UUID(
                    uuidString: "018F9000-0000-7000-8000-000000000720"
                )!
            ),
            insightID: 7_201
        )

        await store.activate(client: client, scope: scope)

        let requests = await recorder.recordedRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/projects/1001/insights/7201")
        #expect(
            URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                .queryItems == [URLQueryItem(name: "refresh", value: "force_cache")]
        )
        #expect(
            requests.allSatisfy { request in
                let components = request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)
                }
                let refresh = components?.queryItems?
                    .first(where: { $0.name == "refresh" })?.value
                return request.url?.path.hasSuffix("/query") != true
                    && refresh != "blocking"
                    && refresh != "lazy_async"
            }
        )
    }

    private static let cachedInsight = Data(
        #"""
        {
          "id": 7201,
          "name": "Synthetic cached preview",
          "is_cached": true,
          "query": {"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}},
          "result": [{"label":"Synthetic series","count":7,"data":[7],"days":["2026-08-26"]}]
        }
        """#.utf8
    )

    private static let event = EventRow(row: QueryRow(
        columns: ["uuid", "event", "timestamp", "distinct_id", "$current_url", "properties"],
        values: [
            .string("event-quick-preview-boundary"),
            .string("Synthetic signup"),
            .string("2026-08-27T14:15:30Z"),
            .string("synthetic-person-0001"),
            .string("https://example.invalid/account"),
            .object(["answer": .number(42)]),
        ]
    ))!
}
