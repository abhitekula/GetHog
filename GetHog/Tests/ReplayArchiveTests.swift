import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay event archive")
struct ReplayArchiveTests {
    @Test("incremental delivery uses fetched batches when a later range sorts earlier")
    @MainActor
    func incrementalDeliveryDoesNotSliceTheSortedArchive() {
        var ledger = ReplayArchiveDeliveryLedger()
        let firstBatch = [
            event("first-40", at: 40_000),
            event("first-50", at: 50_000),
        ]
        ledger.append(firstBatch)

        let boot = ledger.delivery(sortedArchive: firstBatch, after: nil)
        #expect(boot.mode == .restart)
        #expect(boot.events.map(\.windowID) == ["first-40", "first-50"])

        let secondBatch = [
            event("second-1", at: 1_000),
            event("second-50", at: 50_000),
        ]
        ledger.append(secondBatch)
        let globallySorted = ReplayLoader.mergedArchivedEvents(firstBatch, with: secondBatch)

        let incremental = ledger.delivery(sortedArchive: globallySorted, after: boot.cursor)
        #expect(incremental.mode == .append)
        #expect(incremental.events.map(\.windowID) == ["second-1", "second-50"])
    }

    @Test("delivery restarts after archive reset and recovers from a smaller count")
    @MainActor
    func deliveryRecoversAfterResetAndCountShrink() {
        var ledger = ReplayArchiveDeliveryLedger()
        let original = [
            event("old-1", at: 1_000),
            event("old-2", at: 2_000),
        ]
        ledger.append(original)
        let oldCursor = ledger.delivery(sortedArchive: original, after: nil).cursor

        ledger.reset()
        let reset = ledger.delivery(sortedArchive: [], after: oldCursor)
        #expect(reset.mode == .restart)
        #expect(reset.events.isEmpty)
        #expect(reset.cursor.generation != oldCursor.generation)
        #expect(reset.cursor.batchIndex == 0)

        let replacement = [event("new-1", at: 500)]
        ledger.append(replacement)
        let recovered = ledger.delivery(sortedArchive: replacement, after: reset.cursor)
        #expect(recovered.mode == .append)
        #expect(recovered.events.map(\.windowID) == ["new-1"])
    }

    @Test("the archive merge preserves each source's equal-timestamp order")
    @MainActor
    func stableArchiveMergePreservesTieOrder() {
        let existing = [
            event("range-one-before", at: 1_000),
            event("range-one-first-tie", at: 50_000),
            event("range-one-second-tie", at: 50_000),
        ]
        let incoming = [
            event("range-two-before", at: 2_000),
            event("range-two-first-tie", at: 50_000),
            event("range-two-second-tie", at: 50_000),
        ]

        let merged = ReplayLoader.mergedArchivedEvents(existing, with: incoming)

        #expect(
            merged.map(\.windowID)
                == [
                    "range-one-before", "range-two-before",
                    "range-one-first-tie", "range-one-second-tie",
                    "range-two-first-tie", "range-two-second-tie",
                ]
        )
    }

    @Test("the archive keeps source order for equal timestamps across blob ranges")
    @MainActor
    func archiveIsChronologicalAcrossRanges() async throws {
        let loader = ReplayLoader()
        await loader.start(
            client: client(transport: ArchiveRangeTransport()),
            projectID: 1_001,
            recording: try recording()
        )

        #expect(loader.loadedRangeCount == 2)
        #expect(loader.archivedEvents.map(\.timestamp) == [1_000, 40_000, 50_000, 50_000])
        #expect(
            loader.archivedEvents.map(\.windowID)
                == ["range-two-before", "range-one-before", "range-one-tie", "range-two-tie"]
        )
    }

    @Test("reset prevents a suspended snapshot fetch from repopulating replay state")
    @MainActor
    func resetIgnoresSuspendedFetch() async throws {
        let transport = SuspendedBlobTransport()
        let loader = ReplayLoader()
        let replay = try recording()
        let load = Task {
            await loader.start(
                client: client(transport: transport),
                projectID: 1_001,
                recording: replay
            )
        }

        await transport.waitForBlobRequest()
        loader.reset()
        await transport.releaseBlob()
        await load.value

        #expect(loader.archivedEvents.isEmpty)
        #expect(loader.pending.isEmpty)
    }

    @Test("draining player events does not erase the full-screen archive")
    @MainActor
    func drainKeepsArchive() async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
        let recording: SessionRecording = try await client.send(
            PostHogAPI.sessionRecording(
                projectID: 1_001,
                recordingID: "018f1000-0000-7000-8000-000000000001"
            )
        )
        let loader = ReplayLoader()
        await loader.start(client: client, projectID: 1_001, recording: recording)

        let archived = loader.archivedEvents
        #expect(archived.count >= 2)
        #expect(archived.map(\.timestamp) == archived.map(\.timestamp).sorted())
        #expect(loader.drainPending().count == archived.count)
        #expect(loader.archivedEvents == archived)

        loader.reset()
        #expect(loader.archivedEvents.isEmpty)
        #expect(loader.archivedEventCount == 0)
    }

    private func client(transport: some HTTPTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: transport
        )
    }

    private func recording() throws -> SessionRecording {
        try JSONDecoder().decode(
            SessionRecording.self,
            from: Data(
                #"{"id":"archive-demo","snapshot_source":"web"}"#.utf8
            )
        )
    }

    private func event(_ windowID: String, at timestamp: Double) -> SnapshotEvent {
        SnapshotEvent(windowID: windowID, type: 3, timestamp: timestamp, event: .object([:]))
    }
}

