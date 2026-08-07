import Foundation

/// One personal API key, handed from the phone to the wrist on purpose.
///
/// **Why an envelope at all, rather than letting the keychain sync it.**
/// `KeychainTokenStore` pins every credential to
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with no iCloud sync, because
/// a personal API key is a bearer credential for the user's entire PostHog
/// account. That decision is not an obstacle to work around here; it is the
/// reason this type exists. The wrist gets its own copy only through an
/// explicit user action on the phone, and that copy is written straight into
/// the watch's own keychain through the same store discipline —
/// `kSecUseDataProtectionKeychain`, this-device-only, no sync — rather than
/// being replicated by a service neither device asked.
///
/// **What this type is not.** It carries no `WatchConnectivity` and imports
/// nothing but Foundation, so it compiles on every platform the package
/// declares. The kit owns the payload's shape, its codec and its ingestion; the
/// *transport* belongs to the apps — a `WCSession` sender on the phone and a
/// receiver on the wrist. Both name the payload with `userInfoKey` so the one
/// thing left to disagree about is spelled in exactly one place.
///
/// **Why a version field on a value both ends ship together.** They do not ship
/// together. A watch app is reviewed and installed independently of its phone
/// app, so at any moment either end can be a release ahead. The decode is
/// therefore tolerant in the direction that costs nothing — unknown keys are
/// ignored, absent optionals stay absent — and strict only about `key` and
/// `region`, which a payload cannot authenticate anything without.
public struct WatchKeyTransfer: Codable, Sendable, Equatable {

    /// The non-secret half of the payload, returned by `ingest(into:)` for the
    /// caller to apply to its own state.
    ///
    /// Deliberately cannot carry the key: the key goes to the store and
    /// nowhere else, so a receiver that logs, renders or persists what it got
    /// back cannot leak the credential by accident.
    public struct Selection: Sendable, Equatable {
        public let projectID: Int?
        public let projectName: String?
        /// `SharedSnapshot.Metric.id` — the same value the Mac menu bar keeps
        /// under `menuBarHeadlineMetricID`, and what `MetricWatch.metricID`
        /// names.
        public let headlineMetricID: String?
        /// The user's thresholds, so the wrist can evaluate them against the
        /// snapshot it already reads. See the property of the same name on the
        /// enclosing type.
        public let watches: [MetricWatch]
        /// True when `watches` is empty **because the list could not be read**,
        /// not because there was none.
        ///
        /// The two are the same array and completely different facts, and a
        /// receiver that cannot tell them apart shows a calm, empty Health
        /// screen to a user with five alerts armed. Whatever the wrist would
        /// say for "no watches yet", it must say something else for this.
        public let watchesDegraded: Bool

        /// Explicit rather than memberwise, and `watchesDegraded` is defaulted,
        /// so a call site written before the flag existed still compiles and
        /// still means what it meant.
        public init(
            projectID: Int?,
            projectName: String?,
            headlineMetricID: String?,
            watches: [MetricWatch],
            watchesDegraded: Bool = false
        ) {
            self.projectID = projectID
            self.projectName = projectName
            self.headlineMetricID = headlineMetricID
            self.watches = watches
            self.watchesDegraded = watchesDegraded
        }
    }

    public enum Failure: Error, Equatable {
        /// A key that is empty once trimmed. Refused before the store is
        /// touched, so a bad hand-off cannot overwrite a good credential.
        case emptyKey
        /// A payload from before this format existed. Carries the number it
        /// claimed, so a receiver can say what it saw.
        case unsupportedVersion(Int)
    }

    /// What this build writes. A receiver reading a higher number is looking at
    /// a payload from a newer phone and may say so; it is not an error.
    public static let currentVersion = 1

    /// The `WCSession` dictionary key both ends use.
    ///
    /// The kit does not dictate the channel, and does not pretend the three are
    /// interchangeable. They trade the same thing against each other, and this
    /// payload is a bearer credential, so the trade has to be made with open
    /// eyes: `transferUserInfo` queues the dictionary in the WatchConnectivity
    /// daemon's **on-disk outbox** until it is delivered, surviving relaunch and
    /// reboot, and `updateApplicationContext` persists its dictionary on both
    /// devices — in both cases the raw key rests outside the keychain, for a
    /// window the app does not control. `sendMessage` leaves nothing at rest but
    /// requires the counterpart to be reachable, so it will simply fail
    /// whenever the watch is off the wrist or out of range.
    ///
    /// Deliverability against the at-rest window, in other words, and the app
    /// sending the payload owns that choice. What the kit owns is that every
    /// one of those channels needs a dictionary key, and a sender and receiver
    /// that spell it differently fail silently and permanently — so the name is
    /// a constant here rather than a literal at each end.
    public static let userInfoKey = "app.gethog.watchKeyTransfer"

