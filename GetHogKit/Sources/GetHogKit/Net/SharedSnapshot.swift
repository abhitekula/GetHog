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
        /// The dashboard this metric was read from, so tapping a widget can land
        /// on the screen that actually draws it.
        ///
        /// The id is recorded at write time, where the dashboard is already in
        /// hand and costs nothing; deriving it later would mean a request, or a
        /// guess.
        ///
        /// This used to say the app had no screen for a lone insight and drew
        /// one only as a dashboard tile. **That is no longer true** — the app
        /// has a saved-insight library and a detail screen, and the link parser
        /// resolves `/insights/{id}` rather than refusing it.
        ///
        /// The field is unchanged regardless, and this is the honest reason
        /// rather than the old one: a `Metric` has never carried an insight id.
        /// It carries a title, a value and the dashboard it was read from,
        /// because that is what the widget's writer had. Routing a widget tap to
        /// an insight would mean matching on the title, which is a guess — and a
        /// control labelled with a metric landing on some other object that
        /// happens to share its name is a worse outcome than landing on the
        /// dashboard that definitely contains it.
        ///
        /// `nil` means **unknown**, not "no dashboard": a snapshot written by an
        /// older build has no such key. Callers route it to the dashboards home
        /// rather than inventing a destination.
        ///
        /// Deliberately without a default in this initialiser. Every call site
        /// is made to answer, because the failure mode of forgetting is silent —
        /// the widget still opens, just one level short of where it promised.
        public let dashboardID: Int?

        public init(
            id: String,
            title: String,
            value: Double,
            unit: String?,
            previous: Double?,
            sparkline: [Double],
            dashboardID: Int?
        ) {
            self.id = id
            self.title = title
            self.value = value
            self.unit = unit
            self.previous = previous
            self.sparkline = sparkline
            self.dashboardID = dashboardID
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
    /// Ingestion warnings, reduced. `nil` means **not checked** — an app build
    /// that predates the section, or a fetch PostHog refused — which is a
    /// different claim from "healthy" and must never render as one.
    public let ingestion: IngestionDigest?
    /// Metered resources, reduced. `nil` for the same reason, and it carries its
    /// own capture time because it is refreshed on a slower clock than the rest
    /// of this value. See `QuotaDigest.refreshInterval`.
    public let quota: QuotaDigest?
    public let capturedAt: Date

    public init(
        projectID: Int,
        projectName: String,
        metrics: [Metric],
        flags: [Flag],
        ingestion: IngestionDigest? = nil,
        quota: QuotaDigest? = nil,
        capturedAt: Date
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.metrics = metrics
        self.flags = flags
        self.ingestion = ingestion
        self.quota = quota
        self.capturedAt = capturedAt
    }

    // MARK: - Decoding across binaries

    /// Written by the app, read by a **separately installed extension binary**.
    ///
    /// The two are updated independently — a widget can be a release ahead of the
    /// app or a release behind it — so this decode has to survive a snapshot from
    /// either direction. Swift's synthesised keyed decoding already ignores keys
    /// it has no property for, which is what lets an *older* widget read a
    /// *newer* snapshot; this hand-written version preserves that and adds the
    /// other direction, splitting the fields into two groups on one rule:
    ///
    /// - **Required** — `projectID`, `projectName`, `capturedAt`. Each one is a
    ///   field the widget would have to *lie* to substitute. A missing project
    ///   name renders somebody else's numbers under the wrong heading, and a
    ///   missing capture time defaulted to `Date()` makes every stale snapshot
    ///   claim to be current, which is precisely what the freshness footer
    ///   exists to prevent.
    /// - **Tolerant** — everything else. A section this build does not
    ///   understand, or that a newer app has not written, costs that section and
    ///   nothing else: the widget renders the parts it did get, and says so.
    ///
    /// The alternative — one strict decode — turns any single field a future
    /// release renames into a total blank on the Lock Screen, which looks
    /// identical to a broken widget.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(Int.self, forKey: .projectID)
        projectName = try c.decode(String.self, forKey: .projectName)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        metrics = try c.decodeIfPresent([Metric].self, forKey: .metrics) ?? []
        flags = try c.decodeIfPresent([Flag].self, forKey: .flags) ?? []
        // `try?`, not `try`: a section whose own decode throws — a future field
        // that turned out to be required, a missing timestamp — is dropped, and
        // the rest of the snapshot still renders.
        ingestion = (try? c.decodeIfPresent(IngestionDigest.self, forKey: .ingestion)) ?? nil
        quota = (try? c.decodeIfPresent(QuotaDigest.self, forKey: .quota)) ?? nil
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

    /// The unprefixed App Group identifier — exactly what iOS declares.
    /// Prefer `appGroupIdentifier(teamIDPrefix:)` when resolving a container:
    /// it spells the identifier the way the running platform requires.
    public static let appGroupIdentifier = "group.app.gethog"

    /// The App Group identifier as the running platform spells it.
    ///
    /// macOS requires the signing Team ID in front of an App Group identifier
    /// under the App Sandbox — `<TeamID>.group.app.gethog` — while iOS forbids
    /// exactly that. The prefix belongs to whoever signs the app, so the kit
    /// cannot name it: a target publishes it through its own `Info.plist` (see
    /// `teamIDPrefixInfoKey`), and a `nil` or empty prefix degrades to the
    /// unprefixed identifier — today's behavior on every platform. On iOS the
    /// prefix is ignored outright, so no caller can accidentally change what
    /// shipping widgets already read.
    public static func appGroupIdentifier(teamIDPrefix: String?) -> String {
        resolvedAppGroupIdentifier(
            teamIDPrefix: teamIDPrefix,
            requiresTeamIDPrefix: platformRequiresTeamIDPrefix
        )
    }

    /// The `Info.plist` key through which a bundle publishes the Team ID prefix
    /// its App Group identifier needs.
    ///
    /// Only the signer knows the prefix, and a committed Team ID is the one
    /// thing this repository must never contain — so it cannot be a literal on
    /// either side. It travels as `$(TeamIdentifierPrefix)`, which is the same
    /// substitution the Release entitlement performs on
    /// `$(TeamIdentifierPrefix)group.app.gethog`: the entitlement and this
    /// lookup are then two spellings of one build setting and cannot disagree
    /// about the container's name.
    ///
    /// Published by the macOS app and its widget extension only. iOS bundles
    /// do not carry the key, and would ignore it if they did.
    public static let teamIDPrefixInfoKey = "GetHogTeamIDPrefix"

    /// The prefix `bundle` publishes, or `nil` when it publishes none usable.
    ///
    /// `Bundle.main` on purpose: the app and the extension are separate
    /// processes with separate bundles, and each has to read its *own* — an
    /// appex asking the host for this would be asking a bundle it cannot see.
    public static func teamIDPrefix(from bundle: Bundle = .main) -> String? {
        teamIDPrefix(fromInfoValue: bundle.object(forInfoDictionaryKey: teamIDPrefixInfoKey))
    }

    /// The rule that turns a raw `Info.plist` value into a prefix, split out so
    /// every spelling can be pinned without building a bundle.
    ///
    /// Three different values all mean "no prefix", and each is a real state:
    ///
    /// - **Absent.** Every iOS bundle, deliberately, and any build made before
    ///   the key existed.
    /// - **Empty.** What `$(TeamIdentifierPrefix)` substitutes to when there is
    ///   no team — an unsigned local build, which is what a fresh clone makes.
    /// - **Unsubstituted.** The literal `$(TeamIdentifierPrefix)`, which is
    ///   what arrives if `Info.plist` build-setting expansion is ever switched
    ///   off. Left alone it would name the container
    ///   `$(TeamIdentifierPrefix).group.app.gethog` — a path that resolves, is
    ///   creatable, passes the usability probe, and that the *other* process
    ///   would never look in. Silent and permanent, and indistinguishable from
    ///   a broken widget: precisely the failure this mechanism exists to
    ///   prevent, so it is refused rather than trusted. Any `$` is enough to
    ///   detect it — a Team ID prefix is alphanumerics and a trailing dot.
    static func teamIDPrefix(fromInfoValue value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$") else { return nil }
        return trimmed
    }

    /// The App Group identifier **this process** resolves: the base spelling,
    /// plus whatever prefix its own bundle publishes, where the platform
    /// demands one.
    ///
    /// `resolve`'s default and therefore `shared`'s identifier. Public because
    /// a caller reaching the same container by another route — `UserDefaults`
    /// with a suite name, say — must not be able to spell it differently by
    /// accident: two spellings are two containers, and the second one is
    /// always empty.
    public static let bundleAppGroupIdentifier = appGroupIdentifier(teamIDPrefix: teamIDPrefix())

    /// True where App Group identifiers carry the Team ID prefix (macOS under
    /// the sandbox), false where they must not (iOS and its extensions, and the
    /// watchOS, tvOS and visionOS apps).
    ///
    /// The `#else` is the answer for four platforms, not one, and that is
    /// deliberate: only the Mac sandbox demands the prefix, so every other
    /// shell resolves the same `group.app.gethog` the phone writes and reads
    /// the phone's snapshot without a line of platform code. `SharedSnapshotTests`
    /// pins each of those four separately, so an `#elseif` added here for one
    /// platform cannot quietly rename another's container.
    static var platformRequiresTeamIDPrefix: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The platform-independent rule behind `appGroupIdentifier(teamIDPrefix:)`,
    /// split out so tests can pin both branches from whichever platform runs
    /// them.
    static func resolvedAppGroupIdentifier(
        teamIDPrefix: String?,
        requiresTeamIDPrefix: Bool
    ) -> String {
        guard requiresTeamIDPrefix, let teamIDPrefix, !teamIDPrefix.isEmpty else {
            return appGroupIdentifier
        }
        // `$(TeamIdentifierPrefix)` renders with a trailing dot and a raw Team
        // ID has none; accept both rather than let container resolution fail
        // invisibly over punctuation.
        let trimmed = teamIDPrefix.hasSuffix(".")
            ? String(teamIDPrefix.dropLast())
            : teamIDPrefix
        return "\(trimmed).\(appGroupIdentifier)"
    }

    private static let snapshotFileName = "snapshot.json"
    private static let pendingFlagFileName = "pending-flag.json"
    private static let pendingOpenFileName = "pending-open.json"
    private static let metricWatchesFileName = "metric-watches.json"
    private static let breachingWatchIDsFileName = "metric-watch-breaches.json"

    public let directory: URL

    /// False when the App Group container was unavailable and a local fallback
    /// is in use — the app and the widget are then *not* talking to each other.
    /// Surfaced so callers can explain an empty widget instead of guessing.
    public let isSharedContainer: Bool

    public init(directory: URL, isSharedContainer: Bool = false) {
        self.directory = directory
        self.isSharedContainer = isSharedContainer
    }

    /// The store both processes use in production, on every platform.
    ///
    /// It resolves `bundleAppGroupIdentifier`, so the spelling follows the
    /// process it is running in rather than a compile-time guess: unprefixed
    /// on iOS always, and on macOS prefixed exactly when the bundle publishes
    /// a substituted `GetHogTeamIDPrefix` — which is exactly when the
    /// entitlement granting that container was substituted from the same build
    /// setting.
    ///
    /// This used to resolve the unprefixed identifier everywhere, and the two
    /// halves of that were not equally harmless. On iOS it was correct. On a
    /// signed Mac Release it asked for a container the entitlement did not
    /// grant; the usability probe then did its job and sent the process to a
    /// private caches directory — the app to its own, the widget extension to
    /// its own — so every widget rendered its empty state forever, with no
    /// error anywhere, on the one build a user would actually install.
    public static let shared = resolve()

    /// `containerURL(forSecurityApplicationGroupIdentifier:)` answers nil
    /// without the entitlement on iOS — SwiftUI previews, an unsigned
    /// simulator build, a unit-test host. **On macOS it does not**: the lookup
    /// returns a path with or without the entitlement, and the App Sandbox
    /// then denies creating it — measured on macOS Debug, where the App Group
    /// is deliberately absent from the entitlements. Before `probe` existed,
    /// that path was trusted, every write's own `createDirectory` failed, and
    /// the `try?` at the call sites swallowed it: all snapshot writes silently
    /// no-oped while `isSharedContainer` claimed otherwise.
    ///
    /// So a container is trusted only after it proves it can hold a file:
    /// `probe` attempts the directory's creation — the exact operation the
    /// first write would perform — and an unusable container degrades to the
    /// same private-directory fallback a nil lookup always produced. Nothing
    /// traps, nothing force-unwraps, and a caller can read
    /// `isSharedContainer == false` instead of guessing why the widget is
    /// empty.
    ///
    /// The identifier defaults to `bundleAppGroupIdentifier` rather than to the
    /// bare base spelling: a caller that does not pass one is asking for "this
    /// process's container", and on a signed Mac that is the prefixed name.
    public static func resolve(
        appGroupIdentifier: String = SharedSnapshotStore.bundleAppGroupIdentifier,
        container: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        },
        probe: (URL) -> Bool = SharedSnapshotStore.containerIsUsable
    ) -> SharedSnapshotStore {
        if let url = container(appGroupIdentifier), probe(url) {
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

    /// Usability is established the way writing would establish it: create the
    /// directory (a no-op when it already exists), then ask whether it is
    /// writable. No probe file is left behind.
    ///
    /// Public because it is `resolve`'s default argument, and a default
    /// argument of a public function may not name internal API — which also
    /// makes it available to a caller that resolves its own store and wants
    /// the same verdict.
    public static func containerIsUsable(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.snapshotFileName) }

    public var pendingFlagURL: URL { directory.appendingPathComponent(Self.pendingFlagFileName) }

    public var pendingOpenURL: URL { directory.appendingPathComponent(Self.pendingOpenFileName) }

    public var metricWatchesURL: URL { directory.appendingPathComponent(Self.metricWatchesFileName) }

    public var breachingWatchIDsURL: URL {
        directory.appendingPathComponent(Self.breachingWatchIDsFileName)
    }

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

    // MARK: Metric watches

    /// Beside the snapshot rather than in `UserDefaults`, for the same reason
    /// the snapshot is: a future notification-service or widget extension can
    /// read the user's watches without the app being running, and the file
    /// format is then the whole contract between the two processes.
    public func writeMetricWatches(_ watches: [MetricWatch]) throws {
        try writeJSON(watches, to: metricWatchesURL)
    }

    /// Non-throwing: a background wake has nowhere to report a decoding failure,
    /// and a corrupt watch list must not be able to stop the snapshot itself
    /// from being published.
    public func metricWatches() -> [MetricWatch] {
        (try? readJSON([MetricWatch].self, from: metricWatchesURL)) ?? []
    }

    /// The latch that stops a two-hourly wake re-notifying about one bad number.
    ///
    /// Kept in its own file, as the two pending-write records are: editing a
    /// watch rewrites the list, and folding the latch into the same file would
    /// make every edit a chance to lose it.
    public func writeBreachingWatchIDs(_ ids: Set<String>) throws {
        try writeJSON(ids, to: breachingWatchIDsURL)
    }

    public func breachingWatchIDs() -> Set<String> {
        (try? readJSON(Set<String>.self, from: breachingWatchIDsURL)) ?? []
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
