import Darwin
import Foundation

public struct SnapshotRefreshScope: Codable, Sendable, Equatable {
    public let projectID: Int
    public let projectName: String
    public let region: PostHogRegion
    public let authSessionID: UUID

    public init(
        projectID: Int,
        projectName: String,
        region: PostHogRegion,
        authSessionID: UUID
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.region = region
        self.authSessionID = authSessionID
    }
}

public struct SnapshotRefreshLease: Codable, Sendable, Equatable {
    public let token: UUID
    public let scope: SnapshotRefreshScope
    public let trigger: SnapshotRefreshTrigger
    public let startedAt: Date
}

public struct SnapshotRefreshLeaseStore: Sendable {
    public static let timeout: TimeInterval = 30

    public let directory: URL
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("snapshot-refresh-lease.json")
    }

    public func acquire(
        scope: SnapshotRefreshScope,
        trigger: SnapshotRefreshTrigger,
        now: Date = Date()
    ) -> SnapshotRefreshLease? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if current(now: now) != nil {
            return nil
        }

        let lease = SnapshotRefreshLease(
            token: UUID(),
            scope: scope,
            trigger: trigger,
            startedAt: now
        )
        guard let data = try? Self.encoder.encode(lease), createExclusively(data) else {
            return nil
        }
        return lease
    }

    public func current(now: Date = Date()) -> SnapshotRefreshLease? {
        guard let data = try? Data(contentsOf: fileURL),
              let lease = try? Self.decoder.decode(SnapshotRefreshLease.self, from: data)
        else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard now.timeIntervalSince(lease.startedAt) < Self.timeout else {
            release(token: lease.token)
            return nil
        }
        return lease
    }

    public func release(token: UUID) {
        guard let data = try? Data(contentsOf: fileURL),
              let lease = try? Self.decoder.decode(SnapshotRefreshLease.self, from: data),
              lease.token == token
        else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func releaseCurrentLease() {
        guard let data = try? Data(contentsOf: fileURL),
              let lease = try? Self.decoder.decode(SnapshotRefreshLease.self, from: data)
        else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        release(token: lease.token)
    }

    private func createExclusively(_ data: Data) -> Bool {
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let wroteEverything = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        if !wroteEverything {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return wroteEverything
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
