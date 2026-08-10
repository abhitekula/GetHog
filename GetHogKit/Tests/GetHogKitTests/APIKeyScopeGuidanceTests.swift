import Testing

@testable import GetHogKit

@Suite("API key scope guidance")
struct APIKeyScopeGuidanceTests {

    @Test("the onboarding baseline contains only the core read contract")
    func onboardingUsesCoreReadsOnly() {
        #expect(APIKeyScopeGuidance.coreReadScopes.allSatisfy { $0.kind == .coreRead })
        #expect(Set(APIKeyScopeGuidance.coreReadScopes.map(\.id)).count == APIKeyScopeGuidance.coreReadScopes.count)
    }

    @Test("every named write action resolves to one unique optional descriptor")
    func namedWriteActionsResolveUniquely() {
        let descriptors = APIKeyScopeGuidance.OptionalWriteAction.allCases.map {
            APIKeyScopeGuidance.optionalWriteDescriptor(for: $0)
        }

        #expect(descriptors.allSatisfy { $0.kind == .optionalWrite })
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(descriptors == APIKeyScopeGuidance.optionalWriteActions(for: .fullClient))
    }

    @Test("Apple TV advertises no write action its read-only shell cannot perform")
    func appleTVHasNoOptionalWrites() {
        #expect(APIKeyScopeGuidance.optionalWriteActions(for: .appleTV).isEmpty)
    }

    @Test("locked resource recovery falls back to the same core read scopes")
    func lockedRecoveryUsesCoreReads() {
        let report = CapabilityReport(results: [
            .dashboards: .locked(scope: nil),
            .events: .locked(scope: nil),
            .sessions: .locked(scope: nil),
            .flags: .locked(scope: nil),
            .replay: .locked(scope: nil),
        ])

        #expect(report.lockedScope(for: .dashboards) == "dashboard:read, insight:read")
        #expect(report.lockedScope(for: .events) == "query:read")
        #expect(report.lockedScope(for: .sessions) == "session_recording:read")
        #expect(report.lockedScope(for: .flags) == "feature_flag:read")
        #expect(report.lockedScope(for: .replay) == "session_recording:read")
    }
}
