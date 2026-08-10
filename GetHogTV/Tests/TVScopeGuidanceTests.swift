import GetHogKit
import Testing

@Suite("TV scope guidance")
struct TVScopeGuidanceTests {

    @Test("the current-platform Settings projection contains only the live flag toggle")
    func currentPlatformContainsOnlyFeatureFlagWrites() {
        let renderedScopes = APIKeyScopeGuidance.currentPlatformOptionalWriteActions.map(\.scope)

        #expect(renderedScopes == ["feature_flag:write"])
    }
}
