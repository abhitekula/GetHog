import Foundation

public struct PersonSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let distinctIDs: [String]
    public let isIdentified: Bool
    public let createdAt: Date?
    public let properties: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, name, properties
        case distinctIDs = "distinct_ids"
        case isIdentified = "is_identified"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is a UUID string on this endpoint but an integer elsewhere.
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            id = String(n)
        } else {
            id = UUID().uuidString
        }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        distinctIDs = (try? c.decodeIfPresent([String].self, forKey: .distinctIDs)) ?? []
        isIdentified = try c.decodeIfPresent(Bool.self, forKey: .isIdentified) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        properties = try? c.decodeIfPresent(JSONValue.self, forKey: .properties)
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return distinctIDs.first ?? "Anonymous"
    }

    public var initials: String {
        let letters = displayName.prefix(while: { $0 != "@" })
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

public struct Cohort: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let count: Int?
    public let isStatic: Bool
    public let cohortType: String?
    public let deleted: Bool

    /// The filter tree, when there is one this build can read.
    ///
    /// **It arrives on the list response.** `GET /cohorts/` returns every
    /// cohort's whole `filters` object, not a summary — verified against the live
    /// project on 30 Jul 2026 — so showing a cohort's definition costs no request
    /// beyond the list the screen already fetches. That is not a small detail
    /// here: the rate-limit budget is organisation-wide, and the obvious design,
    /// one `GET /cohorts/:id/` per cohort opened, would have spent one request
    /// per tap for data already in hand.
    public let definition: CohortDefinition?

    /// PostHog is re-evaluating membership right now, so `count` is the previous
    /// evaluation's.
    public let isCalculating: Bool
    /// Saved edits not yet evaluated: `pending_version` ahead of `version` means
    /// the definition on screen is newer than the count beside it.
    public let version: Int?
    public let pendingVersion: Int?
    public let lastCalculation: Date?
    public let errorsCalculating: Int
    public let lastErrorMessage: String?

    /// Set when the cohort is defined in HogQL rather than in filter groups.
    ///
    /// Kept as a presence flag rather than a parsed query: PostHog calls these
    /// "analytical" cohorts, this build has no SQL renderer to point at one, and
    /// pretending the empty filter tree that accompanies it is the definition
    /// would describe the cohort as matching everybody.
    public let isQueryDefined: Bool

    /// The legacy pre-`filters` representation.
    ///
    /// PostHog migrated cohorts from `groups` to `filters` and still echoes
    /// `groups` back — as `[]` on every cohort in the project this was built
    /// against. A cohort old enough to have never been migrated would arrive with
    /// this populated and `filters` absent, and that is a definition this build
    /// cannot render rather than a cohort without one.
    public let hasLegacyGroups: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, count, deleted, filters, query, groups, version
        case isStatic = "is_static"
        case cohortType = "cohort_type"
        case isCalculating = "is_calculating"
        case pendingVersion = "pending_version"
        case lastCalculation = "last_calculation"
        case errorsCalculating = "errors_calculating"
        case lastErrorMessage = "last_error_message"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled cohort"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        isStatic = try c.decodeIfPresent(Bool.self, forKey: .isStatic) ?? false
        cohortType = try c.decodeIfPresent(String.self, forKey: .cohortType)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false

        definition = CohortDefinition.make(
            from: try? c.decodeIfPresent(JSONValue.self, forKey: .filters)
        )
        isCalculating = try c.decodeIfPresent(Bool.self, forKey: .isCalculating) ?? false
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        pendingVersion = try c.decodeIfPresent(Int.self, forKey: .pendingVersion)
        lastCalculation = try c.decodeIfPresent(String.self, forKey: .lastCalculation)
            .flatMap(PostHogDate.parse)
        errorsCalculating = try c.decodeIfPresent(Int.self, forKey: .errorsCalculating) ?? 0
        lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage)

        let query = try? c.decodeIfPresent(JSONValue.self, forKey: .query)
        isQueryDefined = !(query == nil || query == .null)
        let groups = try? c.decodeIfPresent(JSONValue.self, forKey: .groups)
        if case .array(let rows)? = groups {
            hasLegacyGroups = !rows.isEmpty
        } else {
            hasLegacyGroups = false
        }
    }

    /// Whether the count on screen belongs to the definition on screen.
    ///
    /// Two ways it does not, and they are not the same: PostHog is evaluating
    /// right now (`is_calculating`), or somebody saved an edit that has not been
    /// evaluated yet (`pending_version` > `version`). Both mean "the number is
    /// the old definition's", which is the one thing a reader must not conclude
    /// from a number sitting under a set of conditions.
    public var isRecalculating: Bool {
        if isCalculating { return true }
        guard let version, let pendingVersion else { return false }
        return pendingVersion > version
    }

    /// Which of the four things this cohort's definition is.
    public enum DefinitionState: Sendable, Hashable {
        /// Membership is a fixed list; there are no conditions and that is not a
        /// gap.
        case staticMembership
        /// A filter tree this build can draw.
        case filters(CohortDefinition)
        /// A definition exists and this build cannot draw it. The string says
        /// which kind, in words a reader can act on.
        case unrenderable(reason: String)
        /// A dynamic cohort carrying an empty filter tree — which matches
        /// everybody, and is a real thing PostHog lets you save.
        case matchesEveryone
    }

    public var definitionState: DefinitionState {
        // Checked before `isStatic`, because a static cohort built by a feature
        // flag or a scanner *also* carries the query that produced it, and the
        // honest reading there is still "a fixed list".
        if isStatic { return .staticMembership }
        if isQueryDefined {
            return .unrenderable(
                reason: "This cohort is defined by a SQL query rather than by filters."
            )
        }
        guard let definition else {
            return hasLegacyGroups
                ? .unrenderable(
                    reason: "This cohort still uses PostHog's pre-2023 filter format."
                )
                : .matchesEveryone
        }
        if definition.isEmpty { return .matchesEveryone }
        return .filters(definition)
    }
}

