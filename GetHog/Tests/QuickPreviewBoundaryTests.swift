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

/// Synchronizes a real SwiftUI preview lifecycle without guessing a delay.
/// Later metadata-only previews declare their descendant task count and use the
/// tracked modifier, so the host cannot return before those tasks have run.
private actor QuickPreviewLifecycleBarrier {
    private let expectedDescendantTasks: Int
    private var hostTaskStarted = false
    private var startedDescendantTasks = 0
    private var finishedDescendantTasks = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedDescendantTasks: Int) {
        self.expectedDescendantTasks = expectedDescendantTasks
    }

    func hostTaskDidStart() {
        hostTaskStarted = true
        resumeWaitersIfSettled()
    }

    func descendantTaskDidStart() {
        startedDescendantTasks += 1
    }

    func descendantTaskDidFinish() {
        finishedDescendantTasks += 1
        resumeWaitersIfSettled()
    }

    func waitForSettledLifecycle() async {
        guard !isSettled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private var isSettled: Bool {
        hostTaskStarted
            && startedDescendantTasks == expectedDescendantTasks
            && finishedDescendantTasks == expectedDescendantTasks
    }

    private func resumeWaitersIfSettled() {
        guard isSettled else { return }
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private struct QuickPreviewLifecycleHost<Content: View>: View {
    let barrier: QuickPreviewLifecycleBarrier
    let content: Content

    init(
        barrier: QuickPreviewLifecycleBarrier,
        @ViewBuilder content: (QuickPreviewLifecycleBarrier) -> Content
    ) {
        self.barrier = barrier
        self.content = content(barrier)
    }

    var body: some View {
        content.task {
            await barrier.hostTaskDidStart()
        }
    }
}

private struct QuickPreviewDescendantTask: ViewModifier {
    let barrier: QuickPreviewLifecycleBarrier
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.task {
            await barrier.descendantTaskDidStart()
            await action()
            await barrier.descendantTaskDidFinish()
        }
    }
}

private extension View {
    func quickPreviewDescendantTask(
        barrier: QuickPreviewLifecycleBarrier,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(QuickPreviewDescendantTask(barrier: barrier, action: action))
    }
}

private struct RequestingQuickPreviewPositiveControl: View {
    let barrier: QuickPreviewLifecycleBarrier
    let recorder: QuickPreviewRequestRecorder

    var body: some View {
        Text("Quick Preview request control")
            .quickPreviewDescendantTask(barrier: barrier) {
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
    @Test("the lifecycle host waits for a descendant task request")
    func lifecycleHostObservesDescendantRequest() async throws {
        let recorder = QuickPreviewRequestRecorder(forwarding: DemoTransport())
        let barrier = QuickPreviewLifecycleBarrier(expectedDescendantTasks: 1)
        let controller = UIHostingController(rootView: AnyView(
            QuickPreviewLifecycleHost(barrier: barrier) { barrier in
                RequestingQuickPreviewPositiveControl(barrier: barrier, recorder: recorder)
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

        await barrier.waitForSettledLifecycle()
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

        let barrier = QuickPreviewLifecycleBarrier(expectedDescendantTasks: 0)
        let controller = UIHostingController(rootView: AnyView(
            QuickPreviewLifecycleHost(barrier: barrier) { _ in
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

        await barrier.waitForSettledLifecycle()
        #expect(await recorder.recordedRequests().isEmpty)
        window.isHidden = true
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
