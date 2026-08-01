import Foundation

/// What a cohort *means*: the tree of conditions PostHog evaluates to decide who
/// is in it.
///
/// **Where the shape comes from.** PostHog's public OpenAPI schema defines it
/// under `CohortFilters`,
/// `CohortFilterGroup`, `PersonFilter`, `PersonMetadataFilter`, `BehavioralFilter`
/// and `CohortFilter`. The deterministic example in
/// `GetHog/Resources/DemoData/cohorts.json` exercises nesting, `AND`/`OR`
/// mixing, `icontains`, `exact`, and an array-valued condition.
///
/// Behavioural conditions, nested-cohort references, static cohorts, and
/// recalculation states are decoded from that schema and tested with fictional
/// payloads. If one of those branches is wrong, the failure it produces is the
/// *renderable* one:
/// `CohortCondition.unrenderable` and `CohortDefinition.unrenderableTypes`, not a
/// confident sentence about the wrong thing.
///
/// **The three ways this can have nothing to say**, which the UI must not blur
/// together, because they mean opposite things to somebody deciding whether to
/// trust a count:
///
/// * **Static.** `is_static` is true and there is no definition to render at all
///   — membership is a list somebody fixed, so "no conditions" is the truth and
///   not a gap.
/// * **Calculating.** `is_calculating`, or `pending_version` ahead of `version`.
///   The definition is renderable; the *count* is mid-flight and any number
///   beside it belongs to the previous evaluation.
/// * **Unrenderable.** A definition exists and this build cannot draw it —
///   `query` is set (an analytical cohort, defined in HogQL rather than in
///   filters), or `filters` is absent while the legacy `groups` array is not, or
///   a condition carries a `type` this build has no case for. Saying "no
///   conditions" there would be a lie about a cohort that has several.
public struct CohortDefinition: Sendable, Hashable {

    /// The outermost group. PostHog always writes one, even for a single
    /// condition, and its combinator is the top-level `OR`/`AND`.
    public let root: CohortFilterGroup

    /// Whether PostHog's own internal/test-user filter is applied on top.
    ///
    /// Optional rather than defaulted false: the served schema declares it
    /// nullable with no default, and "not stated" is not the same claim as
    /// "off". The UI mentions it only when it is actually true.
    public let filtersTestAccounts: Bool?

    public init(root: CohortFilterGroup, filtersTestAccounts: Bool? = nil) {
        self.root = root
        self.filtersTestAccounts = filtersTestAccounts
    }

    /// Every condition `type` string this build had no case for, in encounter
    /// order and de-duplicated.
    ///
    /// The screen names these rather than dropping them. A cohort drawn with
    /// three of its four conditions is a *wrong* definition, and it looks exactly
    /// like a right one.
    public var unrenderableTypes: [String] {
        var seen: [String] = []
        for condition in root.allConditions {
            guard case .unrenderable(let unknown) = condition else { continue }
            if !seen.contains(unknown.type) { seen.append(unknown.type) }
        }
        return seen
    }

    /// True when the tree has no conditions at all.
    public var isEmpty: Bool { root.conditions.isEmpty }

    /// How many leaf conditions the whole tree holds.
    public var conditionCount: Int {
        root.allConditions.reduce(0) { total, condition in
            if case .group = condition { return total }
            return total + 1
        }
    }
}

// MARK: - Groups

/// An `AND`/`OR` group of conditions, which may itself contain groups.
public struct CohortFilterGroup: Sendable, Hashable, Identifiable {

    public enum Combinator: String, Sendable, Hashable {
        case and = "AND"
        case or = "OR"

        /// The word drawn between two conditions.
        ///
        /// Lower case because it sits *inside* a sentence the reader is
        /// assembling — "email contains @example.com **and** signed up after
        /// June" — rather than being a heading.
        public var joiner: String {
            switch self {
            case .and: "and"
            case .or: "or"
            }
        }

        /// How the group reads when it is introduced rather than joined.
        public var headline: String {
            switch self {
            case .and: "Everyone matching all of"
            case .or: "Everyone matching any of"
            }
        }
    }