    public let version: Int
    public let key: String
    public let region: PostHogRegion
    public let projectID: Int?
    public let projectName: String?
    /// `SharedSnapshot.Metric.id` of the metric the wrist leads with.
    public let headlineMetricID: String?
    /// The user's metric watches, carried whole.
    ///
    /// The wrist's Health surface evaluates these against the shared snapshot
    /// locally, through `MetricWatchEvaluator`, and spends no request doing it.
    /// Sending the ids alone would have made the watch fetch a list the phone
    /// already had in hand at the moment of the hand-off.
    public let watches: [MetricWatch]
    /// True when `watches` is empty **because the payload's list could not be
    /// decoded**, false when it is empty because there was nothing to send.
    ///
    /// Not a field on the wire and deliberately not one: it is what *this*
    /// decode found, so a sender cannot claim it and `encoded()` does not
    /// carry it. Constructing a payload leaves it false.
    ///
    /// It exists because the tolerant decode below has a failure mode that
    /// looks exactly like success. A newer phone adding a `MetricWatch.Condition`
    /// case makes the whole array undecodable here; swallowing that yields
    /// `[]`, and `[]` is also what a user with no alerts has. Without this flag
    /// the wrist shows the same calm, empty Health screen either way — to
    /// someone who armed five thresholds and will now never hear about any of
    /// them.
    public let watchesDegraded: Bool

    public init(
        version: Int = WatchKeyTransfer.currentVersion,
        key: String,
        region: PostHogRegion,
        projectID: Int? = nil,
        projectName: String? = nil,
        headlineMetricID: String? = nil,
        watches: [MetricWatch] = [],
        watchesDegraded: Bool = false
    ) {
        self.version = version
        self.key = key
        self.region = region
        self.projectID = projectID
        self.projectName = projectName
        self.headlineMetricID = headlineMetricID
        self.watches = watches
        self.watchesDegraded = watchesDegraded
    }

    // MARK: - Wire form

    /// No dates in the payload, so the default strategies are honest. Held as
    /// statics anyway, so a future dated field decides its strategy once rather
    /// than at each end.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// The wire form: JSON, through a kit-owned encoder, so both ends spell it
    /// identically.
    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Tolerant decode.
    ///
    /// Unknown keys are ignored — a newer phone may send fields this build has
    /// no property for. A missing `version` reads as 1, because the only
    /// payload that could omit it predates the field. Only a version *below*
    /// the floor is refused: a higher one is a newer phone, and dropping its
    /// key on the floor would strand a watch that could have authenticated
    /// perfectly well with the fields it did understand.
    public static func decode(_ data: Data) throws -> WatchKeyTransfer {
        try decoder.decode(WatchKeyTransfer.self, from: data)
    }

    /// `watchesDegraded` is absent on purpose — it is a decode-time
    /// observation, not a payload field, so the synthesised `encode(to:)`
    /// leaves it out and no hop can inherit a claim it cannot verify.
    enum CodingKeys: String, CodingKey {
        case version, key, region, projectID, projectName, headlineMetricID, watches
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version >= 1 else { throw Failure.unsupportedVersion(version) }

        // Required, and loudly so: a payload without either of these cannot
        // authenticate a single request, and a receiver that accepted one would
        // clear a working credential to store a broken one.
        key = try c.decode(String.self, forKey: .key)
        region = try c.decode(PostHogRegion.self, forKey: .region)

        projectID = try c.decodeIfPresent(Int.self, forKey: .projectID)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        headlineMetricID = try c.decodeIfPresent(String.self, forKey: .headlineMetricID)
        // Three states, not two, and the middle one is the whole reason this is
        // written out rather than being a `try?` one-liner:
        //
        // - **Absent, or null.** The phone sent no watch list. Empty is the
        //   truth and nothing was lost.
        // - **Present and readable.** The ordinary case.
        // - **Present and undecodable.** A `Condition` case a newer phone
        //   added, say. The thresholds are lost and the key is not — dropping
        //   the whole payload would punish the user for a field they never
        //   touched — but the receiver is *told*, because an empty list it
        //   cannot explain renders identically to having no alerts at all.
        if c.contains(.watches), try !c.decodeNil(forKey: .watches) {
            if let decoded = try? c.decode([MetricWatch].self, forKey: .watches) {
                watches = decoded
                watchesDegraded = false
            } else {
                watches = []
                watchesDegraded = true
            }
        } else {
            watches = []
            watchesDegraded = false
        }
    }

    // MARK: - Ingestion

    /// Validates the key, writes it through `store`, and returns the non-secret
    /// selections for the caller to apply.
    ///
    /// The key itself never leaves the store: `Selection` has no property for
    /// it. A store that refuses the write throws out of here rather than
    /// returning, so a receiver cannot report a hand-off that did not happen.
    @discardableResult
    public func ingest(into store: any CredentialStoring) throws -> Selection {
        // Trimmed exactly as `PersonalKeyAuthProvider` trims, so the key that
        // reaches the header is the key that was checked. An untrimmed one
        // builds `Bearer  …\n` and 401s forever.
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyKey }

        try store.save(
            StoredCredential(key: trimmed, region: region, projectID: projectID)
        )

        return Selection(
            projectID: projectID,
            projectName: projectName,
            headlineMetricID: headlineMetricID,
            watches: watches,
            watchesDegraded: watchesDegraded
        )
    }
}
