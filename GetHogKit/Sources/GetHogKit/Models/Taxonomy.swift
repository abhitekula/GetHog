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
        property = try c.decode(String.self, forKey: .property)
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        // Values arrive as strings, but a numeric property has come back as a
        // JSON number, which would fail a `[String]` decode and drop the row.
        let rawValues = (try? c.decodeIfPresent([JSONValue].self, forKey: .sampleValues)) ?? nil
        sampleValues = rawValues?.compactMap(\.stringValue) ?? []
    }

    public var sampleSummary: String {
        "\(sampleCount) distinct value\(sampleCount == 1 ? "" : "s") in sample"
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
