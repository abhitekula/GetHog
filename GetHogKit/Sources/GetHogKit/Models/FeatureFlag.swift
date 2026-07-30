import Foundation

public struct FeatureFlag: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let key: String
    public let name: String?
    public let active: Bool
    public let archived: Bool
    public let deleted: Bool
    public let filters: FlagFilters?

    enum CodingKeys: String, CodingKey {
        case id, key, name, active, archived, deleted, filters
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
    public var rolloutPercentage: Double? {
        filters?.groups?.compactMap(\.rolloutPercentage).max()
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