public struct Survey: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let type: String
    public let archived: Bool
    public let startDate: Date?
    public let endDate: Date?
    public let questions: [SurveyQuestion]

    enum CodingKeys: String, CodingKey {
        case id, name, description, type, archived, questions
        case startDate = "start_date"
        case endDate = "end_date"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled survey"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "popover"
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate).flatMap(PostHogDate.parse)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate).flatMap(PostHogDate.parse)
        questions = (try? c.decodeIfPresent([SurveyQuestion].self, forKey: .questions)) ?? []
    }

    /// Launched and not yet stopped. A survey with no start date was never run.
    public var isRunning: Bool {
        guard let startDate, startDate <= Date() else { return false }
        if let endDate, endDate <= Date() { return false }
        return !archived
    }

    public var statusText: String {
        if archived { return "Archived" }
        if isRunning { return "Running" }
        return startDate == nil ? "Draft" : "Stopped"
    }

    /// Returns a copy with different lifecycle dates, for optimistic display
    /// while a write is in flight. Nothing here talks to the API.
    ///
    /// The dates and not the status word, because there **is** no status word on
    /// a survey: `GET /surveys/` returns 37 keys and none of them is `status`.
    /// Running is derived from exactly these three fields, so an optimistic
    /// change has to be made where the derivation reads it — otherwise the app
    /// ends up with two definitions of "Running", one derived and one asserted,
    /// and they drift the first time either changes.
    ///
    /// Same shape as `ErrorIssue.withStatus`, and for the same reason: the model
    /// is `Decodable`-only so that "what the server last said" has exactly one
    /// spelling, and a caller that wants to show something else has to say so.
    public func withDates(startDate: Date?, endDate: Date?) -> Survey {
        Survey(copying: self, startDate: startDate, endDate: endDate)
    }

    private init(copying other: Survey, startDate: Date?, endDate: Date?) {
        self.id = other.id
        self.name = other.name
        self.description = other.description
        self.type = other.type
        self.archived = other.archived
        self.questions = other.questions
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct SurveyQuestion: Sendable, Decodable, Hashable {
    public let type: String?
    public let question: String?
    public let choices: [String]?

    /// The per-question UUID PostHog mints when the survey is saved.
    ///
    /// This is the key half of `$survey_response_<id>` on every response event,
    /// so without it a question's answers cannot be found by anything except
    /// its position — which moves the moment a question is inserted. Surveys
    /// created before PostHog started minting these have no id at all, which is
    /// why it is optional and why `SurveyResultsQuery` keeps an index fallback.
    public let id: String?

    /// Number of points on a rating question's scale: 3, 5, 7 or 10.
    ///
    /// Load-bearing far beyond drawing an axis. A rating question is the only
    /// thing an NPS or CSAT template is built out of — PostHog has no distinct
    /// "nps" question type — so the bucketing of an NPS score can only come
    /// from here. Two surveys in the project this was built against are *named*
    /// NPS and declare `scale: 5`; scoring them with the 9–10 promoter rule
    /// would be arithmetic on the wrong scale. See `SurveyRatingScale`.
    public let scale: Int?

    /// `number`, `emoji`, or `label` — how the survey rendered the scale.
    public let display: String?

    public let lowerBoundLabel: String?
    public let upperBoundLabel: String?

    /// True when the respondent could skip this question, which is why a low
    /// answered-count here is not necessarily drop-off.
    public let isOptional: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, question, choices, scale, display
        case lowerBoundLabel, upperBoundLabel
        case isOptional = "optional"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        choices = try c.decodeIfPresent([String].self, forKey: .choices)
        scale = try c.decodeIfPresent(Int.self, forKey: .scale)
        display = try c.decodeIfPresent(String.self, forKey: .display)
        lowerBoundLabel = try c.decodeIfPresent(String.self, forKey: .lowerBoundLabel)
        upperBoundLabel = try c.decodeIfPresent(String.self, forKey: .upperBoundLabel)
        isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
    }

    public init(
        id: String? = nil,
        type: String? = nil,
        question: String? = nil,
        choices: [String]? = nil,
        scale: Int? = nil,
        display: String? = nil,
        lowerBoundLabel: String? = nil,
        upperBoundLabel: String? = nil,
        isOptional: Bool = false
    ) {
        self.id = id
        self.type = type
        self.question = question
        self.choices = choices
        self.scale = scale
        self.display = display
        self.lowerBoundLabel = lowerBoundLabel
        self.upperBoundLabel = upperBoundLabel
        self.isOptional = isOptional
    }

    /// What kind of answer this question collects, which decides both the HogQL
    /// that reads it and the aggregation that can be drawn from it.
    public var kind: SurveyQuestionKind {
        SurveyQuestionKind(rawType: type)
    }
}

