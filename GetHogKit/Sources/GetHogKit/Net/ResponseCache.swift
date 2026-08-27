import CryptoKit
import Foundation

struct ResponseCacheStoredFile: Sendable {
    let url: URL
    let size: Int?
    let modifiedAt: Date?
}

/// Synchronous filesystem boundary used only from the `ResponseCache` actor.
///
/// Keeping this as a production protocol makes storage failures deterministic
/// to test without a debug branch, while the actor remains the sole owner of
/// ordering, generations, and cleanup obligations.
protocol ResponseCacheStorage: Sendable {
    func createDirectory(at url: URL) throws
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func contents(of directory: URL) throws -> [ResponseCacheStoredFile]
    func remove(_ url: URL) throws
}

private struct FileResponseCacheStorage: ResponseCacheStorage {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func contents(of directory: URL) throws -> [ResponseCacheStoredFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ).map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return ResponseCacheStoredFile(
                url: url,
                size: values?.fileSize,
                modifiedAt: values?.contentModificationDate
            )
        }
    }

    func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let cocoa = error as NSError
            guard cocoa.domain == NSCocoaErrorDomain,
                  cocoa.code == NSFileNoSuchFileError
            else { throw error }
        }
    }
}

/// Disk-backed response cache in the App Group container.
///
/// The app is cache-first by necessity: rate limits are organisation-wide, and
/// widgets must render with no network at all. Every cached entry carries the
/// time it was stored so the UI can show an honest "Updated 5m ago" rather than
/// implying data is live.
public actor ResponseCache {
    struct PublicationLease: Hashable, Sendable {
        let namespace: String
        let id: UUID
        let generation: UInt64
    }

    enum LeaseLookup: Sendable {
        case available(Entry?)
        case revoked
    }

    enum PublicationResult: Sendable {
        case published
        case revoked
        case storageFailure
    }

    public struct Entry: Sendable, Codable {
        public let data: Data
        public let storedAt: Date

        public func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
            now.timeIntervalSince(storedAt) < ttl
        }
    }

    private let directory: URL
    private let storage: any ResponseCacheStorage
    private let beforePublicationCommit: @Sendable () async -> Void
    private let beforeGenerationClear: @Sendable () async -> Void
    private var publicationGeneration: UInt64 = 0
    private var revokedPublicationLeases: Set<UUID> = []
    private var pendingCleanup: CleanupObligation?

    private enum CleanupObligation: Equatable {
        case legacy
        case all
    }

    private static let legacyCleanupMarker = ".gethog-response-cache-legacy-cleanup-v2"
    private static let fullCleanupMarker = ".gethog-response-cache-full-cleanup-v2"

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
        let storage = FileResponseCacheStorage()
        let directory = Self.directory(appGroupID: appGroupID, subdirectory: subdirectory)
        self.beforePublicationCommit = {}
        self.beforeGenerationClear = {}
        self.directory = directory
        self.storage = storage
        self.pendingCleanup = Self.initialCleanupState(
            directory: directory,
            storage: storage
        )
    }

    /// Internal injection point for deterministic actor-ordering tests.
    ///
    /// The public initializer always installs immediate no-ops. Tests can
    /// suspend immediately before the final publication validity check or after
    /// generation revocation but before clear, without adding a debug branch or
    /// changing any app-visible cache behavior.
    init(
        appGroupID: String? = nil,
        subdirectory: String = "PostHogCache",
        beforePublicationCommit: @escaping @Sendable () async -> Void,
        beforeGenerationClear: @escaping @Sendable () async -> Void = {}
    ) {
        let storage = FileResponseCacheStorage()
        let directory = Self.directory(appGroupID: appGroupID, subdirectory: subdirectory)
        self.beforePublicationCommit = beforePublicationCommit
        self.beforeGenerationClear = beforeGenerationClear
        self.directory = directory
        self.storage = storage
        self.pendingCleanup = Self.initialCleanupState(
            directory: directory,
            storage: storage
        )
    }

    /// Internal production-shaped filesystem injection for deterministic
    /// failure and next-launch cleanup tests.
    init(
        directory: URL,
        storage: any ResponseCacheStorage,
        beforePublicationCommit: @escaping @Sendable () async -> Void = {},
        beforeGenerationClear: @escaping @Sendable () async -> Void = {}
    ) {
        self.beforePublicationCommit = beforePublicationCommit
        self.beforeGenerationClear = beforeGenerationClear
        self.directory = directory
        self.storage = storage
        self.pendingCleanup = Self.initialCleanupState(
            directory: directory,
            storage: storage
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

    /// Versioned opaque filename for the complete cache key.
    ///
    /// `String.hashValue` is process-random, while the old stable FNV name
    /// appended a readable suffix containing the authentication epoch and full
    /// URL. SHA-256 is deterministic across launches and leaves no host,
    /// project/object identifier, query, or epoch readable at rest. Request
    /// headers and PATs never enter the key in the first place.
    static func filename(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "v2-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isDataFilename(_ name: String) -> Bool {
        guard name.count == 67, name.hasPrefix("v2-") else { return false }
        return name.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isLegacyFilename(_ name: String) -> Bool {
        guard name.count >= 18 else { return false }
        let separator = name.index(name.startIndex, offsetBy: 16)
        return name[..<separator].allSatisfy(\.isHexDigit) && name[separator] == "-"
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(Self.filename(for: key))
    }

    public func entry(for key: String) -> Entry? {
        guard prepareForDataAccess(),
              let data = try? storage.read(from: url(for: key))
        else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func issuePublicationLease(namespace: String) -> PublicationLease {
        PublicationLease(
            namespace: namespace,
            id: UUID(),
            generation: publicationGeneration
        )
    }

    func entry(for key: String, lease: PublicationLease) -> LeaseLookup {
        guard lease.generation == publicationGeneration,
              !revokedPublicationLeases.contains(lease.id) else { return .revoked }
        return .available(entry(for: key))
    }

    @discardableResult
    public func store(_ data: Data, for key: String, now: Date = Date()) -> Bool {
        guard prepareForDataAccess() else { return false }
        let entry = Entry(data: data, storedAt: now)
        guard let encoded = try? JSONEncoder().encode(entry) else { return false }
        do {
            try storage.write(encoded, to: url(for: key))
            return true
        } catch {
            return false
        }
    }

    /// Publishes only while this client still owns a live cache lease.
    ///
    /// The injected wait exists only in the package-internal initializer used
    /// by deterministic tests. In every production instance it is an immediate
    /// no-op. The cancellation and revocation check after that possible
    /// suspension is the linearization point: `store` is synchronous actor work,
    /// so no revocation, cancellation-aware publication, or competing commit can
    /// interleave between the decision and the atomic file replacement.
    func publish(
        _ data: Data,
        for key: String,
        lease: PublicationLease
    ) async -> PublicationResult {
        await beforePublicationCommit()
        guard !Task.isCancelled,
              lease.generation == publicationGeneration,
              !revokedPublicationLeases.contains(lease.id) else { return .revoked }
        return store(data, for: key) ? .published : .storageFailure
    }

    func revoke(_ lease: PublicationLease) {
        revokedPublicationLeases.insert(lease.id)
    }

    @discardableResult
    func remove(_ key: String, lease: PublicationLease) -> Bool {
        guard lease.generation == publicationGeneration,
              !revokedPublicationLeases.contains(lease.id) else { return false }
        return remove(key)
    }

    /// Invalidates every publication lease issued by this cache before the
    /// boundary, then removes the data those leases could read.
    ///
    /// Generation advance is synchronous actor work and is therefore the
    /// revocation linearization point. The internal wait is an immediate no-op
    /// in production; deterministic tests can suspend after revocation but
    /// before the ordered clear to exercise AppModel replacement races.
    @discardableResult
    public func revokeAllPublicationsAndClear() async -> Bool {
        publicationGeneration &+= 1
        revokedPublicationLeases.removeAll()
        await beforeGenerationClear()
        return clear()
    }

    @discardableResult
    public func remove(_ key: String) -> Bool {
        guard prepareForDataAccess() else { return false }
        do {
            try storage.remove(url(for: key))
            return true
        } catch {
            requestCleanup(.all)
            return false
        }
    }

    @discardableResult
    public func clear() -> Bool {
        requestCleanup(.all)
        return retryPendingCleanup()
    }

    public func totalSizeBytes() -> Int {
        _ = retryPendingCleanup()
        guard let contents = try? storage.contents(of: directory) else { return 0 }
        return contents.reduce(0) { sum, file in
            sum + (file.size ?? 0)
        }
    }

    /// Evicts oldest-first until the cache fits the budget. Used to bound the
    /// replay blob cache, which is otherwise permanent.
    @discardableResult
    public func evict(toFitBytes budget: Int) -> Bool {
        guard prepareForDataAccess(),
              let contents = try? storage.contents(of: directory)
        else { return false }

        var files = contents.compactMap { file -> (URL, Int, Date)? in
            guard Self.isDataFilename(file.url.lastPathComponent),
                  let size = file.size,
                  let modified = file.modifiedAt
            else { return nil }
            return (file.url, size, modified)
        }

        var total = files.reduce(0) { $0 + $1.1 }
        guard total > budget else { return true }

        files.sort { $0.2 < $1.2 }
        var succeeded = true
        for (url, size, _) in files {
            guard total > budget else { break }
            do {
                try storage.remove(url)
                total -= size
            } catch {
                succeeded = false
            }
        }
        return succeeded && total <= budget
    }

    private static func initialCleanupState(
        directory: URL,
        storage: any ResponseCacheStorage
    ) -> CleanupObligation? {
        var pendingCleanup: CleanupObligation?
        do {
            try storage.createDirectory(at: directory)
            let contents = try storage.contents(of: directory)
            let names = Set(contents.map { $0.url.lastPathComponent })
            if names.contains(Self.fullCleanupMarker) {
                pendingCleanup = .all
            } else if names.contains(Self.legacyCleanupMarker)
                        || names.contains(where: Self.isLegacyFilename) {
                pendingCleanup = .legacy
            }
            _ = performPendingCleanup(
                pending: &pendingCleanup,
                directory: directory,
                storage: storage
            )
        } catch {
            requestCleanup(
                .legacy,
                pending: &pendingCleanup,
                directory: directory,
                storage: storage
            )
        }
        return pendingCleanup
    }

    private func prepareForDataAccess() -> Bool {
        pendingCleanup == nil || retryPendingCleanup()
    }

    private func requestCleanup(_ requested: CleanupObligation) {
        Self.requestCleanup(
            requested,
            pending: &pendingCleanup,
            directory: directory,
            storage: storage
        )
    }

    private static func requestCleanup(
        _ requested: CleanupObligation,
        pending pendingCleanup: inout CleanupObligation?,
        directory: URL,
        storage: any ResponseCacheStorage
    ) {
        switch (pendingCleanup, requested) {
        case (.all, _), (_, .all):
            pendingCleanup = .all
        case (nil, .legacy), (.legacy, .legacy):
            pendingCleanup = .legacy
        }
        let marker = pendingCleanup == .all
            ? Self.fullCleanupMarker
            : Self.legacyCleanupMarker
        try? storage.write(Data(), to: directory.appendingPathComponent(marker))
    }

    private func retryPendingCleanup() -> Bool {
        Self.performPendingCleanup(
            pending: &pendingCleanup,
            directory: directory,
            storage: storage
        )
    }

    private static func performPendingCleanup(
        pending pendingCleanup: inout CleanupObligation?,
        directory: URL,
        storage: any ResponseCacheStorage
    ) -> Bool {
        guard let obligation = pendingCleanup else { return true }
        let marker = obligation == .all
            ? Self.fullCleanupMarker
            : Self.legacyCleanupMarker
        let markerURL = directory.appendingPathComponent(marker)
        try? storage.createDirectory(at: directory)
        try? storage.write(Data(), to: markerURL)

        guard let contents = try? storage.contents(of: directory) else { return false }
        var succeeded = true
        for file in contents {
            let name = file.url.lastPathComponent
            let shouldRemove = switch obligation {
            case .legacy:
                Self.isLegacyFilename(name)
            case .all:
                name != Self.fullCleanupMarker
            }
            guard shouldRemove else { continue }
            do {
                try storage.remove(file.url)
            } catch {
                succeeded = false
            }
        }
        guard succeeded else { return false }
        do {
            try storage.remove(markerURL)
            pendingCleanup = nil
            return true
        } catch {
            return false
        }
    }
}