    /// Stable across a redraw, and derived from the condition's position in the
    /// tree rather than from its contents: two sibling conditions are routinely
    /// identical apart from a value, and PostHog's own `conditionHash` is absent
    /// on the nested groups that also need identity here.
    public let id: String
    public let combinator: Combinator
    public let conditions: [CohortCondition]

    public init(id: String, combinator: Combinator, conditions: [CohortCondition]) {
        self.id = id
        self.combinator = combinator
        self.conditions = conditions
    }

    /// This group's conditions and every descendant's, depth first.
    public var allConditions: [CohortCondition] {
        conditions.flatMap { condition -> [CohortCondition] in
            guard case .group(let nested) = condition else { return [condition] }
            return [condition] + nested.allConditions
        }
    }
}

// MARK: - Conditions

public enum CohortCondition: Sendable, Hashable, Identifiable {
    case group(CohortFilterGroup)
    case property(CohortPropertyCondition)
    case behavioural(CohortBehaviouralCondition)
    case cohortReference(CohortReferenceCondition)
    case unrenderable(CohortUnknownCondition)

    public var id: String {
        switch self {
        case .group(let group): group.id
        case .property(let condition): condition.id
        case .behavioural(let condition): condition.id
        case .cohortReference(let condition): condition.id
        case .unrenderable(let condition): condition.id
        }
    }
}

/// A condition on something PostHog already knows about the person.
public struct CohortPropertyCondition: Sendable, Hashable, Identifiable {

    /// Which half of the persons table the key names.
    ///
    /// `person` reads the properties JSON; `person_metadata` reads a column on
    /// the table itself — `created_at` and friends. The distinction is not
    /// cosmetic: a property named `created_at` and the *column* `created_at` are
    /// different things and can disagree, so the screen says which one a
    /// condition means.
    public enum Scope: Sendable, Hashable {
        case property
        case column

        public var noun: String {
            switch self {
            case .property: "Person property"
            case .column: "Person record"
            }
        }
    }

    public let id: String
    public let scope: Scope
    public let key: String
    /// PostHog's raw operator string, kept so an operator this build predates is
    /// still shown rather than silently rendered as "is".
    public let rawOperator: String?
    public let value: JSONValue?
    public let negated: Bool

    public init(
        id: String,
        scope: Scope,
        key: String,
        rawOperator: String?,
        value: JSONValue?,
        negated: Bool
    ) {
        self.id = id
        self.scope = scope
        self.key = key
        self.rawOperator = rawOperator
        self.value = value
        self.negated = negated
    }

    /// The verb phrase between the key and the value.
    ///
    /// **A list changes the verb.** PostHog writes `exact` with an array when a
    /// condition accepts several values, and it means membership — so
    /// `plan exact ["pro", "premium"]` is "plan **is one of** pro, premium", not
    /// "plan **is** pro, premium", which is what it read as on screen before
    /// this branch existed and is a different (and impossible) claim. A
    /// one-element array is the single-value case PostHog also writes that way,
    /// and keeps "is".
    public var comparison: String {
        let base: String
        if isMultiValued, rawOperator == "exact" || rawOperator == nil {
            base = "is one of"
        } else if isMultiValued, rawOperator == "is_not" {
            base = "is none of"
        } else {
            base = CohortOperatorPhrase.phrase(for: rawOperator)
        }
        return negated ? "does not match (\(base))" : base
    }

    private var isMultiValued: Bool {
        guard case .array(let items)? = value else { return false }
        return items.count > 1
    }

    /// Whether the operator is one that carries no right-hand side.
    public var takesValue: Bool {
        switch rawOperator {
        case "is_set", "is_not_set": false
        default: true
        }
    }

    public var valueText: String? {
        guard takesValue else { return nil }
        return CohortValueText.render(value)
    }

    /// One line, for VoiceOver and for anything that needs the condition as
    /// prose rather than as layout.
    public var summary: String {
        var parts = ["\(scope.noun) \(key) \(comparison)"]
        if let valueText { parts.append(valueText) }
        return parts.joined(separator: " ")
    }
}

