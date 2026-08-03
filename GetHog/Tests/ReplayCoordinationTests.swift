import Foundation
import Testing

@testable import GetHog

@Suite("Replay coordination")
struct ReplayCoordinationTests {
    @Test("submission encoding and evaluation keep accepted boot-before-append order")
    @MainActor
    func submissionsStayInAcceptanceOrder() async {
        let gate = ReplaySubmissionGate()
        let recorder = ReplaySubmissionRecorder()
        let coordinator = ReplaySubmissionCoordinator()

        coordinator.accept { kind in
            await gate.wait()
            await recorder.record(kind)
        }
        coordinator.accept { kind in
            await recorder.record(kind)
        }

        await Task.yield()
        #expect(await recorder.values.isEmpty)

        await gate.open()
        await coordinator.waitUntilIdle()
        #expect(await recorder.values == [.boot, .append])
    }

    @Test("early close keeps the compact playhead until expanded restoration succeeds")
    func earlyCloseUsesInitialPosition() {
        #expect(
            ExpandedReplayHandoff.dismissalPosition(
                initialPosition: 42,
                didRestorePosition: false,
                currentTime: 0
            ) == 42
        )
        #expect(
            ExpandedReplayHandoff.dismissalPosition(
                initialPosition: 42,
                didRestorePosition: true,
                currentTime: 87
            ) == 87
        )
    }

    @Test("expanded playback requests the shared prefetch lead beyond its playhead")
    @MainActor
    func expandedCoverageBoundary() {
        #expect(ExpandedReplayCoverage.target(after: 75) == 135)
    }
}

private actor ReplaySubmissionGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ReplaySubmissionRecorder {
    private(set) var values: [ReplaySubmissionKind] = []

    func record(_ value: ReplaySubmissionKind) {
        values.append(value)
    }
}
