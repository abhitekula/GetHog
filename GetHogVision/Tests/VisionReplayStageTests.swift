import Foundation
import Testing
import WebKit

@testable import GetHog

/// The three facts the Vision replay stage stands on that no iOS or Mac test
/// can falsify for it: the player bundle has to ride in *this* app, WebKit's
/// rule-list compiler has to work in *this* process, and the configuration the
/// shared builder hands the web view has to keep media inline here — the one
/// WebKit presentation path visionOS genuinely breaks is the fullscreen one.
@MainActor
@Suite("Vision replay stage", .serialized)
struct VisionReplayStageTests {

    /// Playback dies exactly this way: the resource folder rides along through
    /// the target's `GetHog/Resources` entry, and if that ever narrows, the
    /// stage loads nothing and reports a missing asset. Nothing else in the
    /// app notices, so this is the only alarm.
    @Test("the rrweb player bundle rides in this app")
    func playerAssetsShip() {
        #expect(ReplayAssets.isComplete)
    }

    /// The stage refuses to load the document until the offline rule list is
    /// installed, so a `WKContentRuleListStore` that does not work on xrOS is
    /// a player that never starts. Compiling it is the only way to know.
    @Test("the offline resource policy compiles on visionOS")
    func resourcePolicyCompiles() async throws {
        let rules = try await ReplayWebResourcePolicy.compile()

        #expect(rules.identifier == ReplayWebResourcePolicy.identifier)
    }

    /// Pins the inline-media decision against a future re-narrowing to
    /// `#if os(iOS)`: a recorded page can carry `<video>`, and the default
    /// steers it into the fullscreen presentation this platform handles worst.
    /// The user-action gate is asserted alongside it because the two travel
    /// together — inline playback that could autoplay would be a different,
    /// worse setting.
    @Test("the stage configuration keeps media inline and silent")
    func stageConfigurationKeepsMediaInline() {
        let configuration = ReplayStageBuilder.makeConfiguration(
            bridge: ReplayWebBridge(),
            controller: ReplayPlayerController()
        )
        #expect(configuration.allowsInlineMediaPlayback)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .all)
    }
}
