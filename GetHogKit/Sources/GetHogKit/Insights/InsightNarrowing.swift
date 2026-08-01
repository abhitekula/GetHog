import Foundation

// Narrowing a saved insight without editing it: one property filter, and one
// breakdown.
//
// The two things an analyst asks next after "signups dropped" — *for whom*, and
// *split by what* — and neither had an answer on the phone before this. Both are
// written into the query node `InsightRerun` already re-posts to `/query/`, so
// they cost exactly what the date rerun costs: **one `.query` request per
// change, behind an explicit Apply.** The control is deliberately explicit so
// users decide when a rerun is requested.
//
// ## The payload shape, and the trap that is *not* the one you expect
//
// `PropertyGroupFilter` is nested —
// `{"type":"AND","values":[{"type":"AND","values":[…filters…]}]}` — and records
// that the flat form parses far enough to look right and then 400s the moment it
// carries data. That correction is about **`TraceSpansQuery.filterGroup`**, which
// is *typed* `PropertyGroupFilter`. It is not about this field, and reaching for
// it here would repeat the same mistake in the opposite direction: copying one
// call site's shape onto a differently-typed field.
//
// `properties` on an insight query node is a **union**, and the array arm is a
// documented representation:
//
// * PostHog's own schema — `InsightsQueryBase.properties?: AnyPropertyFilter[] |
//   PropertyGroupFilter` in `frontend/src/queries/schema/schema-general.ts` on
//   master. A bare array is one of the two declared arms, where on
//   `filterGroup` it is not an arm at all.
//
// This file writes the array form for these nodes.
//
// ## Which node can carry what
//
// Read out of the same schema file, from the `extends` clauses rather than from
// prose, because that is the list that cannot drift from the types:
//
// * `properties` comes from `InsightsQueryBase`, which `TrendsQuery`,
//   `FunnelsQuery`, `RetentionQuery`, `PathsQuery`, `LifecycleQuery` and
//   `CalendarHeatmapQuery` extend. `HogQLQuery` does not — it is a `DataNode`
//   with SQL in it, and there is no property list to add one to.
// * `breakdownFilter` is declared on `TrendsQuery`, `FunnelsQuery` and
//   `RetentionQuery` only. Stickiness, lifecycle and paths have no such key.
//
// A key a node cannot carry is **not written**, and the caller is told so before
// it offers a control. Pydantic answers `Extra inputs are not permitted` for an
// unknown key on these nodes, so writing one anyway would spend a request to
// produce a 400 the user cannot act on.

/// One equality narrowing applied to a re-run insight.
///
/// Deliberately smaller than PostHog's filter vocabulary. `AnyPropertyFilter`
/// spans eleven operators across seven property types, and a phone cannot offer
/// that without becoming the query editor this app has repeatedly declined to
/// be. What it does offer is the pair that answers "for whom": *is* and *is
/// not*, over a value the taxonomy has actually seen.
public struct InsightPropertyFilter: Sendable, Hashable, Codable, Identifiable {

    /// Which table the property lives on — PostHog's `PropertyFilterType`, cut
    /// to the three this app can offer a value list for.
    ///
    /// `cohort`, `element`, `hogql`, `feature` and `group` are all real arms of
    /// the union and none of them is offered: a cohort filter takes an id rather
    /// than a value, an element filter takes a CSS selector, and a HogQL filter
    /// takes an expression. Offering a picker that cannot fill any of them in is
    /// worse than not offering it.
    public enum Scope: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        case event
        case person
        case session

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .event: "Event"
            case .person: "Person"
            case .session: "Session"
            }
        }
    }

    public let scope: Scope
    public let key: String
    public let value: String
    /// `true` writes `is_not` instead of `exact`.
    public let isNegated: Bool

    public init(scope: Scope, key: String, value: String, isNegated: Bool = false) {
        self.scope = scope
        self.key = key
        self.value = value
        self.isNegated = isNegated
    }

    /// Scope participates in identity: `$browser` as an event property and as a
    /// person property are different narrowings and must both be removable.
    public var id: String { "\(scope.rawValue)\u{1F}\(key)\u{1F}\(value)\u{1F}\(isNegated)" }

    public var displayText: String {
        "\(key) \(isNegated ? "is not" : "is") \(value)"
    }

    /// The wire form.
    ///
    /// `value` is an **array of one**, not a bare string. Both are legal —
    /// `PropertyFilterValue` is `PropertyFilterBaseValue | PropertyFilterBaseValue[]
    /// | null` in PostHog's `frontend/src/types.ts` — and the array is what the
    /// console emits for `exact`/`is_not`, so it is the form the server already
    /// stores for filters a human wrote. Matching what is stored is one fewer
    /// difference to explain when somebody diffs the two.
    var jsonValue: JSONValue {
        .object([
            "key": .string(key),
            "type": .string(scope.rawValue),
            "operator": .string(isNegated ? "is_not" : "exact"),
            "value": .array([.string(value)]),
        ])
    }
}

/// One breakdown applied to a re-run insight.
public struct InsightBreakdown: Sendable, Hashable, Codable {

    /// PostHog's `MultipleBreakdownType`, cut to the three the app can name a
    /// property for. The full union also carries `event_metadata`, `group`,
    /// `hogql`, `cohort`, `revenue_analytics`, `data_warehouse` and
    /// `data_warehouse_person_property`.
    public enum Scope: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        case event
        case person
        case session

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .event: "Event"
            case .person: "Person"
            case .session: "Session"
            }
        }
    }

    public let scope: Scope
    public let property: String

    public init(scope: Scope, property: String) {
        self.scope = scope
        self.property = property
    }

    /// The wire form used by saved insight breakdowns:
    ///
    ///     "breakdownFilter": {
    ///       "breakdowns": [{"type": "event", "property": "method"}],
    ///       "breakdown_type": "event"
    ///     }
    ///
    /// Both keys, not one. `breakdowns[]` is the current form and
    /// `breakdown_type` the legacy scalar that PostHog still writes beside it;
    /// this reproduces the compatibility pair rather than dropping either key.
    var jsonValue: JSONValue {
        .object([
            "breakdowns": .array([
                .object(["type": .string(scope.rawValue), "property": .string(property)])
            ]),
            "breakdown_type": .string(scope.rawValue),
        ])
    }
}

