import Foundation

// The data taxonomy: what events a project actually receives, what properties
// those events carry, and what a human has curated on top of that.
//
// Two sources answer overlapping but *different* questions, and the difference
// is load-bearing:
//
// * `TeamTaxonomyQuery` counts events **received in the last 30 days**, then —
//   on the final page — pads its answer with PostHog's well-known event names at
//   `count: 0`, whether or not the project has ever sent them.
// * `/event_definitions/` lists every event name the project has **ever**
//   ingested, with the curation state (`verified`, `hidden`, description).
//
// So the two totals do not agree, and neither is "the number of events this
// project has". `TaxonomyEvent.merge` keeps the distinction rather than
// collapsing it.

// MARK: - Volumes

/// One row of `TeamTaxonomyQuery`: an event name and its 30-day volume.
///
/// Unlike `GroupsQuery`, this query kind answers with objects rather than
/// positional arrays, so it decodes directly.
public struct TaxonomyEventVolume: Sendable, Decodable, Hashable, Identifiable {
    public let event: String
    public let count: Int

    public var id: String { event }

    /// A zero here does not mean "no events lately" — it means the row is
    /// padding for a well-known name, or the event has genuinely gone quiet.
    /// Which of the two it is can only be settled against the definitions.
    public var wasSeen: Bool { count > 0 }
}

// MARK: - Property samples

/// One row of `EventTaxonomyQuery`: a property seen on an event, with a few of
/// its values.
public struct TaxonomyPropertySample: Sendable, Decodable, Hashable, Identifiable {
    public let property: String
    /// Distinct values found **within the sample**, not total occurrences.
    ///
    /// The query runner takes the 100 most recent matching events and counts
    /// `DISTINCT value` inside that slice, so this caps at 100 and says nothing
    /// about how often the property appears overall.
    public let sampleCount: Int
    public let sampleValues: [String]

    public var id: String { property }

    enum CodingKeys: String, CodingKey {
        case property
        case sampleCount = "sample_count"
        case sampleValues = "sample_values"
    }

    public init(property: String, sampleCount: Int, sampleValues: [String]) {
        self.property = property
        self.sampleCount = sampleCount
        self.sampleValues = sampleValues
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // **Absent whenever the request named its properties**, which `zip`
        // below already documents at length — and which a *required* decode
        // here made unreachable. Measured 2026-07-31 by routing
        // `ActorsPropertyTaxonomyQuery` in demo mode against its own recording
        // (`actors_property_taxonomy.json`, `{"results":[{"sample_count":51,
        // "sample_values":[…]}]}`, the shape `PostHogAPI.actorsPropertyTaxonomy`
        // records as measured): `Page<TaxonomyPropertySample>` threw
        // `DecodingError.keyNotFound … Path: results[0]`. `Page` has no lenient
        // element decode, so one missing key fails the whole page — meaning
        // `TaxonomyPropertyDetailView.loadActorSample`, the entire property
        // screen for a person- or group-scoped property, could not decode any
        // answer the server gives it. `zip` was written for exactly that
        // response and could never have received a row.
        //
        // Empty rather than optional so `id` stays non-optional and no call
        // site has to unwrap. Nothing should ever read the empty string: the
        // named form is only meaningful through `zip`, which replaces it with
        // the key that was asked for, and the discovery form always carries it.
        property = ((try? c.decodeIfPresent(String.self, forKey: .property)) ?? nil) ?? ""
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        // Values arrive as strings, but a numeric property has come back as a
        // JSON number, which would fail a `[String]` decode and drop the row.
        let rawValues = (try? c.decodeIfPresent([JSONValue].self, forKey: .sampleValues)) ?? nil
        sampleValues = rawValues?.compactMap(\.stringValue) ?? []
    }

    public var sampleSummary: String {
        "\(sampleCount) distinct value\(sampleCount == 1 ? "" : "s") in sample"
    }

    /// Joins the rows of a **named-properties** taxonomy response back to the
    /// keys that were asked for.
    ///
    /// `EventTaxonomyQuery` and `ActorsPropertyTaxonomyQuery` both drop the
    /// `property` key when the request named its properties: the rows are
    /// positional and parallel to the request array. A property with nothing
    /// recorded still holds its place — measured `{"sample_count": 0,
    /// "sample_values": []}` for a group property that exists in the definitions
    /// and has never been set — so index *i* is always key *i*.
    ///
    /// A short response is therefore a shape this code does not understand, not
    /// a shorter list: the surplus keys are dropped rather than being paired
    /// with whatever row happens to sit at their index.
    public static func zip(
        _ properties: [String],
        with rows: [TaxonomyPropertySample]
    ) -> [TaxonomyPropertySample] {
        properties.enumerated().compactMap { index, key in
            guard index < rows.count else { return nil }
            let row = rows[index]
            return TaxonomyPropertySample(
                property: key,
                sampleCount: row.sampleCount,
                sampleValues: row.sampleValues
            )
        }
    }
}

