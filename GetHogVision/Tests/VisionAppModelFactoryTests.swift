import GetHogKit
import Testing

@testable import GetHog

#if DEBUG
@Suite("Vision app model factory")
@MainActor
struct VisionAppModelFactoryTests {

    @Test("forced keyless wins over demo mode and an environment credential")
    func forcedKeylessWins() async throws {
        let model = VisionAppModelFactory.makeModel(
            environment: [
                "GETHOG_FORCE_KEYLESS": "1",
                "GETHOG_API_KEY": "ignored-synthetic-key"
            ],
            demoModeEnabled: true
        )

        // Require both safety properties before bootstrap. If factory
        // precedence regresses, the test stops here rather than letting the
        // ignored environment credential reach a live transport.
        try #require(model.store is InMemoryTokenStore)
        try #require(model.isDemo)
        #expect(try model.store.load() == nil)

        await model.bootstrap()

        #expect(model.phase == .onboarding)
        #expect(model.client == nil)
    }

    @Test("only the exact debug flag activates the keyless override")
    func keylessFlagRequiresOne() {
        let model = VisionAppModelFactory.makeModel(
            environment: ["GETHOG_FORCE_KEYLESS": "true"],
            demoModeEnabled: false
        )

        #expect(model.store is KeychainTokenStore)
        #expect(!model.isDemo)
    }
}
#endif