/// A condition on what the person has *done*.
///
/// Decoded and phrased from PostHog's public `BehavioralFilter` schema. Unknown
/// cases remain renderable as unsupported data instead of being mislabelled.
public struct CohortBehaviouralCondition: Sendable, Hashable, Identifiable {

    public let id: String
    /// PostHog's `value` — the *kind* of behavioural test, e.g.
    /// `performed_event`. Kept raw for the same reason `rawOperator` is.
    public let kind: String
    /// The event or action. `key` is an integer for `event_type: "actions"`,
    /// which is why it is rendered rather than typed.
    public let event: String
    /// `events`, `actions` or `data_warehouse`.
    public let eventType: String?
    public let timeValue: Int?
    public let timeInterval: String?
    /// PostHog's newer relative-date spelling, e.g. `-30d`, which supersedes the
    /// `time_value`/`time_interval` pair when present.
    public let explicitDatetime: String?
    public let rawOperator: String?
    public let operatorValue: Int?
    public let sequenceEvent: String?
    public let sequenceTimeValue: Int?
    public let sequenceTimeInterval: String?
    public let totalPeriods: Int?
    public let minimumPeriods: Int?
    public let negated: Bool

    public init(
        id: String,
        kind: String,
        event: String,
        eventType: String?,
        timeValue: Int?,
        timeInterval: String?,
        explicitDatetime: String?,
        rawOperator: String?,
        operatorValue: Int?,
        sequenceEvent: String?,
        sequenceTimeValue: Int?,
        sequenceTimeInterval: String?,
        totalPeriods: Int?,
        minimumPeriods: Int?,
        negated: Bool
    ) {
        self.id = id
        self.kind = kind
        self.event = event
        self.eventType = eventType
        self.timeValue = timeValue
        self.timeInterval = timeInterval
        self.explicitDatetime = explicitDatetime
        self.rawOperator = rawOperator
        self.operatorValue = operatorValue
        self.sequenceEvent = sequenceEvent
        self.sequenceTimeValue = sequenceTimeValue
        self.sequenceTimeInterval = sequenceTimeInterval
        self.totalPeriods = totalPeriods
        self.minimumPeriods = minimumPeriods
        self.negated = negated
    }

    /// The window, as words, or `nil` when the condition names none.
    ///
    /// `explicit_datetime` wins when both are present: PostHog writes it on
    /// newly-saved conditions and leaves the older pair beside it, and the two
    /// can disagree.
    public var window: String? {
        if let explicitDatetime, !explicitDatetime.isEmpty {
            return Self.relativeWindow(explicitDatetime) ?? "since \(explicitDatetime)"
        }
        guard let timeValue, let timeInterval else { return nil }
        return "in the last \(Self.count(timeValue, of: timeInterval))"
    }

    /// The whole condition as one sentence.
    ///
    /// Every branch ends with the raw `kind` when it is not one this build
    /// knows, rather than falling through to the most common phrasing — a
    /// behavioural test rendered as the wrong behavioural test is the failure
    /// mode with no symptom.
    public var summary: String {
        let subject = negated ? "Has not" : "Has"
        let noun = eventType == "actions" ? "action" : "event"
        let scoped = "\(noun) \(event)"

        switch kind {
        case "performed_event":
            return join(subject, "performed", scoped, window)
        case "performed_event_multiple":
            // `countPhrase`, not `phrase`. The property phrasing reads "is at
            // least", which is right beside a property name and wrong inside a
            // sentence: "has performed event checkout completed **is at least**
            // 5 times". The count-specific phrase keeps the sentence grammatical.
            let times = operatorValue.map {
                "\(CohortOperatorPhrase.countPhrase(for: rawOperator)) \($0) \($0 == 1 ? "time" : "times")"
            }
            return join(subject, "performed", scoped, times, window)
        case "performed_event_first_time":
            return join(subject, "performed", scoped, "for the first time", window)
        case "performed_event_sequence":
            let then = sequenceEvent.map { "then \($0)" }
            let within = sequenceTimeValue.flatMap { value in
                sequenceTimeInterval.map { "within \(Self.count(value, of: $0))" }
            }
            return join(subject, "performed", scoped, then, within, window)
        case "performed_event_regularly":
            let regularity = minimumPeriods.flatMap { minimum in
                totalPeriods.map { total in
                    "in at least \(minimum) of the last \(total) \(total == 1 ? "period" : "periods")"
                }
            }
            return join(subject, "performed", scoped, regularity, window)
        case "stopped_performing_event":
            return join("Stopped performing", scoped, window)
        case "restarted_performing_event":
            return join("Restarted performing", scoped, window)
        default:
            // Named, not guessed. The reader learns there is a condition here
            // and what PostHog calls it, which is enough to go and look.
            return join("Behaviour “\(kind)” on", scoped, window)
        }
    }

