import Foundation
import GetHogKit
import Testing

@testable import GetHog

private actor HeldReplayRetryTransport: HTTPTransport {
    private let demo = DemoTransport()
    private var sourceRequests = 0
    private var retryStarted = false
    private var retryReleased = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseGate: CheckedContinuation<Void, Never>?

    func waitForRetrySource() async {
        guard !retryStarted else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func releaseRetrySource() {
        retryReleased = true
        releaseGate?.resume()
        releaseGate = nil
    }

    func sourceRequestCount() -> Int { sourceRequests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        let query = request.url?.query ?? ""
        let isSourceList = path.contains("/snapshots") && !query.contains("blob_v2")
        guard isSourceList else { return try await demo.send(request) }

        sourceRequests += 1
        if sourceRequests == 1 {
            return (
                Data(#"{"detail":"Synthetic initial replay failure"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }

        if sourceRequests == 2 {
            retryStarted = true
            startWaiter?.resume()
            startWaiter = nil
            if !retryReleased {
                await withCheckedContinuation { releaseGate = $0 }
            }
        }

        return try await demo.send(request)
    }
}

@Suite("TV replay retry")
struct TVReplayRetryTests {
    @Test("concurrent retry callers spend one replacement request and publish ready")
    @MainActor
    func concurrentRetriesShareOneFlight() async throws {
        let transport = HeldReplayRetryTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )
        let recording: SessionRecording = try await client.send(
            PostHogAPI.sessionRecording(
                projectID: 1_001,
                recordingID: "018f1000-0000-7000-8000-000000000001"
            )
        )
        let loader = ReplayLoader()

        await loader.start(client: client, projectID: 1_001, recording: recording)
        guard case .unavailable = loader.availability else {
            Issue.record("the synthetic initial source request did not fail")
            return
        }

        let leader = Task { @MainActor in
            await loader.retryUnavailable(
                client: client,
                projectID: 1_001,
                recording: recording
            )
        }
        await transport.waitForRetrySource()

        let follower = Task { @MainActor in
            await loader.retryUnavailable(
                client: client,
                projectID: 1_001,
                recording: recording
            )
        }
        await follower.value
        await transport.releaseRetrySource()
        await leader.value

        let sourceRequestCount = await transport.sourceRequestCount()
        #expect(sourceRequestCount == 2)
        #expect(loader.availability == .ready)
    }
}
