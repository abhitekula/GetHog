import Foundation

/// Disk-backed response cache in the App Group container.
///
/// The app is cache-first by necessity: rate limits are organisation-wide, and
/// widgets must render with no network at all. Every cached entry carries the
/// time it was stored so the UI can show an honest "Updated 5m ago" rather than
/// implying data is live.
public actor ResponseCache {
    struct PublicationLease: Hashable, Sendable {
        let namespace: String
        let id = UUID()
    }

    enum LeaseLookup: Sendable {
        case available(Entry?)
        case revoked
    }

    public struct Entry: Sendable, Codable {
        public let data: Data
        public let storedAt: Date

        public func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
            now.timeIntervalSince(storedAt) < ttl
        }
    }

    private let directory: URL
    private let fileManager = FileManager.default
    private let beforePublicationCommit: @Sendable () async -> Void
    private var revokedPublicationLeases: Set<UUID> = []

    /// Replay blobs are immutable once written, so they never expire; a rewatch
    /// costs zero requests. Everything else is short-lived.
    public enum TTL {
        public static let dashboards: TimeInterval = 300
        public static let lists: TimeInterval = 120
        public static let events: TimeInterval = 30
        public static let snapshots: TimeInterval = .infinity

        /// A rendered page image changes only when someone re-renders the saved
        /// heatmap in the web console, which is a manual act — so a day, not
        /// minutes. Half a megabyte per view is exactly the kind of spend the
        /// organisation-wide budget cannot absorb on a screen people scroll
        /// back to.
        public static let pageRenders: TimeInterval = 86_400
    }

    public init(appGroupID: String? = nil, subdirectory: String = "PostHogCache") {
        self.beforePublicationCommit = {}
        self.directory = Self.directory(appGroupID: appGroupID, subdirectory: subdirectory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// Internal injection point for deterministic actor-ordering tests.
    ///
    /// The public initializer always installs an immediate no-op. Tests can
    /// suspend immediately before the final validity check without adding a
    /// debug branch or changing any app-visible cache behavior.
    init(
        appGroupID: String? = nil,
        subdirectory: String = "PostHogCache",
        beforePublicationCommit: @escaping @Sendable () async -> Void
    ) {
        self.beforePublicationCommit = beforePublicationCommit
        self.directory = Self.directory(appGroupID: appGroupID, subdirectory: subdirectory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private static func directory(appGroupID: String?, subdirectory: String) -> URL {
        let base: URL
        if let appGroupID,
           let container = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: appGroupID
           ) {
            base = container
        } else {
            base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        }
        return base.appendingPathComponent(subdirectory, isDirectory: true)
    }

    /// Filename for a cache key.
    ///
    /// The hash **must not** be `String.hashValue`. Swift seeds its hasher
    /// randomly per process, so `hashValue` returns a different number for the
    /// same key on every launch — which named the same response a different file
    /// each time the app started. The cache therefore missed on every cold
    /// start, re-spending the organisation-wide request budget it exists to
    /// protect, and left the previous launch's copy behind as garbage. (It also
    /// trapped, rarely: `abs()` overflows on `Int.min`.)
    ///
    /// FNV-1a instead: a few lines, no dependency, and identical across launches
    /// and devices, which is the only property that matters here.
    static func filename(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        // The readable tail is kept for anyone inspecting the container; the
        // hash is what makes the name unique and filesystem-safe.
        let readable = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .suffix(96)
        return String(format: "%016llx", hash) + "-" + readable
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(Self.filename(for: key))
    }

    public func entry(for key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func entry(for key: String, lease: PublicationLease) -> LeaseLookup {
        guard !revokedPublicationLeases.contains(lease.id) else { return .revoked }
        return .available(entry(for: key))
    }

    public func store(_ data: Data, for key: String, now: Date = Date()) {
        let entry = Entry(data: data, storedAt: now)
        guard let encoded = try? JSONEncoder().encode(entry) else { return }
        try? encoded.write(to: url(for: key), options: .atomic)
    }

    /// Publishes only while this client still owns a live cache lease.
    ///
    /// The injected wait exists only in the package-internal initializer used
    /// by deterministic tests. In every production instance it is an immediate
    /// no-op. The cancellation and revocation check after that possible
    /// suspension is the linearization point: `store` is synchronous actor work,
    /// so no revocation, cancellation-aware publication, or competing commit can
    /// interleave between the decision and the atomic file replacement.
    func publish(_ data: Data, for key: String, lease: PublicationLease) async -> Bool {
        await beforePublicationCommit()
        guard !Task.isCancelled,
              !revokedPublicationLeases.contains(lease.id) else { return false }
        store(data, for: key)
        return true
    }

    func revoke(_ lease: PublicationLease) {
        revokedPublicationLeases.insert(lease.id)
    }

    func remove(_ key: String, lease: PublicationLease) {
        guard !revokedPublicationLeases.contains(lease.id) else { return }
        remove(key)
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