    private func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func count(_ value: Int, of interval: String) -> String {
        let unit = interval.hasSuffix("s") ? String(interval.dropLast()) : interval
        return "\(value) \(value == 1 ? unit : unit + "s")"
    }

    /// Turns `-30d` into "in the last 30 days", and returns `nil` for anything
    /// that is not that shape rather than mangling it.
    private static func relativeWindow(_ token: String) -> String? {
        guard token.hasPrefix("-"), let unit = token.last else { return nil }
        let digits = token.dropFirst().dropLast()
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        let name: String
        switch unit {
        case "h": name = "hour"
        case "d": name = "day"
        case "w": name = "week"
        case "m": name = "month"
        case "y": name = "year"
        default: return nil
        }
        return "in the last \(value) \(value == 1 ? name : name + "s")"
    }
}

/// A condition that says "and also in this other cohort".
public struct CohortReferenceCondition: Sendable, Hashable, Identifiable {
    public let id: String
    public let cohortID: Int
    /// Resolved from the cohorts already on screen where possible. PostHog does
    /// not send a name here, and an id on its own is not a definition.
    public let name: String?
    public let negated: Bool

    public init(id: String, cohortID: Int, name: String?, negated: Bool) {
        self.id = id
        self.cohortID = cohortID
        self.name = name
        self.negated = negated
    }

    public var summary: String {
        let verb = negated ? "Is not in cohort" : "Is in cohort"
        return "\(verb) \(name ?? "#\(cohortID)")"
    }
}

/// A condition this build has no case for.
public struct CohortUnknownCondition: Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String

    public init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    public var summary: String {
        "A “\(type)” condition, which this version of GetHog cannot describe"
    }
}

// MARK: - Decoding

public extension CohortDefinition {

    /// Builds a definition from a cohort's raw `filters` object.
    ///
    /// **Walked as `JSONValue` rather than decoded through `Codable`.** The
    /// group's `values` array is heterogeneous — five member types discriminated
    /// by a `type` string that is *also* the discriminator for "this is a nested
    /// group" — and expressing that as `init(from:)` means a chain of
    /// `try?`-decodes whose ordering silently decides which type wins. Walking it
    /// makes the discrimination one readable `switch`, and makes the
    /// unrecognised case a *value* (`.unrenderable`) instead of a thrown error
    /// that would discard the whole definition over one condition.
    ///
    /// Returns `nil` when there is no filter tree at all, which the caller must
    /// distinguish from an empty one — see `Cohort.definitionState`.
    static func make(from filters: JSONValue?) -> CohortDefinition? {
        guard let filters, case .object(let object) = filters else { return nil }
        guard let properties = object["properties"] else { return nil }
        guard let root = group(from: properties, path: "0") else { return nil }
        return CohortDefinition(
            root: root,
            filtersTestAccounts: boolean(object["filterTestAccounts"])
        )
    }

    /// Fills in the names of referenced cohorts from cohorts already fetched.
    ///
    /// PostHog sends only an id on a nested-cohort condition, and "is in cohort
    /// #4102" is not a definition. The names come from the list the People screen
    /// already holds, so resolving them costs no request — which matters, because
    /// the alternative is one `GET /cohorts/:id/` per reference and the
    /// rate-limit budget is the whole organisation's.
    func resolvingCohortNames(_ names: [Int: String]) -> CohortDefinition {
        CohortDefinition(
            root: CohortDefinition.resolve(root, names: names),
            filtersTestAccounts: filtersTestAccounts
        )
    }

