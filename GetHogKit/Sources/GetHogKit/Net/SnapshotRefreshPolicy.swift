import Foundation

public enum SnapshotRefreshTrigger: String, Codable, Sendable, Equatable {
    case foreground
    case manualWidget
    case automaticWidget
    case macBackground
}

public enum SnapshotRefreshPolicy {
    public static let automaticWidgetInterval = SharedSnapshot.defaultStaleTolerance
    public static let macBackgroundInterval: TimeInterval = 2 * 60 * 60
    public static let macBackgroundEarlyTolerance: TimeInterval = 5 * 60

    public static func shouldRefresh(
        trigger: SnapshotRefreshTrigger,
        capturedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        switch trigger {
        case .foreground, .manualWidget:
            return true
        case .automaticWidget:
            guard let capturedAt else { return true }
            return now.timeIntervalSince(capturedAt) >= automaticWidgetInterval
        case .macBackground:
            guard let capturedAt else { return true }
            return now.timeIntervalSince(capturedAt)
                >= macBackgroundInterval - macBackgroundEarlyTolerance
        }
    }
}
