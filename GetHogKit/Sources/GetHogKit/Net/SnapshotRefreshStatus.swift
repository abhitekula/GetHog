import Foundation

public struct SnapshotRefreshStatus: Codable, Sendable, Equatable {
    public let attemptedAt: Date
    public let failure: SnapshotRefreshFailure?

    public init(attemptedAt: Date, failure: SnapshotRefreshFailure?) {
        self.attemptedAt = attemptedAt
        self.failure = failure
    }
}

public extension SharedSnapshotStore {
    var snapshotRefreshStatusURL: URL {
        directory.appendingPathComponent("snapshot-refresh-status.json")
    }

    func writeSnapshotRefreshStatus(_ status: SnapshotRefreshStatus) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(status).write(to: snapshotRefreshStatusURL, options: .atomic)
    }

    func snapshotRefreshStatus() -> SnapshotRefreshStatus? {
        guard let data = try? Data(contentsOf: snapshotRefreshStatusURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SnapshotRefreshStatus.self, from: data)
    }

    func clearSnapshotRefreshStatus() {
        try? FileManager.default.removeItem(at: snapshotRefreshStatusURL)
    }
}
