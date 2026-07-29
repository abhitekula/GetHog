import Foundation

/// Disk-backed response cache in the App Group container.
///
/// The app is cache-first by necessity: rate limits are organisation-wide, and
/// widgets must render with no network at all. Every cached entry carries the
/// time it was stored so the UI can show an honest "Updated 5m ago" rather than
/// implying data is live.
public actor ResponseCache {
    public struct Entry: Sendable, Codable {
        public let data: Data
        public let storedAt: Date

        public func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
            now.timeIntervalSince(storedAt) < ttl
        }
    }

    private let directory: URL
    private let fileManager = FileManager.default

    /// Replay blobs are immutable once written, so they never expire; a rewatch
    /// costs zero requests. Everything else is short-lived.
    public enum TTL {
        public static let dashboards: TimeInterval = 300
        public static let lists: TimeInterval = 120
        public static let events: TimeInterval = 30
        public static let snapshots: TimeInterval = .infinity
    }

    public init(appGroupID: String? = nil, subdirectory: String = "PostHogCache") {
        let base: URL
        if let appGroupID,
           let container = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: appGroupID
           ) {
            base = container
        } else {
            base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        }
        self.directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private func url(for key: String) -> URL {
        // Hash so arbitrary query strings can't produce invalid filenames.
        let name = String(format: "%02x", abs(key.hashValue)) + "-" + key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .suffix(96)
        return directory.appendingPathComponent(name)
    }

    public func entry(for key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    public func store(_ data: Data, for key: String, now: Date = Date()) {
        let entry = Entry(data: data, storedAt: now)
        guard let encoded = try? JSONEncoder().encode(entry) else { return }
        try? encoded.write(to: url(for: key), options: .atomic)
    }

    public func remove(_ key: String) {
        try? fileManager.removeItem(at: url(for: key))
    }

    public func clear() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in contents { try? fileManager.removeItem(at: file) }
    }

    public func totalSizeBytes() -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Evicts oldest-first until the cache fits the budget. Used to bound the
    /// replay blob cache, which is otherwise permanent.
    public func evict(toFitBytes budget: Int) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var files = contents.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }
            return (url, size, modified)
        }

        var total = files.reduce(0) { $0 + $1.1 }
        guard total > budget else { return }

        files.sort { $0.2 < $1.2 }
        for (url, size, _) in files {
            guard total > budget else { break }
            try? fileManager.removeItem(at: url)
            total -= size
        }
    }
}
