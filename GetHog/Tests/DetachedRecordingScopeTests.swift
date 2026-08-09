import Foundation
import GetHogKit
import Testing

@testable import GetHog

private actor HeldDetachedRecordingTransport: HTTPTransport {
    private struct Request: Sendable {
        let url: URL
        let projectID: Int
        let host: String
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    }

    private var requests: [Request] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let projectID = try #require(
            url.pathComponents
                .drop(while: { $0 != "projects" })
                .dropFirst()
                .first
                .flatMap(Int.init)
        )
        let host = try #require(url.host())

        return try await withCheckedThrowingContinuation { continuation in
            requests.append(
                Request(
                    url: url,
                    projectID: projectID,
                    host: host,
                    continuation: continuation
                )
            )
            resumeSatisfiedWaiters()
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func succeed(_ index: Int, recordingID: String, person: String) {
        respond(
            index,
            statusCode: 200,
            body: Self.recordingJSON(id: recordingID, person: person)
        )
    }

    func fail(_ index: Int, statusCode: Int, detail: String) {
        respond(
            index,
            statusCode: statusCode,
            body: Data("{\"detail\":\"\(detail)\"}".utf8)
        )
    }

    func projectIDs() -> [Int] {
        requests.map(\.projectID)
    }

    func hosts() -> [String] {
        requests.map(\.host)
    }

    private func respond(_ index: Int, statusCode: Int, body: Data) {
        let request = requests[index]
        request.continuation.resume(
            returning: (
                body,
                HTTPURLResponse(
                    url: request.url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        )
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = requestWaiters.filter { requests.count >= $0.count }
        requestWaiters.removeAll { requests.count >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }

    private static func recordingJSON(id: String, person: String) -> Data {
        Data(
            """
            {"id":"\(id)","distinct_id":"\(person)","snapshot_source":"web",\
            "recording_duration":30,"start_url":"https://example.invalid/synthetic"}
            """.utf8
        )
    }
}

@Suite("Detached recording authority")
@MainActor
struct DetachedRecordingScopeTests {
    @Test("a project switch publishes replacement loading before suspension")
    func projectSwitchPublishesReplacementLoadingBeforeAwait() async {
        let transport = HeldDetachedRecordingTransport()
        let client = Self.client(region: .usCloud, transport: transport)
        let store = DetachedRecordingStore()
        let scopeA = Self.scope(projectID: 1, region: .usCloud, epoch: Self.epochA)
        let scopeB = Self.scope(projectID: 2, region: .usCloud, epoch: Self.epochA)

        let firstLoad = Task {
            await store.load(client: client, recordingID: "recording-a", scope: scopeA)
        }
        await transport.waitForRequestCount(1)
        await transport.succeed(0, recordingID: "recording-a", person: "person-a")
        await firstLoad.value

        guard case .loaded(let loadedScopeA, let recordingA) = store.state else {
            Issue.record("Expected the first recording to load")
            return
        }
        #expect(loadedScopeA == scopeA)
        #expect(recordingA.id == "recording-a")

        let replacementLoad = Task {
            await store.load(client: client, recordingID: "recording-b", scope: scopeB)
        }
        await transport.waitForRequestCount(2)

        #expect(store.state == .loading(scopeB))
        #expect(await transport.projectIDs() == [1, 2])

        await transport.succeed(1, recordingID: "recording-b", person: "person-b")
        await replacementLoad.value

        guard case .loaded(let loadedScopeB, let recordingB) = store.state else {
            Issue.record("Expected the replacement recording to load")
            return
        }
        #expect(loadedScopeB == scopeB)
        #expect(recordingB.id == "recording-b")
        #expect(await transport.projectIDs() == [1, 2])
    }

    @Test("replacement failure and retry stay in the replacement scope")
    func replacementFailureAndRetryStayInReplacementScope() async {
        let transport = HeldDetachedRecordingTransport()
        let client = Self.client(region: .usCloud, transport: transport)
        let store = DetachedRecordingStore()
        let scopeA = Self.scope(projectID: 1, region: .usCloud, epoch: Self.epochA)
        let scopeB = Self.scope(projectID: 2, region: .usCloud, epoch: Self.epochA)

        let firstLoad = Task {
            await store.load(client: client, recordingID: "recording-a", scope: scopeA)
        }
        await transport.waitForRequestCount(1)
        await transport.succeed(0, recordingID: "recording-a", person: "person-a")
        await firstLoad.value

        let failedReplacement = Task {
            await store.load(client: client, recordingID: "recording-b", scope: scopeB)
        }
        await transport.waitForRequestCount(2)
        #expect(store.state == .loading(scopeB))
        await transport.fail(1, statusCode: 503, detail: "Synthetic replacement outage")
        await failedReplacement.value

        guard case .failed(let failedScope, let message) = store.state else {
            Issue.record("Expected only the replacement failure to remain visible")
            return
        }
        #expect(failedScope == scopeB)
        #expect(message == "Synthetic replacement outage")

        let retry = Task {
            await store.load(client: client, recordingID: "recording-b", scope: scopeB)
        }
        await transport.waitForRequestCount(3)
        #expect(store.state == .loading(scopeB))
        await transport.succeed(2, recordingID: "recording-b", person: "person-b")
        await retry.value

        guard case .loaded(let loadedScope, let recording) = store.state else {
            Issue.record("Expected the replacement retry to load")
            return
        }
        #expect(loadedScope == scopeB)
        #expect(recording.id == "recording-b")
        #expect(recording.distinctID == "person-b")
        #expect(await transport.projectIDs() == [1, 2, 2])
    }

    @Test("a late completion cannot cross a same-id region or epoch replacement")
    func lateCompletionCannotCrossSameIDRegionOrEpochReplacement() async {
        let transport = HeldDetachedRecordingTransport()
        let usClient = Self.client(region: .usCloud, transport: transport)
        let euClient = Self.client(region: .euCloud, transport: transport)
        let store = DetachedRecordingStore()
        let scopeA = Self.scope(projectID: 1_001, region: .usCloud, epoch: Self.epochA)
        let scopeB = Self.scope(projectID: 1_001, region: .euCloud, epoch: Self.epochB)

        let oldLoad = Task {
            await store.load(client: usClient, recordingID: "shared-recording", scope: scopeA)
        }
        await transport.waitForRequestCount(1)

        let replacementLoad = Task {
            await store.load(client: euClient, recordingID: "shared-recording", scope: scopeB)
        }
        await transport.waitForRequestCount(2)
        oldLoad.cancel()

        await transport.succeed(1, recordingID: "shared-recording", person: "eu-person")
        await replacementLoad.value

        let replacementSnapshot = Self.loadedSnapshot(store.state)
        #expect(replacementSnapshot?.scope == scopeB)
        #expect(replacementSnapshot?.recording.distinctID == "eu-person")

        await transport.succeed(0, recordingID: "shared-recording", person: "us-person")
        await oldLoad.value

        let finalSnapshot = Self.loadedSnapshot(store.state)
        #expect(finalSnapshot?.scope == scopeB)
        #expect(finalSnapshot?.recording.distinctID == "eu-person")
        #expect(await transport.projectIDs() == [1_001, 1_001])
        #expect(await transport.hosts() == ["us.posthog.com", "eu.posthog.com"])

        let uncancelledTransport = HeldDetachedRecordingTransport()
        let uncancelledUSClient = Self.client(region: .usCloud, transport: uncancelledTransport)
        let uncancelledEUClient = Self.client(region: .euCloud, transport: uncancelledTransport)
        let uncancelledStore = DetachedRecordingStore()

        let uncancelledOldLoad = Task {
            await uncancelledStore.load(
                client: uncancelledUSClient,
                recordingID: "shared-recording",
                scope: scopeA
            )
        }
        await uncancelledTransport.waitForRequestCount(1)

        let uncancelledReplacementLoad = Task {
            await uncancelledStore.load(
                client: uncancelledEUClient,
                recordingID: "shared-recording",
                scope: scopeB
            )
        }
        await uncancelledTransport.waitForRequestCount(2)

        await uncancelledTransport.succeed(
            1,
            recordingID: "shared-recording",
            person: "uncancelled-eu-person"
        )
        await uncancelledReplacementLoad.value

        let uncancelledReplacementSnapshot = Self.loadedSnapshot(uncancelledStore.state)
        #expect(uncancelledReplacementSnapshot?.scope == scopeB)
        #expect(
            uncancelledReplacementSnapshot?.recording.distinctID
                == "uncancelled-eu-person"
        )

        await uncancelledTransport.succeed(
            0,
            recordingID: "shared-recording",
            person: "uncancelled-us-person"
        )
        await uncancelledOldLoad.value

        let uncancelledFinalSnapshot = Self.loadedSnapshot(uncancelledStore.state)
        #expect(uncancelledFinalSnapshot?.scope == scopeB)
        #expect(
            uncancelledFinalSnapshot?.recording.distinctID
                == "uncancelled-eu-person"
        )
        #expect(await uncancelledTransport.projectIDs() == [1_001, 1_001])
        #expect(
            await uncancelledTransport.hosts()
                == ["us.posthog.com", "eu.posthog.com"]
        )
    }

    private static let epochA = UUID(uuidString: "018f9000-0000-7000-8000-000000000504")!
    private static let epochB = UUID(uuidString: "018f9000-0000-7000-8000-000000000505")!

    private static func client(
        region: PostHogRegion,
        transport: some HTTPTransport
    ) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: region),
            transport: transport
        )
    }

    private static func scope(
        projectID: Int,
        region: PostHogRegion,
        epoch: UUID
    ) -> FlagWriteScope {
        FlagWriteScope(
            projectID: projectID,
            projectRegion: region,
            authSessionID: epoch
        )
    }

    private static func loadedSnapshot(
        _ state: DetachedRecordingStore.State
    ) -> (scope: FlagWriteScope, recording: SessionRecording)? {
        guard case .loaded(let scope, let recording) = state else { return nil }
        return (scope, recording)
    }
}
