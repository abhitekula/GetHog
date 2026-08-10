import Testing

@testable import GetHogKit

@Suite("API key scope guidance")
struct APIKeyScopeGuidanceTests {

    @Test("the onboarding baseline contains only the core read contract")
    func onboardingUsesCoreReadsOnly() {
        #expect(APIKeyScopeGuidance.coreReadScopes.map(\.scope) == [
            "dashboard:read",
            "insight:read",
            "query:read",
            "session_recording:read",
            "feature_flag:read",
            "project:read",
        ])
        #expect(APIKeyScopeGuidance.coreReadScopes.allSatisfy { $0.kind == .coreRead })
    }

    @Test("Settings names every currently offered write as optional")
    func settingsOffersOnlyKnownOptionalWrites() {
        #expect(APIKeyScopeGuidance.optionalWriteActions.map(\.scope) == [
            "feature_flag:write",
            "alert:write",
            "annotation:write",
            "error_tracking:write",
            "experiment:write",
            "survey:write",
        ])
        #expect(APIKeyScopeGuidance.optionalWriteActions.allSatisfy { $0.kind == .optionalWrite })
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