/// What to do with the insight's **own** saved breakdown.
///
/// Three states rather than an `InsightBreakdown?`, because "leave the saved one
/// alone" and "explicitly show no breakdown" are different requests and the
/// screen has to be able to make both. Collapsing them would mean a reader who
/// opened the sheet and changed only the date silently lost the breakdown the
/// insight was designed around.
public enum InsightBreakdownOverride: Sendable, Hashable {
    /// Do not touch `breakdownFilter`. The saved insight draws as it was saved.
    case saved
    /// Remove `breakdownFilter` — one undivided series.
    case none
    /// Replace `breakdownFilter` with this one.
    case property(InsightBreakdown)

    public var breakdown: InsightBreakdown? {
        if case .property(let value) = self { return value }
        return nil
    }
}

/// Which narrowings a given insight kind can actually carry.
///
/// A type rather than two loose functions so the caller cannot ask one question
/// and forget the other — the failure that produces is a breakdown menu on a
/// HogQL insight, which spends a `.query` request to be told
/// `Extra inputs are not permitted`.
public struct InsightNarrowing: Sendable, Hashable {

    /// Node kinds inheriting `InsightsQueryBase`, which is where `properties`
    /// comes from.
    ///
    /// Six of the seven are a plain `extends InsightsQueryBase`. The seventh,
    /// `StickinessQuery`, is `extends Omit<InsightsQueryBase<…>,
    /// 'aggregation_group_type_index'>` — it drops the group-aggregation key and
    /// keeps `properties`, so it belongs here even though a search for the plain
    /// clause does not find it. Written down because the obvious re-derivation
    /// of this list would silently lose it.
    static let filterableKinds: Set<String> = [
        "TrendsQuery",
        "FunnelsQuery",
        "RetentionQuery",
        "PathsQuery",
        "LifecycleQuery",
        "CalendarHeatmapQuery",
        "StickinessQuery",
    ]

    /// Node kinds declaring `breakdownFilter`. A strict subset of the above.
    static let breakdownableKinds: Set<String> = [
        "TrendsQuery",
        "FunnelsQuery",
        "RetentionQuery",
    ]

    public let sourceKind: String

    public init(sourceKind: String) {
        self.sourceKind = sourceKind
    }

    public var supportsPropertyFilters: Bool {
        Self.filterableKinds.contains(sourceKind)
    }

    public var supportsBreakdown: Bool {
        Self.breakdownableKinds.contains(sourceKind)
    }

    /// Whether *any* narrowing control should be drawn at all.
    public var isNarrowable: Bool { supportsPropertyFilters || supportsBreakdown }

    /// Why the controls are absent, in the words of the thing that made them
    /// absent — so a HogQL insight does not simply look like a screen missing a
    /// button.
    ///
    /// `nil` when there is nothing to explain.
    public var unavailableReason: String? {
        guard !isNarrowable else { return nil }
        if sourceKind == "HogQLQuery" {
            return "A SQL insight has no property list to narrow — the filtering is in the query itself. Edit it in PostHog, or run your own in the SQL tab."
        }
        return "PostHog's \(sourceKind) node carries no property filters, so there is nothing here to narrow."
    }
}

public extension InsightRerun {

    /// Returns `source` with the date range replaced **and** the narrowings
    /// applied, everything else untouched.
    ///
    /// The long form of `source(_:dateFrom:compare:)`, which stays as the
    /// two-key call every existing caller already makes. Splitting them would
    /// mean two places that both have to remember the `InsightVizNode`
    /// unwrapping and the non-object guard.
    ///
    /// Keys a node cannot carry are **not written** — see this file's header. A
    /// caller that asks for a breakdown on a `LifecycleQuery` gets a request
    /// without one rather than a 400, and `InsightNarrowing` is how it knows not
    /// to offer the control in the first place.
    ///
    /// `filters` replaces the node's `properties` wholesale rather than merging
    /// into it. Merging is the option that looks friendlier and is the one that
    /// cannot be done honestly: the saved value may be either arm of the union,
    /// and appending an array element to a `PropertyGroupFilter` object — or a
    /// group to an array — produces a body that is neither. So an empty
    /// `filters` leaves the saved `properties` exactly as it was, and a non-empty
    /// one states plainly that it is the whole filter list. The screen says which
    /// of the two the reader is looking at.
    static func source(
        _ source: JSONValue,
        dateFrom: String,
        compare: Bool,
        filters: [InsightPropertyFilter],
        breakdown: InsightBreakdownOverride
    ) -> JSONValue {
        guard case .object(var fields) = source else { return source }

        fields = Self.dated(fields, dateFrom: dateFrom, compare: compare)

        let narrowing = InsightNarrowing(sourceKind: fields["kind"]?.stringValue ?? "")

        if narrowing.supportsPropertyFilters, !filters.isEmpty {
            fields["properties"] = .array(filters.map(\.jsonValue))
        }

        if narrowing.supportsBreakdown {
            switch breakdown {
            case .saved:
                break
            case .none:
                fields["breakdownFilter"] = nil
            case .property(let value):
                fields["breakdownFilter"] = value.jsonValue
            }
        }

        return .object(fields)
    }
}
