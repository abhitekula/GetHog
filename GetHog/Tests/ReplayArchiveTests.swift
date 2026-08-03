import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay event archive")
struct ReplayArchiveTests {
    @Test("the archive merges events across out-of-order blob ranges")
    @MainActor
    func archiveIsChronologicalAcrossRanges() async throws {
        let loader = ReplayLoader()
        await loader.start(
            client: client(transport: ArchiveRangeTransport()),
            projectID: 1_001,
            recording: try recording()
        )

        #expect(loader.loadedRangeCount == 2)
        #expect(loader.archivedEvents.map(\.timestamp) == [1_000, 2_000, 40_000, 41_000])
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
            ["archive-demo",{"type":2,"timestamp":40000,"data":{}}]
            ["archive-demo",{"type":3,"timestamp":41000,"data":{}}]
            """.utf8
        )
    }

    private var earlierEvents: Data {
        Data(
            """
            ["archive-demo",{"type":3,"timestamp":1000,"data":{}}]
            ["archive-demo",{"type":3,"timestamp":2000,"data":{}}]
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