/// The answer shapes PostHog collects.
///
/// `unsupported` is a real state, not a failure: a `link` question records no
/// answer at all, and PostHog can add a type tomorrow that this build has never
/// heard of. Both must read as "nothing to aggregate here", which is a different
/// sentence from "nobody answered".
public enum SurveyQuestionKind: Sendable, Hashable {
    case open
    case rating
    case singleChoice
    case multipleChoice
    case link
    case unsupported(String)

    init(rawType: String?) {
        switch rawType {
        case "open": self = .open
        case "rating": self = .rating
        case "single_choice": self = .singleChoice
        case "multiple_choice": self = .multipleChoice
        case "link": self = .link
        case let other: self = .unsupported(other ?? "unknown")
        }
    }

    /// Multi-select answers are stored as a JSON array and have to be read with
    /// a different HogQL accessor from every other type. Getting this wrong is
    /// silent — `JSONExtractArrayRaw` over a scalar returns `[]`, so asking for
    /// an array where there is a string loses the answer without an error.
    public var isMultiSelect: Bool { self == .multipleChoice }
}

/// An experiment's lifecycle state, as the API reports it.
///
/// `ExperimentStatusEnum` in the schema this deployment publishes. Two of the
/// five are documented there as *virtual* — `paused` is derived from
/// `feature_flag.active` and `exposure_frozen` from the flag's release groups —
/// which matters because neither can be inferred from `start_date`/`end_date`,
/// the only signals this model used to have.
public enum ExperimentStatus: String, Sendable, Hashable, Decodable {
    case draft
    case running
    case paused
    case exposureFrozen = "exposure_frozen"
    case stopped

    /// The word shown on screen. Always travels with any colour that encodes it.
    public var displayName: String {
        switch self {
        case .draft: "Draft"
        case .running: "Running"
        case .paused: "Paused"
        case .exposureFrozen: "Exposure frozen"
        case .stopped: "Complete"
        }
    }

    /// Whether exposures are still being counted. `paused` keeps its data but
    /// stops collecting, so it reads results and is not "not started".
    public var hasLaunched: Bool { self != .draft }
}

