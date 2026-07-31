import Foundation

public struct FeatureFlag: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let key: String
    public let name: String?
    public let active: Bool
    public let archived: Bool
    public let deleted: Bool
    public let filters: FlagFilters?

    /// The **verbatim** `filters` object, kept beside the typed one.
    ///
    /// The same device `Experiment.featureFlagRaw` uses, and for a stronger
    /// reason. `filters` is a Django `JSONField`, so a PATCH replaces the whole
    /// object rather than merging into it — every key the client fails to echo is
    /// destroyed. `FlagFilters` below models a strict subset: it has no
    /// `payloads`, no `early_exit`, no `aggregation_group_type_index`, no
    /// per-group `variant`, and `FlagProperty` drops `group_type_index` and
    /// `cohort_name`. Re-encoding the typed model into a write body would
    /// silently delete a flag's per-variant payloads and its group aggregation.
    ///
    /// The fix is not to add the missing fields. A typed round-trip cannot be
    /// made safe by widening it, only by never dropping a key it does not know
    /// about — which is a property of carrying the bytes, not of the type. So the
    /// write mutates exactly one path in this value and sends it back whole; see
    /// `FlagRollout.filters(_:settingGroup:toPercentage:)`.
    ///
    /// `early_exit: false` and a group-level `aggregation_group_type_index: null`
    /// were both present on flag [REMOVED PRIVATE DATA] when it was read live on 2026-07-31, and
    /// neither exists on `FlagFilters` — so this is not a hypothetical.
    public let filtersRaw: JSONValue?

    /// The row's version, for the serializer's optimistic-concurrency check.
    ///
    /// Read off the **raw request body** server-side (`version =
    /// request_data.get("version", -1)`), not off the serializer, so omitting it
    /// does not fail closed — it skips the check entirely and last write wins,
    /// while the row's version is bumped anyway. `setFlagActive` has always
    /// omitted it, which is defensible for a one-bit toggle; it is not defensible
    /// for a rollout percentage read minutes earlier on a phone, where sending
    /// the version you decoded is the only way to be told you were racing.
    ///
    /// Optional because a payload predating the field, or a fixture without one,
    /// must still decode. A write built from a flag with no version simply omits
    /// it and is back to last-write-wins, which is stated where it is offered.
    public let version: Int?

    enum CodingKeys: String, CodingKey {
        case id, key, name, active, archived, deleted, filters, version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        // `active` is documented as boolean-or-"STALE"; treat anything non-false as on.
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .active) {
            active = b
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .active) {
            active = s.uppercased() != "FALSE"
        } else {
            active = false
        }
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        filters = try? c.decodeIfPresent(FlagFilters.self, forKey: .filters)
        filtersRaw = try? c.decodeIfPresent(JSONValue.self, forKey: .filters)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
    }

    /// The flag's name in full, or its key when it has none.
    ///
    /// Deliberately not shortened. This used to cut at 80 characters with an
    /// ellipsis so the flags list would keep even row heights — a layout
    /// decision taken in a type that cannot see a screen, and one every consumer
    /// inherited whether or not it was laying anything out. The flags row's
    /// `accessibilityLabel` was one of them, so VoiceOver read the `deep-links`
    /// flag as "…copy-link buttons on vendor/guest/gift/member/eve…", and
    /// Spotlight indexed the same stub. Truncation now happens in `FlagRowView`,
    /// where the layout is.
    public var displayName: String {
        guard let name, !name.isEmpty else { return key }
        return name
    }

    /// Highest rollout percentage across release condition groups, if set.
    ///
    /// A **derived summary, not a field**. There is no scalar rollout percentage
    /// on a feature flag: the number lives once per release-condition group, and
    /// a flag with two groups has two of them. This reduction is honest as a
    /// headline figure and is not a value anything may write back — a control
    /// labelled "Rollout %" that PATCHed `max()` into group 0 would be wrong for
    /// every multi-group flag in the project. A write has to name *which* group
    /// it is changing, which is why `FlagRollout` takes an index.
    public var rolloutPercentage: Double? {
        filters?.groups?.compactMap(\.rolloutPercentage).max()
    }

    /// The release-condition groups, which is what a rollout percentage can
    /// actually be set on. Empty when the flag has none.
    public var conditionGroups: [FlagGroup] { filters?.groups ?? [] }

    /// Whether a rollout percentage can be written for this flag at all.
    ///
    /// Two conditions, both structural rather than cautious. The verbatim
    /// `filters` must have survived decoding, because the write is a mutation of
    /// those exact bytes and there is nothing to mutate without them; and the
    /// object must carry a `groups` array, because a `filters` PATCH with no
    /// `groups` key is **silently ignored** — `validate_filters` returns the
    /// instance's existing filters unchanged on a PATCH that omits it, so the
    /// request answers 200 with the flag untouched.
    public var canEditRollout: Bool {
        if case .array? = filtersRaw?["groups"] { return !conditionGroups.isEmpty }
        return false
    }

    public var variants: [FlagVariant] { filters?.multivariate?.variants ?? [] }

    public var isMultivariate: Bool { !variants.isEmpty }

    /// Client-side opt-in. Nothing reaches Control Center or an interactive
    /// widget unless the user deliberately enables it in the app; the server has
    /// no such concept, so this is always false on decode.
    public var allowsQuickToggle: Bool { false }
}

public struct FlagFilters: Sendable, Decodable, Hashable {
    public let groups: [FlagGroup]?
    public let multivariate: FlagMultivariate?
}

public struct FlagGroup: Sendable, Decodable, Hashable {
    public let rolloutPercentage: Double?
    public let properties: [FlagProperty]?

    enum CodingKeys: String, CodingKey {
        case properties
        case rolloutPercentage = "rollout_percentage"
    }
}

public struct FlagProperty: Sendable, Decodable, Hashable {
    public let key: String?
    public let type: String?
    public let `operator`: String?
    public let value: JSONValue?

    public var summary: String {
        let op = (`operator` ?? "equals").replacingOccurrences(of: "_", with: " ")
        let val: String
        switch value {
        case .array(let a): val = a.compactMap(\.stringValue).joined(separator: ", ")
        case .some(let v): val = v.stringValue ?? ""
        case .none: val = ""
        }
        return "\(key ?? "?") \(op) \(val)"
    }
}

public struct FlagMultivariate: Sendable, Decodable, Hashable {
    public let variants: [FlagVariant]
}

public struct FlagVariant: Sendable, Decodable, Hashable, Identifiable {
    public let key: String
    public let name: String?
    public let rolloutPercentage: Double?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, name
        case rolloutPercentage = "rollout_percentage"
    }
}
