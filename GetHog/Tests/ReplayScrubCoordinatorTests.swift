import Testing

@testable import GetHog

@Suite("Replay scrub coordination")
struct ReplayScrubCoordinatorTests {
    @Test("a drag pauses once, previews at 120ms, and requests remote coverage immediately")
    func previewAndCoverage() {
        var scrub = ReplayScrubCoordinator()
        #expect(scrub.begin(isPlaying: true) == true)

        let first = scrub.update(position: 10, buffered: 30, now: 0)
        #expect(first.previewPosition == 10)
        #expect(first.coverageTarget == nil)

        let throttled = scrub.update(position: 12, buffered: 30, now: 0.05)
        #expect(throttled.previewPosition == nil)

        let next = scrub.update(position: 14, buffered: 30, now: 0.12)
        #expect(next.previewPosition == 14)

        let remote = scrub.update(position: 90, buffered: 30, now: 0.13)
        #expect(remote.previewPosition == nil)
        #expect(remote.coverageTarget == 90)
    }

    @Test("a remote commit waits for coverage and preserves prior playback")
    func pendingCommit() {
        var scrub = ReplayScrubCoordinator()
        _ = scrub.begin(isPlaying: true)

        #expect(scrub.end(position: 90, buffered: 30) == .waiting(target: 90))
        #expect(scrub.coverageAdvanced(to: 89) == nil)
        #expect(scrub.coverageAdvanced(to: 90) == .seek(target: 90, resume: true))
    }

    @Test("a new drag replaces an older pending target")
    func replacesPendingTarget() {
        var scrub = ReplayScrubCoordinator()
        _ = scrub.begin(isPlaying: false)
        _ = scrub.end(position: 90, buffered: 30)

        _ = scrub.begin(isPlaying: false)
        #expect(scrub.end(position: 50, buffered: 30) == .waiting(target: 50))
        #expect(scrub.coverageAdvanced(to: 50) == .seek(target: 50, resume: false))
    }

    @Test("duplicate time stays throttled and a clock rollback rebases the preview window")
    func clockRollback() {
        var scrub = ReplayScrubCoordinator()
        _ = scrub.begin(isPlaying: false)

        #expect(scrub.update(position: 1, buffered: 10, now: 10).previewPosition == 1)
        #expect(scrub.update(position: 2, buffered: 10, now: 10).previewPosition == nil)
        #expect(scrub.update(position: 3, buffered: 10, now: 9).previewPosition == nil)
        #expect(scrub.update(position: 4, buffered: 10, now: 9.12).previewPosition == 4)
    }

    // MARK: - Production transport contract