/// What the team concluded when they ended the experiment.
///
/// `ConclusionEnum`. This is a *human* judgement recorded on the experiment, not
/// a statistical output, and the screen must not let the two be confused.
/// `CaseIterable` because ending an experiment has to *offer* these: the API
/// makes `conclusion` optional and then assigns it unconditionally, so a caller
/// that ends an experiment without naming one writes `null` over whatever was
/// recorded. `PostHogAPI.endExperiment` therefore requires a value, and a
/// required value needs a full list to pick from.
public enum ExperimentConclusion: String, Sendable, Hashable, Decodable, CaseIterable {
    case won, lost, inconclusive
    case stoppedEarly = "stopped_early"
    case invalid

    public var displayName: String {
        switch self {
        case .won: "Won"
        case .lost: "Lost"
        case .inconclusive: "Inconclusive"
        case .stoppedEarly: "Stopped early"
        case .invalid: "Invalid"
        }
    }

    /// What choosing this conclusion asserts, in the words of someone who will
    /// read it later without the context of the day it was written.
    ///
    /// These are labels on a *human judgement*, not statistical outputs, and the
    /// picker sits directly under a card showing a computed verdict — so each one
    /// has to say what a person is claiming rather than restating the word.
    public var meaning: String {
        switch self {
        case .won: "The test variant beat the control and you're keeping it."
        case .lost: "The control won, or the test variant did harm."
        case .inconclusive: "It ran its course and the result wasn't clear either way."
        case .stoppedEarly: "It was cut short before it could answer the question."
        case .invalid: "Something was wrong with the setup, so the numbers don't mean what they appear to."
        }
    }
}

/// One arm of the experiment's feature flag.
public struct ExperimentVariant: Sendable, Hashable, Identifiable, Decodable {
    public let key: String
    public let name: String?
    public let rolloutPercentage: Int?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, name
        case rolloutPercentage = "rollout_percentage"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "unknown"
        name = try c.decodeIfPresent(String.self, forKey: .name)
        rolloutPercentage = try c.decodeIfPresent(Int.self, forKey: .rolloutPercentage)
    }
}

/// The running-time calculator's saved state.
public struct ExperimentRunningTime: Sendable, Hashable, Decodable {
    public let minimumDetectableEffect: Double?
    public let recommendedSampleSize: Double?
    public let recommendedRunningTimeDays: Double?

    enum CodingKeys: String, CodingKey {
        case minimumDetectableEffect = "minimum_detectable_effect"
        case recommendedSampleSize = "recommended_sample_size"
        case recommendedRunningTimeDays = "recommended_running_time"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimumDetectableEffect = try c.decodeIfPresent(Double.self, forKey: .minimumDetectableEffect)
        recommendedSampleSize = try c.decodeIfPresent(Double.self, forKey: .recommendedSampleSize)
        recommendedRunningTimeDays = try c.decodeIfPresent(Double.self, forKey: .recommendedRunningTimeDays)
    }
}