    private static func resolve(
        _ group: CohortFilterGroup, names: [Int: String]
    ) -> CohortFilterGroup {
        CohortFilterGroup(
            id: group.id,
            combinator: group.combinator,
            conditions: group.conditions.map { condition in
                switch condition {
                case .group(let nested):
                    return .group(resolve(nested, names: names))
                case .cohortReference(let reference) where reference.name == nil:
                    return .cohortReference(
                        CohortReferenceCondition(
                            id: reference.id,
                            cohortID: reference.cohortID,
                            name: names[reference.cohortID],
                            negated: reference.negated
                        )
                    )
                default:
                    return condition
                }
            }
        )
    }

    private static func group(from value: JSONValue, path: String) -> CohortFilterGroup? {
        guard case .object(let object) = value else { return nil }
        let raw = (object["type"]?.stringValue ?? "AND").uppercased()
        let combinator = CohortFilterGroup.Combinator(rawValue: raw) ?? .and
        guard case .array(let values)? = object["values"] else {
            return CohortFilterGroup(id: path, combinator: combinator, conditions: [])
        }
        let conditions = values.enumerated().compactMap { index, element in
            condition(from: element, path: "\(path).\(index)")
        }
        return CohortFilterGroup(id: path, combinator: combinator, conditions: conditions)
    }

    private static func condition(from value: JSONValue, path: String) -> CohortCondition? {
        guard case .object(let object) = value else { return nil }
        let type = object["type"]?.stringValue ?? ""

        // A group is discriminated by its `type`, which is the same field the
        // leaves use — that is how the served schema's `discriminator.mapping`
        // does it, with `AND` and `OR` mapping to the group.
        if type.uppercased() == "AND" || type.uppercased() == "OR" {
            return group(from: value, path: path).map(CohortCondition.group)
        }

        let negated = boolean(object["negation"]) ?? false

        switch type {
        case "person", "person_metadata":
            return .property(
                CohortPropertyCondition(
                    id: path,
                    scope: type == "person" ? .property : .column,
                    key: object["key"]?.stringValue ?? "(unnamed)",
                    rawOperator: object["operator"]?.stringValue,
                    value: object["value"],
                    negated: negated
                )
            )

        case "behavioral":
            return .behavioural(
                CohortBehaviouralCondition(
                    id: path,
                    kind: object["value"]?.stringValue ?? "",
                    // `key` is an integer when `event_type` is `actions`, so it
                    // is rendered rather than required to be a string.
                    event: object["key"]?.stringValue ?? "(unnamed)",
                    eventType: object["event_type"]?.stringValue,
                    timeValue: integer(object["time_value"]),
                    timeInterval: object["time_interval"]?.stringValue,
                    explicitDatetime: object["explicit_datetime"]?.stringValue,
                    rawOperator: object["operator"]?.stringValue,
                    operatorValue: integer(object["operator_value"]),
                    sequenceEvent: object["seq_event"]?.stringValue,
                    sequenceTimeValue: integer(object["seq_time_value"]),
                    sequenceTimeInterval: object["seq_time_interval"]?.stringValue,
                    totalPeriods: integer(object["total_periods"]),
                    minimumPeriods: integer(object["min_periods"]),
                    negated: negated
                )
            )

        // Three spellings for the same idea. `static-cohort` and
        // `precalculated-cohort` are what PostHog rewrites `cohort` to once it
        // has decided how to evaluate the reference; all three mean "and also in
        // that cohort", and telling a reader which optimisation was chosen would
        // be noise.
        case "cohort", "static-cohort", "precalculated-cohort":
            guard let id = integer(object["value"]) else {
                return .unrenderable(CohortUnknownCondition(id: path, type: type))
            }
            return .cohortReference(
                CohortReferenceCondition(id: path, cohortID: id, name: nil, negated: negated)
            )

        default:
            // `event`, `element`, `session`, `hogql`, `group`,
            // `data_warehouse`… — types PostHog permits elsewhere and may start
            // writing here. Named, never dropped.
            return .unrenderable(
                CohortUnknownCondition(id: path, type: type.isEmpty ? "untyped" : type)
            )
        }
    }

