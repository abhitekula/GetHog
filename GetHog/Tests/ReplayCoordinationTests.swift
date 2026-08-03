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

    @Test("prepared expanded playback restores at the controller ready boundary")
    @MainActor
    func preparedPlaybackRestoresWhenReady() {
        let controller = ReplayPlayerController()
        controller.preparePlaybackForNextReady(position: 1, speed: 2)

        controller.handle(message: ["type": "ready", "totalTime": 10_000.0])

        #expect(controller.didRestorePreparedPlayback)
        #expect(controller.expansionHandoffPosition == 1)
        #expect(controller.speed == 2)
        #expect(!controller.isPlaying)

        controller.restartPlayback()
        controller.preparePlaybackForNextReady(position: 4, speed: 4)
        controller.handle(message: ["type": "ready", "totalTime": 10_000.0])

        #expect(controller.didRestorePreparedPlayback)
        #expect(controller.expansionHandoffPosition == 4)
        #expect(controller.speed == 4)
        #expect(!controller.isPlaying)
    }

    @Test("a rejected interactive commit cannot retain a dead handoff target")
    @MainActor
    func rejectedInteractiveCommitReleasesHandoff() {
        let controller = ReplayPlayerController()
        controller.handle(message: ["type": "ready", "totalTime": 100_000.0])
        controller.handle(message: ["type": "time", "currentTime": 10_000.0])

        controller.updateInteractiveSeekPosition(90)
        controller.finishInteractiveSeek()

        #expect(controller.expansionHandoffPosition == 10)
    }

    @Test("renderer ticks cannot roll back a pending native seek")
    @MainActor
    func pendingSeekWaitsForDirectionalAcknowledgement() {
        let controller = ReplayPlayerController()
        controller.handle(message: ["type": "ready", "totalTime": 10_000.0])

        controller.handle(message: ["type": "time", "currentTime": 400.0])
        controller.updateInteractiveSeekPosition(1)
        #expect(controller.expansionHandoffPosition == 1)
        controller.handle(message: ["type": "time", "currentTime": 500.0])
        #expect(controller.currentTime == 0.5)
        #expect(controller.expansionHandoffPosition == 1)

        controller.seek(to: 1, resume: false)
        controller.finishInteractiveSeek()
        #expect(controller.expansionHandoffPosition == 1)
        controller.handle(message: ["type": "time", "currentTime": 730.0])
        #expect(controller.currentTime == 1)
        #expect(controller.expansionHandoffPosition == 1)

        controller.handle(message: ["type": "time", "currentTime": 990.0])
        #expect(controller.currentTime == 1)
        #expect(controller.expansionHandoffPosition == 1)
        controller.handle(message: ["type": "time", "currentTime": 1_200.0])
        #expect(controller.currentTime == 1.2)
        #expect(controller.expansionHandoffPosition == 1.2)

        controller.updateInteractiveSeekPosition(2)
        #expect(controller.expansionHandoffPosition == 2)
        controller.cancelInteractiveSeek()
        #expect(controller.expansionHandoffPosition == 1.2)

        controller.seek(to: 0.5, resume: false)
        controller.handle(message: ["type": "time", "currentTime": 900.0])
        #expect(controller.currentTime == 0.5)

        controller.handle(message: ["type": "time", "currentTime": 510.0])
        #expect(controller.currentTime == 0.5)
        controller.handle(message: ["type": "time", "currentTime": 700.0])
        #expect(controller.currentTime == 0.7)
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