public struct Experiment: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let featureFlagKey: String?
    public let startDate: Date?
    public let endDate: Date?
    public let archived: Bool

    /// The API's own lifecycle state. Optional only because it is absent from
    /// captures taken before the field existed; when present it always wins over
    /// the date-derived guess below.
    public let status: ExperimentStatus?
    public let conclusion: ExperimentConclusion?
    public let conclusionComment: String?
    public let variants: [ExperimentVariant]
    public let runningTime: ExperimentRunningTime?
    /// Variant keys the analysis leaves out. They are still served to users.
    public let excludedVariants: [String]

    /// Primary metrics. Empty from the list endpoint, which uses the leaner
    /// `ExperimentBasicSerializer` and defers these columns — so an empty array
    /// here means "not loaded yet", not "no metrics".
    public let metrics: [ExperimentMetric]
    public let secondaryMetrics: [ExperimentMetric]

    /// The engine this experiment is configured to use, from `stats_config`.
    ///
    /// The schema types `stats_config` as a free-form object, so this is read
    /// defensively. It is only the *configured* method; a result payload states
    /// which engine actually produced it, and that statement wins.
    public let configuredStatsMethod: ExperimentStatsMethod?

    /// The linked flag, verbatim. `ExperimentExposureQuery` requires the whole
    /// flag object echoed back, so it is kept rather than reconstructed.
    public let featureFlagRaw: JSONValue?
    public let exposureCriteriaRaw: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, name, description, archived, status, conclusion, metrics
        case featureFlagKey = "feature_flag_key"
        case startDate = "start_date"
        case endDate = "end_date"
        case conclusionComment = "conclusion_comment"
        case featureFlag = "feature_flag"
        case runningTimeCalculation = "running_time_calculation"
        case excludedVariants = "excluded_variants"
        case secondaryMetrics = "metrics_secondary"
        case statsConfig = "stats_config"
        case exposureCriteria = "exposure_criteria"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled experiment"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        featureFlagKey = try c.decodeIfPresent(String.self, forKey: .featureFlagKey)
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate).flatMap(PostHogDate.parse)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate).flatMap(PostHogDate.parse)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false

        // A status string PostHog adds later must not fail the whole page, so an
        // unknown value falls through to the date-derived text.
        status = try? c.decodeIfPresent(ExperimentStatus.self, forKey: .status)
        conclusion = try? c.decodeIfPresent(ExperimentConclusion.self, forKey: .conclusion)
        conclusionComment = try c.decodeIfPresent(String.self, forKey: .conclusionComment)
        runningTime = try? c.decodeIfPresent(ExperimentRunningTime.self, forKey: .runningTimeCalculation)
        excludedVariants = (try? c.decodeIfPresent([String].self, forKey: .excludedVariants)) ?? []

        metrics = (try? c.decodeIfPresent([ExperimentMetric].self, forKey: .metrics)) ?? []
        secondaryMetrics = (try? c.decodeIfPresent([ExperimentMetric].self, forKey: .secondaryMetrics)) ?? []

        featureFlagRaw = try? c.decodeIfPresent(JSONValue.self, forKey: .featureFlag)
        exposureCriteriaRaw = try? c.decodeIfPresent(JSONValue.self, forKey: .exposureCriteria)

        if case .array(let raw)? = featureFlagRaw?["filters"]?["multivariate"]?["variants"] {
            variants = raw.compactMap { value in
                guard let key = value["key"]?.stringValue else { return nil }
                return ExperimentVariant(
                    key: key,
                    name: value["name"]?.stringValue,
                    rolloutPercentage: value["rollout_percentage"]?.intValue
                )
            }
        } else {
            variants = []
        }

        let statsConfig = try? c.decodeIfPresent(JSONValue.self, forKey: .statsConfig)
        configuredStatsMethod = statsConfig?["method"]?.stringValue
            .flatMap(ExperimentStatsMethod.init(rawValue:))
    }

    /// The status word. Prefers the API's own state; the date-derived fallback
    /// only runs for payloads that predate the `status` field.
    public var statusText: String {
        if let status { return archived ? "Archived" : status.displayName }
        if archived { return "Archived" }
        if endDate != nil { return "Complete" }
        if startDate != nil { return "Running" }
        return "Draft"
    }

    /// Whether this experiment has ever collected exposures. Drives whether the
    /// screen asks for results at all.
    public var hasLaunched: Bool {
        status?.hasLaunched ?? (startDate != nil)
    }

    /// The variant treated as the control arm. PostHog's rule, per the schema:
    /// the arm keyed `control` when present, otherwise the first.
    public var baselineVariant: ExperimentVariant? {
        variants.first { $0.key == "control" } ?? variants.first
    }

    /// Days the experiment has been collecting, to the given instant.
    public func daysRunning(asOf now: Date = Date()) -> Int? {
        guard let startDate else { return nil }
        let end = endDate ?? now
        guard end >= startDate else { return nil }
        return Calendar.current.dateComponents([.day], from: startDate, to: end).day
    }
}

extension ExperimentVariant {
    /// Memberwise init, needed because the decoder above builds variants out of
    /// the raw flag payload rather than decoding them in place.
    init(key: String, name: String?, rolloutPercentage: Int?) {
        self.key = key
        self.name = name
        self.rolloutPercentage = rolloutPercentage
    }
}

/// Row from `GET /insights/` — the saved insight library, independent of dashboards.
public struct InsightSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String?
    public let derivedName: String?
    public let favorited: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, favorited
        case derivedName = "derived_name"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        derivedName = try c.decodeIfPresent(String.self, forKey: .derivedName)
        favorited = try c.decodeIfPresent(Bool.self, forKey: .favorited) ?? false
    }

    public var title: String {
        if let name, !name.isEmpty { return name }
        if let derivedName, !derivedName.isEmpty { return derivedName }
        return "Untitled insight"
    }
}
