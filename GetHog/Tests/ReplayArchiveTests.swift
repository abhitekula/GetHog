import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay event archive")
struct ReplayArchiveTests {
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
}
