import Foundation
import Testing

@testable import GetHogKit

@Suite("Session recordings")
struct SessionRecordingTests {

    @Test("decodes the recording list")
    func decodesList() throws {
        let page = try Page<SessionRecording>.decode(from: Fixture.data("session_recordings.json"))
        let first = try #require(page.results.first)

        #expect(page.results.map(\.id) == [
            "018f1000-0000-7000-8000-000000000001",
            "018f1000-0000-7000-8000-000000000002",
            "018f1000-0000-7000-8000-000000000003",
            "018f1000-0000-7000-8000-000000000004",
            "018f1000-0000-7000-8000-000000000005",
        ])
        #expect(first.id == "018f1000-0000-7000-8000-000000000001")
        #expect(first.recordingDuration == 10)
        #expect(first.clickCount == 1)
        #expect(first.consoleErrorCount == 0)
        #expect(first.startURL == "https://app.example.com/dashboard")
        #expect(first.startTime != nil)
    }

    @Test("identifies web recordings as replayable and mobile ones as not")
    func replayability() throws {
        let page = try Page<SessionRecording>.decode(from: Fixture.data("session_recordings.json"))
        let first = try #require(page.results.first)

        // Mobile replay needs PostHog's closed-source transform, so only web
        // sessions may be handed to the bundled rrweb player.
        #expect(first.snapshotSource == "web")
        #expect(first.isReplayable)
    }

    @Test("exposes a person display name")
    func personName() throws {
        let page = try Page<SessionRecording>.decode(from: Fixture.data("session_recordings.json"))
        let first = try #require(page.results.first)
        #expect(first.personDisplayName == "Alex Example")
    }
}

@Suite("Feature flags")
struct FeatureFlagTests {

    @Test("decodes flags with key and active state")
    func decodesFlags() throws {
        let page = try Page<FeatureFlag>.decode(from: Fixture.data("feature_flags.json"))
        let first = try #require(page.results.first)

        #expect(first.id == 710301)
        #expect(page.results.map(\.id) == [
            710301, 710302, 710303, 710304, 710305, 710306, 710307, 710308, 710399,
        ])
        #expect(first.key == "example-navigation")
        #expect(first.active)
        #expect(!first.archived)
    }

    @Test("quick toggle is opt-in and therefore off for a freshly decoded flag")
    func quickToggleDefaultsOff() throws {
        let page = try Page<FeatureFlag>.decode(from: Fixture.data("feature_flags.json"))
        let first = try #require(page.results.first)

        // Nothing reaches Control Center or an interactive widget without an
        // explicit in-app opt-in; the server has no such concept.
        #expect(!first.allowsQuickToggle)
    }
}