private actor ArchiveRangeTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "start_blob_key" })?
            .value

        switch key {
        case nil:
            return response(for: request, data: listing)
        case "0":
            return response(for: request, data: laterEvents)
        case "20":
            return response(for: request, data: earlierEvents)
        default:
            throw PostHogError.transport("Unexpected synthetic blob range")
        }
    }

    private var listing: Data {
        let sources = (0...20).map { #"{"source":"blob_v2","blob_key":"\#($0)"}"# }
        return Data(#"{"sources":[\#(sources.joined(separator: ","))]}"#.utf8)
    }

    private var laterEvents: Data {
        Data(
            """
            ["range-one-before",{"type":2,"timestamp":40000,"data":{}}]
            ["range-one-tie",{"type":3,"timestamp":50000,"data":{}}]
            """.utf8
        )
    }

    private var earlierEvents: Data {
        Data(
            """
            ["range-two-before",{"type":3,"timestamp":1000,"data":{}}]
            ["range-two-tie",{"type":3,"timestamp":50000,"data":{}}]
            """.utf8
        )
    }
}

private actor SuspendedBlobTransport: HTTPTransport {
    private var blobRequestStarted = false
    private var waitForBlobRequest: CheckedContinuation<Void, Never>?
    private var blobGate: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    func waitForBlobRequest() async {
        guard !blobRequestStarted else { return }
        await withCheckedContinuation { waitForBlobRequest = $0 }
    }

    func releaseBlob() {
        releaseRequested = true
        blobGate?.resume()
        blobGate = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isBlobRequest = request.url?.query?.contains("start_blob_key") == true
        guard isBlobRequest else {
            return response(for: request, data: listing)
        }

        blobRequestStarted = true
        waitForBlobRequest?.resume()
        waitForBlobRequest = nil
        await withCheckedContinuation { continuation in
            if releaseRequested {
                continuation.resume()
            } else {
                blobGate = continuation
            }
        }
        return response(for: request, data: events)
    }

    private var listing: Data {
        Data(#"{"sources":[{"source":"blob_v2","blob_key":"0"}]}"#.utf8)
    }

    private var events: Data {
        Data(
            """
            ["archive-demo",{"type":2,"timestamp":1000,"data":{}}]
            ["archive-demo",{"type":3,"timestamp":2000,"data":{}}]
            """.utf8
        )
    }
}

private func response(for request: URLRequest, data: Data) -> (Data, HTTPURLResponse) {
    (
        data,
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}
