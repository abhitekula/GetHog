import Foundation
import Testing

@testable import GetHogKit

/// A probe that *failed* and a probe that came back *denied* are different
/// facts, and this suite exists to stop them collapsing into one.
///
/// Reported: the same key, the same build, one launch apart — the Sessions tab
/// listed sessions normally, then was replaced by "Your PostHog API key is
/// missing a scope. Add it to your key in PostHog, then re-check." The key was
/// fine. A transient probe failure had been mapped to `.failed`, and `.failed`
/// was then treated as `.locked` by a boolean that only had room for two states.
@Suite("Scope evidence")
struct ScopeEvidenceTests {

    @Test("a probe that failed is not evidence of a missing scope")
    func failedProbeDoesNotLock() {
        let report = CapabilityReport(results: [.sessions: .failed("The request timed out.")])
        #expect(report.isAvailable(.sessions))
        #expect(report.missingScopes.isEmpty)
    }

    @Test("a probe that was denied still locks")
    func deniedProbeLocks() {
        let report = CapabilityReport(results: [
            .sessions: .locked(scope: "session_recording:read")
        ])
        #expect(!report.isAvailable(.sessions))
        #expect(report.missingScopes == ["session_recording:read"])
    }

    @Test("a capability that was never probed is not locked either")
    func unprobedDoesNotLock() {
        let report = CapabilityReport(results: [:])
        #expect(report.isAvailable(.flags))
        #expect(report.missingScopes.isEmpty)
    }

    @Test("only a denial answers the denial question")
    func isDeniedIsNarrow() {
        #expect(CapabilityStatus.locked(scope: "x").isDenied)
        #expect(CapabilityStatus.locked(scope: nil).isDenied)
        #expect(!CapabilityStatus.failed("boom").isDenied)
        #expect(!CapabilityStatus.available.isDenied)
    }

    @Test("the failure is kept, so a screen can say the check did not complete")
    func keepsTheFailure() {
        // Not discarded: the reported bug replaced the real error with a scope
        // claim the app had no evidence for, and lost the error in the process.
        let report = CapabilityReport(results: [
            .sessions: .failed("Couldn't reach PostHog: timed out"),
            .flags: .locked(scope: "feature_flag:read"),
            .events: .available,
        ])
        #expect(report.probeFailure(.sessions) == "Couldn't reach PostHog: timed out")
        #expect(report.probeFailure(.flags) == nil)
        #expect(report.probeFailure(.events) == nil)
    }

    @Test("a failed probe is not counted as a confirmed pass")
    func allAvailableStaysStrict() {
        // `isAvailable` answers "may this screen open?" and a failed probe must
        // not close it. `allAvailable` answers "did every probe confirm?", which
        // a failed probe genuinely did not — the two questions differ and the
        // type must be able to tell them apart.
        var results = Dictionary(uniqueKeysWithValues: Capability.allCases.map { ($0, CapabilityStatus.available) })
        results[.sessions] = .failed("timed out")
        let report = CapabilityReport(results: results)
        #expect(report.isAvailable(.sessions))
        #expect(!report.allAvailable)
    }

    @Test("a transient probe failure is never turned into an instruction to edit the key")
    func noCredentialInstructionWithoutEvidence() {
        // The end-to-end statement of the bug: nothing about a failed probe may
        // reach the "add this scope to your key" path.
        let report = CapabilityReport(results: [.sessions: .failed("A server error occurred.")])
        #expect(report.lockedScope(for: .sessions) == nil)
        #expect(report.isAvailable(.sessions))
    }

    @Test("a denial names a scope to add, falling back to the documented ones")
    func deniedNamesAScope() {
        let named = CapabilityReport(results: [.sessions: .locked(scope: "session_recording:read")])
        #expect(named.lockedScope(for: .sessions) == "session_recording:read")

        let unnamed = CapabilityReport(results: [.flags: .locked(scope: nil)])
        #expect(unnamed.lockedScope(for: .flags) == Capability.flags.requiredScopes.joined(separator: ", "))
    }
}
