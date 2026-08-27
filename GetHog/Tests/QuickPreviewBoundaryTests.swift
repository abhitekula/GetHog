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
/// Later metadata-only previews can reuse this host and assertion window.
private actor QuickPreviewLifecycleProbe {
    private var hasSettledAppearance = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func settledAppearance() {
        hasSettledAppearance = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    func waitForSettledAppearance() async {
        guard !hasSettledAppearance else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct QuickPreviewLifecycleHost<Content: View>: View {
    let probe: QuickPreviewLifecycleProbe
    let content: Content

    init(probe: QuickPreviewLifecycleProbe, @ViewBuilder content: () -> Content) {
        self.probe = probe
        self.content = content()
    }

    var body: some View {
        content.onAppear {
            Task {
                await Task.yield()
                await probe.settledAppearance()
            }
        }
    }
}

@Suite("Quick Preview request boundaries")
@MainActor
struct QuickPreviewBoundaryTests {
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

        await probe.waitForSettledAppearance()
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
