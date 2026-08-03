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
}
