import Foundation

/// The entire contract between the app and its widgets.
///
/// Widgets **never** call the PostHog API. Rate limits are billed per
/// *organisation*, not per client, and that budget is shared with whatever the
/// user's own production integrations are doing. A handful of installed widgets
/// each refreshing on their own schedule would multiply request volume against a
/// budget that isn't ours to spend — and would do it invisibly, from a process
/// the user never launched. So the app fetches once, reduces the result to this
/// small value, and writes it to the App Group container. The widget's only job
/// is to render what it finds, and to be honest about how old it is.
public struct SharedSnapshot: Codable, Sendable, Equatable {

    public struct Metric: Codable, Sendable, Identifiable, Equatable {
        /// The insight id as a string — `AppEntity` identifiers are stringly
        /// typed and this value is round-tripped through widget configuration.
        public let id: String
        public let title: String
        public let value: Double
        public let unit: String?
        /// The comparison-period value. `nil` means "not known", which is not
        /// the same as "unchanged" and must not render as a flat delta.
        public let previous: Double?
        /// Oldest to newest. May be empty; the widget then draws no trend line
        /// rather than a straight one.
        public let sparkline: [Double]

        public init(
            id: String,
            title: String,
            value: Double,
            unit: String?,
            previous: Double?,
            sparkline: [Double]
        ) {
            self.id = id
            self.title = title
            self.value = value
            self.unit = unit
            self.previous = previous
            self.sparkline = sparkline
        }
    }

    public struct Flag: Codable, Sendable, Identifiable, Equatable {
        public let id: Int
        public let key: String
        public let active: Bool
        /// The user's per-flag opt-in, resolved by the app at write time.
        /// Outside the app there is no confirmation dialog to answer, so a flag
        /// is invisible to Control Center and interactive widgets until the
        /// user deliberately says otherwise.
        public let quickToggleAllowed: Bool

        public init(id: Int, key: String, active: Bool, quickToggleAllowed: Bool) {
            self.id = id
            self.key = key
            self.active = active
            self.quickToggleAllowed = quickToggleAllowed
        }
    }

    public let projectID: Int
    public let projectName: String
    public let metrics: [Metric]
    public let flags: [Flag]
    public let capturedAt: Date

    public init(
        projectID: Int,
        projectName: String,
        metrics: [Metric],
        flags: [Flag],
        capturedAt: Date
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.metrics = metrics
        self.flags = flags
        self.capturedAt = capturedAt
    }
}

// MARK: - Derived values

extension SharedSnapshot.Metric {

    public enum Direction: Sendable, Equatable {
        case up, down, flat
        /// No comparison value. The widget says so instead of drawing an arrow.
        case unknown
    }

    public var delta: Double? {
        guard let previous else { return nil }
        return value - previous
    }

    /// Relative change, e.g. `0.234` for +23.4%. `nil` when there is no
    /// baseline, or when the baseline is zero — every percentage against zero is
    /// infinite and "∞%" is not a number anyone can act on.
    public var deltaFraction: Double? {
        guard let previous, previous != 0, let delta else { return nil }
        return delta / abs(previous)
    }

    public var direction: Direction {
        guard let delta else { return .unknown }
        if delta > 0 { return .up }
        if delta < 0 { return .down }
        return .flat
    }
}

extension SharedSnapshot {

    /// How old this snapshot is, in seconds. Clamped at zero: clocks drift and
    /// snapshots outlive NTP corrections, and a negative age formats as
    /// "Updated in 5 minutes".
    public func staleness(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(capturedAt))
    }

    /// Default tolerance matches the widget's own refresh cadence: past this,
    /// the app has not synced for longer than a healthy timeline would allow, so
    /// the widget labels the value as stale rather than presenting it as live.
    public static let defaultStaleTolerance: TimeInterval = 30 * 60

    public func isStale(now: Date = Date(), tolerance: TimeInterval = SharedSnapshot.defaultStaleTolerance) -> Bool {
        staleness(now: now) > tolerance
    }

    public func metric(id: String) -> Metric? { metrics.first { $0.id == id } }

    public func flag(id: Int) -> Flag? { flags.first { $0.id == id } }

    /// The only flags a widget or control may offer to flip.
    public var quickToggleFlags: [Flag] { flags.filter(\.quickToggleAllowed) }
}

// MARK: - Pending writes

/// A flag change requested from a surface that must not perform network work.
///
/// A widget or Control Center toggle records the *intent* here and opens the
/// app; the app performs the authenticated write, applies whatever confirmation
/// or biometric gate the user configured, and clears the record. Nothing about
/// a flag write belongs in an extension process: it needs the keychain, the
/// rate-limit governor, and a place to show a failure.
public struct PendingFlagWrite: Codable, Sendable, Equatable {
    public let flagID: Int
    public let key: String
    public let desiredActive: Bool
    public let requestedAt: Date