// MARK: - Property scope

/// Which table a property definition belongs to.
///
/// `/property_definitions/` lists one table at a time and defaults to events.
/// The distinction is not cosmetic: an event property can be counted over the
/// `events` table and given a real distribution, and a person or group property
/// cannot — it lives on the actor row, where "how often" has no meaning, only
/// "how many actors". A screen that showed both the same way would be claiming
/// a frequency the second has never had.
public enum PropertyScope: Sendable, Hashable {
    case event
    case person
    /// Group properties are per type, so the index travels with the scope.
    case group(index: Int)
    case session

    /// The `type` query parameter. `group_type_index` rides alongside it and is
    /// added by the endpoint builder, because it is a second parameter rather
    /// than part of this one.
    public var parameterValue: String {
        switch self {
        case .event: "event"
        case .person: "person"
        case .group: "group"
        case .session: "session"
        }
    }

    /// Whether the events table can answer "what values does this take, and how
    /// often", which is the only place a distribution is defined.
    public var hasEventDistribution: Bool {
        if case .event = self { return true }
        return false
    }
}

// MARK: - Property distribution

/// One value of a property and how much of the property's traffic it is.
///
/// `share` divides by a total taken from the same response — a window function
/// evaluated across every group before the `LIMIT`, not the sum of the rows on
/// screen. Dividing by the visible rows would make the top ten of four hundred
/// values add up to 100%, which is the specific wrong number this type exists
/// to avoid.
public struct PropertyValueShare: Sendable, Identifiable, Hashable {
    /// `nil` where the property was present but held JSON null. Kept distinct
    /// from the string `"null"`, which is a value somebody actually sent.
    public let value: String?
    public let occurrences: Int
    /// Every matching event in the window, across all values.
    public let totalOccurrences: Int
    /// Every distinct value in the window, not only the ones returned.
    public let distinctValues: Int

    public var id: String { value ?? "\u{0}null" }

    public init?(row: QueryRow) {
        guard let occurrences = row.int("occurrences") else { return nil }
        self.value = row.string("value")
        self.occurrences = occurrences
        self.totalOccurrences = row.int("total_occurrences") ?? occurrences
        self.distinctValues = row.int("distinct_values") ?? 0
    }

    /// `nil` rather than zero when there is no total to divide by, so a caller
    /// draws nothing instead of drawing a 0% bar for an unknown share.
    public var share: Double? {
        guard totalOccurrences > 0 else { return nil }
        return Double(occurrences) / Double(totalOccurrences)
    }

    /// How many values the response did not carry. Zero when it carried them all.
    public static func hiddenValueCount(_ rows: [PropertyValueShare]) -> Int {
        guard let first = rows.first else { return 0 }
        return max(0, first.distinctValues - rows.count)
    }
}

/// One event that carries a property, with how varied the property is on it.
public struct PropertyCarrierEvent: Sendable, Identifiable, Hashable {
    public let event: String
    public let occurrences: Int
    /// Distinct values of the property **on this event**, which is routinely
    /// smaller than the project-wide figure and is the interesting number.
    public let distinctValues: Int
    public let totalOccurrences: Int
    public let distinctEvents: Int

    public var id: String { event }

    public init?(row: QueryRow) {
        guard let event = row.string("event"), let occurrences = row.int("occurrences")
        else { return nil }
        self.event = event
        self.occurrences = occurrences
        self.distinctValues = row.int("distinct_values") ?? 0
        self.totalOccurrences = row.int("total_occurrences") ?? occurrences
        self.distinctEvents = row.int("distinct_events") ?? 0
    }

    public var share: Double? {
        guard totalOccurrences > 0 else { return nil }
        return Double(occurrences) / Double(totalOccurrences)
    }

    public static func hiddenEventCount(_ rows: [PropertyCarrierEvent]) -> Int {
        guard let first = rows.first else { return 0 }
        return max(0, first.distinctEvents - rows.count)
    }
}

