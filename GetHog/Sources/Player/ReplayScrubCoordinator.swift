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
        let canPreview = lastPreviewAt.map {
            now - $0 >= Self.previewInterval
        } ?? true
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
}
