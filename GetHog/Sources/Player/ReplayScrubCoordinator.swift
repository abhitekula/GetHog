import Foundation

struct ReplayScrubUpdate: Equatable {
    let previewPosition: TimeInterval?
    let coverageTarget: TimeInterval?
}

enum ReplayScrubCommit: Equatable {
    case waiting(target: TimeInterval)
    case seek(target: TimeInterval, resume: Bool)
}

struct ReplayScrubCoordinator {
    static let previewInterval: TimeInterval = 0.12

    private var resumeAfterCommit = false
    private var lastPreviewAt: TimeInterval?
    private(set) var pendingTarget: TimeInterval?

    mutating func begin(isPlaying: Bool) -> Bool {
        resumeAfterCommit = isPlaying
        lastPreviewAt = nil
        pendingTarget = nil
        return isPlaying
    }

    mutating func update(
        position: TimeInterval,
        buffered: TimeInterval,
        now: TimeInterval
    ) -> ReplayScrubUpdate {
        guard position <= buffered else {
            return ReplayScrubUpdate(
                previewPosition: nil,
                coverageTarget: position
            )
        }
        let canPreview: Bool
        if let lastPreviewAt, now < lastPreviewAt {
            // `systemUptime` is monotonic in production, but deterministic tests
            // and future injected clocks can move backwards. Rebase the window
            // without treating the rollback sample as a second immediate seek.
            self.lastPreviewAt = now
            canPreview = false
        } else {
            canPreview = lastPreviewAt.map {
                now >= $0 + Self.previewInterval
            } ?? true
        }
        if canPreview {
            lastPreviewAt = now
        }
        return ReplayScrubUpdate(
            previewPosition: canPreview ? position : nil,
            coverageTarget: nil
        )
    }

    mutating func end(
        position: TimeInterval,
        buffered: TimeInterval
    ) -> ReplayScrubCommit {
        if position > buffered {
            pendingTarget = position
            return .waiting(target: position)
        }
        pendingTarget = nil
        return .seek(target: position, resume: resumeAfterCommit)
    }

    mutating func coverageAdvanced(to buffered: TimeInterval) -> ReplayScrubCommit? {
        guard let pendingTarget, buffered >= pendingTarget else { return nil }
        self.pendingTarget = nil
        return .seek(target: pendingTarget, resume: resumeAfterCommit)
    }

    mutating func cancel() {
        resumeAfterCommit = false
        lastPreviewAt = nil
        pendingTarget = nil
    }
}

enum ReplayTransportEffect: Equatable {
    case pause
    case preview(target: TimeInterval)
    case requestCoverage(target: TimeInterval)
    case commit(target: TimeInterval, resume: Bool)
}

struct ReplayTransportInteraction {
    static let bufferingStatusText = "Buffering selected moment…"

    private var scrub = ReplayScrubCoordinator()
    private(set) var scrubPosition: TimeInterval = 0
    private(set) var isEditing = false

    var pendingTarget: TimeInterval? { scrub.pendingTarget }

    var bufferingStatus: String? {
        pendingTarget == nil ? nil : Self.bufferingStatusText
    }

    static func sliderUpperBound(duration: TimeInterval) -> TimeInterval {
        max(max(0, duration), 0.001)
    }

    func displayedPosition(current: TimeInterval) -> TimeInterval {
        isEditing || pendingTarget != nil ? scrubPosition : current
    }

    mutating func begin(
        position: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) -> [ReplayTransportEffect] {
        guard !isEditing else { return [] }
        isEditing = true
        scrubPosition = Self.clamped(position, duration: duration)
        return scrub.begin(isPlaying: isPlaying) ? [.pause] : []
    }

    mutating func update(
        position: TimeInterval,
        buffered: TimeInterval,
        duration: TimeInterval,
        isComplete: Bool,
        now: TimeInterval
    ) -> [ReplayTransportEffect] {
        guard isEditing else { return [] }
        let target = Self.clamped(position, duration: duration)
        scrubPosition = target
        let update = scrub.update(
            position: target,
            buffered: Self.effectiveCoverage(
                buffered: buffered,
                duration: duration,
                isComplete: isComplete
            ),
            now: now
        )
        var effects: [ReplayTransportEffect] = []
        if let preview = update.previewPosition {
            effects.append(.preview(target: preview))
        }
        if let coverage = update.coverageTarget {
            effects.append(.requestCoverage(target: coverage))
        }
        return effects
    }

    mutating func end(
        buffered: TimeInterval,
        duration: TimeInterval,
        isComplete: Bool
    ) -> [ReplayTransportEffect] {
        guard isEditing else { return [] }
        isEditing = false
        return Self.effects(
            for: scrub.end(
                position: scrubPosition,
                buffered: Self.effectiveCoverage(
                    buffered: buffered,
                    duration: duration,
                    isComplete: isComplete
                )
            )
        )
    }

    mutating func coverageAdvanced(
        to buffered: TimeInterval,
        duration: TimeInterval,
        isComplete: Bool
    ) -> [ReplayTransportEffect] {
        guard let commit = scrub.coverageAdvanced(
            to: Self.effectiveCoverage(
                buffered: buffered,
                duration: duration,
                isComplete: isComplete
            )
        ) else { return [] }
        return Self.effects(for: commit)
    }

    mutating func cancel() {
        isEditing = false
        scrub.cancel()
    }

    private static func clamped(
        _ position: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        min(max(0, position), max(0, duration))
    }

    private static func effectiveCoverage(
        buffered: TimeInterval,
        duration: TimeInterval,
        isComplete: Bool
    ) -> TimeInterval {
        isComplete ? max(0, duration) : max(0, buffered)
    }

    private static func effects(for commit: ReplayScrubCommit) -> [ReplayTransportEffect] {
        switch commit {
        case .waiting(let target):
            return [.requestCoverage(target: target)]
        case .seek(let target, let resume):
            return [.commit(target: target, resume: resume)]
        }
    }
}

struct ReplaySeekArbiter {
    private enum Owner {
        case slider
        case programmatic
    }

    private struct DeferredSeek {
        let target: TimeInterval
        let resume: Bool
    }

    private var deferred: DeferredSeek?
    private var owner: Owner?
    private(set) var sliderCancellationRevision = 0

    mutating func sliderBegan() {
        deferred = nil
        owner = .slider
    }

    mutating func acceptSliderCommit(
        target: TimeInterval,
        resume: Bool
    ) -> ReplayScrubCommit? {
        guard owner == .slider else { return nil }
        owner = nil
        return .seek(target: max(0, target), resume: resume)
    }

    mutating func requestProgrammatic(
        target: TimeInterval,
        resume: Bool,
        buffered: TimeInterval,
        isComplete: Bool
    ) -> ReplayScrubCommit {
        let target = max(0, target)
        sliderCancellationRevision &+= 1
        if target > buffered, !isComplete {
            deferred = DeferredSeek(target: target, resume: resume)
            owner = .programmatic
            return .waiting(target: target)
        }
        deferred = nil
        owner = nil
        return .seek(target: target, resume: resume)
    }

    mutating func coverageAdvanced(to buffered: TimeInterval) -> ReplayScrubCommit? {
        guard owner == .programmatic,
              let deferred,
              buffered >= deferred.target
        else { return nil }
        self.deferred = nil
        owner = nil
        return .seek(target: deferred.target, resume: deferred.resume)
    }
}