    @Test("an ordinary drag emits one pause intent")
    func pausesOnce() {
        var transport = ReplayTransportInteraction()

        #expect(
            transport.begin(position: 5, duration: 100, isPlaying: true) == [.pause]
        )
        #expect(
            transport.begin(position: 5, duration: 100, isPlaying: true).isEmpty
        )
    }

    @Test("a remote drag requests coverage immediately and exposes its pending label")
    func remoteIntentAndPendingState() {
        var transport = ReplayTransportInteraction()
        _ = transport.begin(position: 5, duration: 100, isPlaying: false)

        #expect(
            transport.update(
                position: 90,
                buffered: 30,
                duration: 100,
                isComplete: false,
                now: 0
            ) == [.requestCoverage(target: 90)]
        )
        #expect(transport.displayedPosition(current: 5) == 90)
        #expect(
            transport.end(buffered: 30, duration: 100, isComplete: false)
                == [.requestCoverage(target: 90)]
        )
        #expect(transport.pendingTarget == 90)
        #expect(transport.bufferingStatus == "Buffering selected moment…")
        #expect(transport.displayedPosition(current: 5) == 90)
    }

    @Test("coverage completes the exact pending target once")
    func completesOnce() {
        var transport = ReplayTransportInteraction()
        _ = transport.begin(position: 5, duration: 100, isPlaying: true)
        _ = transport.update(
            position: 90,
            buffered: 30,
            duration: 100,
            isComplete: false,
            now: 0
        )
        _ = transport.end(buffered: 30, duration: 100, isComplete: false)

        #expect(
            transport.coverageAdvanced(
                to: 90, duration: 100, isComplete: false
            ) == [.commit(target: 90, resume: true)]
        )
        #expect(
            transport.coverageAdvanced(
                to: 100, duration: 100, isComplete: true
            ).isEmpty
        )
        #expect(transport.pendingTarget == nil)
    }

    @Test("a deferred commit releases its handoff after renderer acknowledgement")
    @MainActor
    func deferredCommitReleasesHandoff() {
        let controller = ReplayPlayerController()
        controller.handle(message: ["type": "ready", "totalTime": 100_000.0])
        controller.handle(message: ["type": "time", "currentTime": 10_000.0])

        var transport = ReplayTransportInteraction()
        _ = transport.begin(position: 10, duration: 100, isPlaying: false)
        controller.updateInteractiveSeekPosition(90)
        _ = transport.update(
            position: 90,
            buffered: 30,
            duration: 100,
            isComplete: false,
            now: 0
        )

        #expect(
            transport.end(buffered: 30, duration: 100, isComplete: false)
                == [.requestCoverage(target: 90)]
        )
        #expect(controller.expansionHandoffPosition == 90)

        for effect in transport.coverageAdvanced(
            to: 90,
            duration: 100,
            isComplete: false
        ) {
            guard case .commit(let target, let resume) = effect else {
                Issue.record("Coverage emitted a non-commit effect")
                continue
            }
            controller.seek(to: target, resume: resume)
            controller.finishInteractiveSeek()
        }

        controller.handle(message: ["type": "time", "currentTime": 89_990.0])
        #expect(controller.expansionHandoffPosition == 90)
        controller.handle(message: ["type": "time", "currentTime": 92_000.0])
        #expect(controller.expansionHandoffPosition == 92)
    }

    @Test("a replacement drag is the only target allowed to complete")
    func replacementDragWins() {
        var transport = ReplayTransportInteraction()
        _ = transport.begin(position: 5, duration: 100, isPlaying: true)
        _ = transport.update(
            position: 90,
            buffered: 30,
            duration: 100,
            isComplete: false,
            now: 0
        )
        _ = transport.end(buffered: 30, duration: 100, isComplete: false)

        _ = transport.begin(position: 5, duration: 100, isPlaying: false)
        _ = transport.update(
            position: 50,
            buffered: 30,
            duration: 100,
            isComplete: false,
            now: 1
        )
        _ = transport.end(buffered: 30, duration: 100, isComplete: false)

        #expect(
            transport.coverageAdvanced(
                to: 50, duration: 100, isComplete: false
            ) == [.commit(target: 50, resume: false)]
        )
        #expect(
            transport.coverageAdvanced(
                to: 90, duration: 100, isComplete: false
            ).isEmpty
        )
    }

    @Test("a complete sub-second replay clamps every commit to its real duration")
    func completeSubsecondReplay() {
        var transport = ReplayTransportInteraction()

        #expect(ReplayTransportInteraction.sliderUpperBound(duration: 0.9) == 0.9)
        #expect(ReplayTransportInteraction.sliderUpperBound(duration: 0) > 0)
        _ = transport.begin(position: 0.2, duration: 0.9, isPlaying: false)
        #expect(
            transport.update(
                position: 1,
                buffered: 0.9,
                duration: 0.9,
                isComplete: true,
                now: 0
            ) == [.preview(target: 0.9)]
        )
        #expect(
            transport.end(buffered: 0.9, duration: 0.9, isComplete: true)
                == [.commit(target: 0.9, resume: false)]
        )
        #expect(transport.pendingTarget == nil)

        _ = transport.begin(position: 0, duration: 0, isPlaying: false)
        _ = transport.update(
            position: 0.001,
            buffered: 0,
            duration: 0,
            isComplete: true,
            now: 1
        )
        #expect(
            transport.end(buffered: 0, duration: 0, isComplete: true)
                == [.commit(target: 0, resume: false)]
        )
    }

    // MARK: - Slider and programmatic seek arbitration

    @Test("a newer slider drag cancels an older deferred programmatic seek")
    func sliderWins() {
        var arbiter = ReplaySeekArbiter()
        var transport = ReplayTransportInteraction()

        #expect(
            arbiter.requestProgrammatic(
                target: 80,
                resume: true,
                buffered: 20,
                isComplete: false
            ) == .waiting(target: 80)
        )
        _ = transport.begin(position: 5, duration: 100, isPlaying: false)
        arbiter.sliderBegan(generation: transport.sliderGeneration)
        _ = transport.update(
            position: 50,
            buffered: 20,
            duration: 100,
            isComplete: false,
            now: 0
        )
        _ = transport.end(buffered: 20, duration: 100, isComplete: false)

        #expect(arbiter.coverageAdvanced(to: 80) == nil)
        let sliderEffects = transport.coverageAdvanced(
            to: 50, duration: 100, isComplete: false
        )
        #expect(sliderEffects == [.commit(target: 50, resume: false)])
        #expect(
            arbiter.acceptSliderCommit(target: 50, resume: false)
                == .seek(target: 50, resume: false)
        )
        #expect(arbiter.acceptSliderCommit(target: 50, resume: false) == nil)
        #expect(
            transport.coverageAdvanced(
                to: 100, duration: 100, isComplete: true
            ).isEmpty
        )
    }

    @Test("a newer programmatic seek cancels an older slider target")
    func programmaticWins() throws {
        var arbiter = ReplaySeekArbiter()
        var transport = ReplayTransportInteraction()

        _ = transport.begin(position: 5, duration: 100, isPlaying: true)
        arbiter.sliderBegan(generation: transport.sliderGeneration)
        _ = transport.update(
            position: 80,
            buffered: 20,
            duration: 100,
            isComplete: false,
            now: 0
        )
        _ = transport.end(buffered: 20, duration: 100, isComplete: false)

        #expect(
            arbiter.requestProgrammatic(
                target: 40,
                resume: true,
                buffered: 20,
                isComplete: false
            ) == .waiting(target: 40)
        )
        let cancellation = try #require(arbiter.sliderCancellationToken)
        let didCancel = transport.cancel(ifMatching: cancellation)
        #expect(didCancel)

        #expect(arbiter.acceptSliderCommit(target: 80, resume: true) == nil)
        #expect(
            transport.coverageAdvanced(
                to: 80, duration: 100, isComplete: false
            ).isEmpty
        )
        #expect(arbiter.coverageAdvanced(to: 40) == .seek(target: 40, resume: true))
        #expect(arbiter.coverageAdvanced(to: 100) == nil)
    }

    @Test("a stale cancellation token cannot cancel a newer slider generation")
    func staleCancellationCannotCancelNewSlider() throws {
        var arbiter = ReplaySeekArbiter()
        var transport = ReplayTransportInteraction()

        _ = transport.begin(position: 5, duration: 100, isPlaying: true)
        arbiter.sliderBegan(generation: transport.sliderGeneration)
        #expect(
            arbiter.requestProgrammatic(
                target: 80,
                resume: true,
                buffered: 20,
                isComplete: false
            ) == .waiting(target: 80)
        )
        let cancellationA = try #require(arbiter.sliderCancellationToken)

        let staleAEffects = transport.end(
            buffered: 20,
            duration: 100,
            isComplete: false
        )
        #expect(staleAEffects == [.commit(target: 5, resume: true)])
        #expect(arbiter.acceptSliderCommit(target: 5, resume: true) == nil)

        _ = transport.begin(position: 10, duration: 100, isPlaying: false)
        arbiter.sliderBegan(generation: transport.sliderGeneration)
        let didCancelB = transport.cancel(ifMatching: cancellationA)
        #expect(didCancelB == false)
        #expect(transport.isEditing)
        #expect(
            transport.update(
                position: 40,
                buffered: 100,
                duration: 100,
                isComplete: true,
                now: 1
            ) == [.preview(target: 40)]
        )
        #expect(
            transport.end(buffered: 100, duration: 100, isComplete: true)
                == [.commit(target: 40, resume: false)]
        )
        #expect(
            arbiter.acceptSliderCommit(target: 40, resume: false)
                == .seek(target: 40, resume: false)
        )
        #expect(arbiter.acceptSliderCommit(target: 40, resume: false) == nil)
        #expect(arbiter.coverageAdvanced(to: 100) == nil)
    }

    @Test("a matching cancellation token still cancels its slider generation")
    func matchingCancellationCancelsSlider() throws {
        var arbiter = ReplaySeekArbiter()
        var transport = ReplayTransportInteraction()

        _ = transport.begin(position: 5, duration: 100, isPlaying: true)
        arbiter.sliderBegan(generation: transport.sliderGeneration)
        #expect(
            arbiter.requestProgrammatic(
                target: 40,
                resume: true,
                buffered: 20,
                isComplete: false
            ) == .waiting(target: 40)
        )
        let cancellation = try #require(arbiter.sliderCancellationToken)

        let didCancel = transport.cancel(ifMatching: cancellation)
        #expect(didCancel)
        #expect(!transport.isEditing)
        #expect(
            transport.update(
                position: 80,
                buffered: 100,
                duration: 100,
                isComplete: true,
                now: 1
            ).isEmpty
        )
        #expect(
            transport.end(buffered: 100, duration: 100, isComplete: true).isEmpty
        )
        #expect(arbiter.coverageAdvanced(to: 40) == .seek(target: 40, resume: true))
        #expect(arbiter.coverageAdvanced(to: 100) == nil)
    }
}
