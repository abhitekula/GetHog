import GetHogKit
import Testing

@Suite("TV scope guidance")
struct TVScopeGuidanceTests {

    @Test("the current-platform Settings projection contains no writes on Apple TV")
    func currentPlatformHasNoWrites() {
        #expect(APIKeyScopeGuidance.currentPlatformOptionalWriteActions.isEmpty)
    }
}