    /// `JSONValue` has no boolean accessor, and `stringValue` renders `true` as
    /// the *string* "true" — which would make `filterTestAccounts: false` truthy.
    private static func boolean(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    /// `JSONValue.intValue` is `Int(Double)`, which traps on a non-finite or
    /// out-of-range number. Nothing in a cohort filter should be either, and
    /// "should" is not a reason to leave a trap on a path fed by the network.
    private static func integer(_ value: JSONValue?) -> Int? {
        guard let double = value?.doubleValue, double.isFinite,
              double >= Double(Int.min), double <= Double(Int.max)
        else { return nil }
        return Int(double)
    }
}

// MARK: - Phrasing

enum CohortOperatorPhrase {

    /// Every operator `PropertyOperator` declares in the served schema, read on
    /// 30 Jul 2026, plus a fallback that shows the raw token.
    ///
    /// The fallback matters more than the table: PostHog adds operators, and a
    /// new one rendered as "is" would produce a confident, wrong sentence about
    /// somebody's cohort. Showing `semver_tilde` untranslated is ugly and true.
    static func phrase(for token: String?) -> String {
        guard let token, !token.isEmpty else { return "is" }
        switch token {
        case "exact": return "is"
        case "is_not": return "is not"
        case "icontains": return "contains"
        case "not_icontains": return "does not contain"
        case "icontains_multi": return "contains any of"
        case "not_icontains_multi": return "contains none of"
        case "starts_with": return "starts with"
        case "not_starts_with": return "does not start with"
        case "ends_with": return "ends with"
        case "not_ends_with": return "does not end with"
        case "regex": return "matches the pattern"
        case "not_regex": return "does not match the pattern"
        case "gt": return "is greater than"
        case "gte": return "is at least"
        case "lt": return "is less than"
        case "lte": return "is at most"
        case "min": return "is the minimum"
        case "max": return "is the maximum"
        case "is_set": return "is set"
        case "is_not_set": return "is not set"
        case "is_date_exact": return "is on"
        case "is_date_before": return "is before"
        case "is_date_after": return "is after"
        case "between": return "is between"
        case "not_between": return "is not between"
        case "in": return "is one of"
        case "not_in": return "is none of"
        case "is_cleaned_path_exact": return "is the cleaned path"
        case "flag_evaluates_to": return "evaluates to"
        default:
            // `semver_*` and anything newer. Shown as PostHog spells it, with
            // the underscores opened up so it reads as words rather than as an
            // identifier that leaked.
            return token.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The same operators, phrased to sit in front of a **count** rather than
    /// beside a property name.
    ///
    /// A separate table rather than a clever rewrite of the first, because the
    /// two genuinely differ: `gte` is "is at least" against a property and "at
    /// least" against a number of times, and `exact` is "is" against a property
    /// and "exactly" against a count.
    static func countPhrase(for token: String?) -> String {
        switch token {
        case "gte": "at least"
        case "gt": "more than"
        case "lte": "at most"
        case "lt": "fewer than"
        case "exact": "exactly"
        case "is_not": "any number of times other than"
        default: phrase(for: token)
        }
    }
}

enum CohortValueText {

    /// A condition's right-hand side as text.
    ///
    /// Arrays are the common case rather than the exception — the observed
    /// cohort's `$internal_or_test_user` condition carries `[true]` for a
    /// single-valued `exact` — so a one-element array renders as its element
    /// and nothing announces a list that is not one.
    static func render(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .array(let items):
            let rendered = items.compactMap { render($0) }
            guard !rendered.isEmpty else { return nil }
            return rendered.count == 1 ? rendered[0] : rendered.joined(separator: ", ")
        case .object:
            // Nothing in the served schema puts an object here. If one arrives,
            // say so rather than printing a Swift dictionary description.
            return "a structured value this build cannot show"
        case .string(let text):
            return text.isEmpty ? "an empty string" : text
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number:
            return value.stringValue
        }
    }
}
