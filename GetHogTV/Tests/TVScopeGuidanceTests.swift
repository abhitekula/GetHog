import GetHogKit
import Testing

@Suite("TV scope guidance")
struct TVScopeGuidanceTests {

    @Test("the current-platform Settings projection contains only the live flag toggle")
    func currentPlatformContainsOnlyFeatureFlagWrites() {
        let descriptors = APIKeyScopeGuidance.currentPlatformOptionalWriteActions

        #expect(descriptors.count == 1)
        #expect(descriptors.first?.action == "Toggle feature flags")
        #expect(descriptors.first?.scope == "feature_flag:write")
        #expect(descriptors.allSatisfy { !$0.action.localizedCaseInsensitiveContains("rollout") })
    }
}