// MARK: - Definitions

/// An entry in the project's event taxonomy, with whatever a human curated.
public struct EventDefinitionSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let tags: [String]
    public let lastSeenAt: Date?
    public let isVerified: Bool
    public let isHidden: Bool
    public let isAction: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, tags, verified, hidden
        case lastSeenAt = "last_seen_at"
        case isAction = "is_action"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description).flatMap {
            $0.isEmpty ? nil : $0
        }
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        lastSeenAt = try c.decodeIfPresent(String.self, forKey: .lastSeenAt).flatMap(PostHogDate.parse)
        // `verified` and `hidden` only exist on the enterprise serializer; a
        // self-hosted open-source instance omits them entirely.
        isVerified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        isAction = try c.decodeIfPresent(Bool.self, forKey: .isAction) ?? false
    }
}

/// An entry in the project's property taxonomy.
public struct PropertyDefinitionSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    /// Null for properties PostHog has not typed yet. Substituting "Unknown"
    /// would be a claim the API never made.
    public let propertyType: String?
    public let isNumerical: Bool
    public let isVerified: Bool
    public let isHidden: Bool
    public let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, description, tags, verified, hidden
        case propertyType = "property_type"
        case isNumerical = "is_numerical"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description).flatMap {
            $0.isEmpty ? nil : $0
        }
        propertyType = try c.decodeIfPresent(String.self, forKey: .propertyType).flatMap {
            $0.isEmpty ? nil : $0
        }
        isNumerical = try c.decodeIfPresent(Bool.self, forKey: .isNumerical) ?? false
        isVerified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
    }
}

// MARK: - Merged view

/// An event as the taxonomy screen shows it: volume joined to curation state.
public struct TaxonomyEvent: Sendable, Identifiable, Hashable {
    public enum Status: Sendable, Hashable {
        /// Received in the last 30 days.
        case active
        /// Known to this project, but not received in the last 30 days.
        case quiet
        /// A name PostHog padded the response with that this project has never
        /// sent. Only ever assigned when the definitions actually loaded.
        case neverSent

        fileprivate var rank: Int {
            switch self {
            case .active: 0
            case .quiet: 1
            case .neverSent: 2
            }
        }
    }

    public let name: String
    /// 30-day volume, or `nil` when the event was absent from the taxonomy
    /// response entirely. `nil` and `0` are different facts and stay different.
    public let recentCount: Int?
    public let definition: EventDefinitionSummary?
    public let status: Status

    public var id: String { name }

    public var isVerified: Bool { definition?.isVerified ?? false }
    public var isHidden: Bool { definition?.isHidden ?? false }
    public var description: String? { definition?.description }
    public var lastSeenAt: Date? { definition?.lastSeenAt }
    public var tags: [String] { definition?.tags ?? [] }
    public var isDefined: Bool { definition != nil }

    /// Joins the 30-day volumes to the taxonomy definitions.
    ///
    /// An empty `definitions` is read as "the definitions did not load", not as
    /// "this project defines nothing": without them there is no evidence that an
    /// event was never sent, so nothing may be labelled that way.
    public static func merge(
        volumes: [TaxonomyEventVolume],
        definitions: [EventDefinitionSummary]
    ) -> [TaxonomyEvent] {
        let byName = Dictionary(definitions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let haveDefinitions = !definitions.isEmpty

        var merged: [TaxonomyEvent] = volumes.map { volume in
            let definition = byName[volume.event]
            let status: Status = if volume.wasSeen {
                .active
            } else if haveDefinitions && definition == nil {
                .neverSent
            } else {
                .quiet
            }
            return TaxonomyEvent(
                name: volume.event,
                recentCount: volume.count,
                definition: definition,
                status: status
            )
        }

        // A defined event with no volume row was sent before the 30-day window
        // and has stopped. That is precisely what someone auditing a taxonomy is
        // looking for, so it must not be dropped.
        let seen = Set(volumes.map(\.event))
        merged += definitions
            .filter { !seen.contains($0.name) }
            .map { TaxonomyEvent(name: $0.name, recentCount: nil, definition: $0, status: .quiet) }

        // Volume first within each status, so the loudest event in the project is
        // the first thing on screen; ties fall back to the name so the order is
        // stable across refreshes.
        return merged.sorted { a, b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            let countA = a.recentCount ?? 0
            let countB = b.recentCount ?? 0
            if countA != countB { return countA > countB }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