    public init(flagID: Int, key: String, desiredActive: Bool, requestedAt: Date = Date()) {
        self.flagID = flagID
        self.key = key
        self.desiredActive = desiredActive
        self.requestedAt = requestedAt
    }
}

/// Where a widget or control asked the app to go when it opened it.
///
/// Foregrounding the app is all an extension can do on its own; without this the
/// user lands wherever they last were and has to navigate to the thing they just
/// tapped. Purely advisory — an app that ignores it still behaves correctly.
public struct PendingOpen: Codable, Sendable, Equatable {
    /// The metric (insight) to show, or `nil` for the dashboards home.
    public let metricID: String?
    public let requestedAt: Date

    public init(metricID: String?, requestedAt: Date = Date()) {
        self.metricID = metricID
        self.requestedAt = requestedAt
    }
}

// MARK: - Store

/// Reads and writes the snapshot as JSON in the App Group container.
///
/// A value type, not a singleton with hidden state: the widget extension, the
/// app, and the tests each construct their own and point it at a directory.
public struct SharedSnapshotStore: Sendable {

    public static let appGroupIdentifier = "group.app.gethog"

    private static let snapshotFileName = "snapshot.json"
    private static let pendingFlagFileName = "pending-flag.json"
    private static let pendingOpenFileName = "pending-open.json"

    public let directory: URL

    /// False when the App Group container was unavailable and a local fallback
    /// is in use — the app and the widget are then *not* talking to each other.
    /// Surfaced so callers can explain an empty widget instead of guessing.
    public let isSharedContainer: Bool

    public init(directory: URL, isSharedContainer: Bool = false) {
        self.directory = directory
        self.isSharedContainer = isSharedContainer
    }

    /// The store both processes use in production.
    public static let shared = resolve()

    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil
    /// without the entitlement — SwiftUI previews, an unsigned simulator build,
    /// a unit-test host. Falling back to a private directory keeps every call
    /// site total: nothing traps, nothing force-unwraps, and the widget simply
    /// renders its no-data state rather than crashing on a locked screen.
    static func resolve(
        appGroupIdentifier: String = SharedSnapshotStore.appGroupIdentifier,
        container: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    ) -> SharedSnapshotStore {
        if let url = container(appGroupIdentifier) {
            return SharedSnapshotStore(directory: url, isSharedContainer: true)
        }
        let fallback = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return SharedSnapshotStore(
            directory: fallback.appendingPathComponent("GetHogShared", isDirectory: true),
            isSharedContainer: false
        )
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.snapshotFileName) }

    public var pendingFlagURL: URL { directory.appendingPathComponent(Self.pendingFlagFileName) }

    public var pendingOpenURL: URL { directory.appendingPathComponent(Self.pendingOpenFileName) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Explicit and version-stable: app and extension are separate binaries
        // that can be built from different sources during a staged rollout, and
        // `.deferredToDate`'s reference-date doubles would silently drift if the
        // default ever changed.
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Snapshot

    public func write(_ snapshot: SharedSnapshot) throws {
        try writeJSON(snapshot, to: fileURL)
    }

    /// `nil` when nothing has been written yet — the ordinary state of a widget
    /// installed before the app's first sync, not an error.
    public func read() throws -> SharedSnapshot? {
        try readJSON(SharedSnapshot.self, from: fileURL)
    }

    /// Non-throwing read for render paths. A widget has no way to present a
    /// decoding failure, and a corrupt file must degrade to "no data" rather
    /// than to a blank rectangle.
    public func loadOrNil() -> SharedSnapshot? {
        try? read()
    }

    // MARK: Pending flag write

    public func enqueue(_ request: PendingFlagWrite) throws {
        try writeJSON(request, to: pendingFlagURL)
    }

    public func pendingFlagWrite() -> PendingFlagWrite? {
        try? readJSON(PendingFlagWrite.self, from: pendingFlagURL)
    }

    /// Called by the app once the write has been applied or abandoned. Leaving
    /// the record behind would re-apply the toggle on the next launch.
    public func clearPendingFlagWrite() {
        try? FileManager.default.removeItem(at: pendingFlagURL)
    }

    // MARK: Pending open

    public func enqueue(_ open: PendingOpen) throws {
        try writeJSON(open, to: pendingOpenURL)
    }

    public func pendingOpen() -> PendingOpen? {
        try? readJSON(PendingOpen.self, from: pendingOpenURL)
    }

    public func clearPendingOpen() {
        try? FileManager.default.removeItem(at: pendingOpenURL)
    }

    // MARK: Plumbing

    private func writeJSON(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(value)
        // Atomic so a widget reload mid-write can never see a half file.
        // `completeFileProtectionUntilFirstUserAuthentication` rather than the
        // stricter `completeFileProtection`: Lock Screen accessory widgets
        // render while the device is locked, and unreadable data there is
        // indistinguishable from no data at all.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(type, from: data)
    }
}
