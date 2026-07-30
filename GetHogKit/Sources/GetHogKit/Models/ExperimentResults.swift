import Foundation

// Experiment readout models.
//
// Shapes here are taken from the OpenAPI document this deployment publishes at
// `GET /api/schema/` — `ExperimentQueryResponse`, `ExperimentExposureQueryResponse`,
// `ExperimentVariantResultBayesian`, `ExperimentVariantResultFrequentist`,
// `ExperimentStatsBaseValidated` and their enums. That document is the server
// describing itself, so it is a measurement rather than prose documentation.
//
// What could *not* be measured: project [REMOVED PRIVATE DATA] has zero experiments, and
// `ExperimentQuery` rejects a request without `experiment_id` ("experiment_id is
// required", HTTP 400), so no live results payload was ever observed. The
// fixtures are built to the published schema and are labelled as such. Every
// field below is therefore decoded defensively: absent is never a decode error,
// and an unrecognised enum value degrades to a stated unknown rather than
// throwing.

// MARK: - Statistical method

/// Which statistics produced a readout.
///
/// The two are not interchangeable and must never be relabelled as each other:
/// a Bayesian "chance to win" is the posterior probability that a variant beats
/// the baseline, while a frequentist p-value is the probability of seeing this
/// data if there were *no* difference. Presenting one under the other's name
/// inverts its meaning.
public enum ExperimentStatsMethod: String, Sendable, Hashable, Codable {
    case bayesian
    case frequentist

    /// What this method calls the interval it reports.
    public var intervalName: String {
        switch self {
        case .bayesian: "credible interval"
        case .frequentist: "confidence interval"
        }
    }

    public var displayName: String {
        switch self {
        case .bayesian: "Bayesian"
        case .frequentist: "Frequentist"
        }
    }
}

/// Why a variant's numbers were not turned into a verdict.
///
/// `ExperimentStatsValidationFailure` in the published schema.
public enum ExperimentValidationFailure: String, Sendable, Hashable, Decodable {
    case notEnoughExposures = "not-enough-exposures"
    case baselineMeanIsZero = "baseline-mean-is-zero"
    case notEnoughMetricData = "not-enough-metric-data"

    public var explanation: String {
        switch self {
        case .notEnoughExposures:
            "Too few people have seen this experiment to compare variants."
        case .baselineMeanIsZero:
            "The control group's value is zero, so there is no baseline to compare against."
        case .notEnoughMetricData:
            "Too few metric events have been recorded to compare variants."
        }
    }
}

/// `ExperimentSignificanceCode` — why the engine did or did not call a result.
public enum ExperimentSignificanceCode: String, Sendable, Hashable, Decodable {
    case significant
    case notEnoughExposure = "not_enough_exposure"
    case lowWinProbability = "low_win_probability"
    case highLoss = "high_loss"
    case highPValue = "high_p_value"
}

// MARK: - Metric definitions

/// The four metric shapes the current experiment engine supports.
///
/// Held alongside the raw string so a kind this build does not know about can
/// still be *named* on screen instead of silently rendering as an empty card —
/// the WorldMap lesson, applied to metrics.
public enum ExperimentMetricType: String, Sendable, Hashable, Decodable {
    case mean
    case funnel
    case ratio
    case retention
}

/// One primary or secondary metric attached to an experiment.
///
/// `rawMetric` is kept verbatim because running a metric's result means sending
/// the same definition back to `/query/` inside an `ExperimentQuery`. Rebuilding
/// it from parsed fields would silently drop anything this build does not model
/// (conversion windows, winsorisation bounds, breakdown filters) and quietly
/// compute a *different* metric than the one PostHog shows on the web.
public struct ExperimentMetric: Sendable, Hashable, Identifiable, Decodable {
    public let uuid: String?
    public let name: String?
    /// `nil` when the API reported a `metric_type` this build does not model.
    public let type: ExperimentMetricType?
    /// The `metric_type` exactly as sent, including values not in the enum.
    public let rawType: String?
    /// `increase` or `decrease` — which direction counts as an improvement.
    public let goal: String?
    public let rawMetric: JSONValue

    public var id: String { uuid ?? name ?? rawType ?? UUID().uuidString }

    /// Falls back to the metric type, then to a stated placeholder, so a metric
    /// row is never a blank line.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let rawType, !rawType.isEmpty { return rawType.capitalized + " metric" }
        return "Untitled metric"
    }

    /// True when a rise in this metric is bad news, so a delta badge can tint
    /// against the direction rather than with it.
    public var isDecreaseGoal: Bool { goal == "decrease" }

    enum CodingKeys: String, CodingKey {
        case uuid, name, goal
        case metricType = "metric_type"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        rawType = try c.decodeIfPresent(String.self, forKey: .metricType)
        type = rawType.flatMap(ExperimentMetricType.init(rawValue:))
        rawMetric = (try? JSONValue(from: decoder)) ?? .null
    }
}

// MARK: - Variant results

/// One arm's numbers, from either engine.
///
/// The two engines return different field sets, but every field either one
/// carries is optional in the schema, so a single struct decodes both without
/// guessing: `method` is a constant on the wire (`"bayesian"` / `"frequentist"`)
/// and is the authoritative statement of which engine ran. The baseline arrives
/// as `ExperimentStatsBaseValidated`, which carries no `method` at all — hence
/// `method` is optional here rather than required.
public struct ExperimentVariantResult: Sendable, Hashable, Identifiable, Decodable {
    public let key: String
    public let method: ExperimentStatsMethod?
    public let numberOfSamples: Int
    public let sum: Double
    public let sumSquares: Double

    /// Posterior probability this arm beats the baseline. Bayesian only.
    public let chanceToWin: Double?
    /// Frequentist only.
    public let pValue: Double?
    /// Relative-effect bounds. A credible interval under Bayesian, a confidence
    /// interval under frequentist — `method` says which, and the UI must label
    /// it accordingly.
    public let interval: ClosedRange<Double>?
    public let significant: Bool?
    public let validationFailures: [ExperimentValidationFailure]
    /// Per-step counts for a funnel metric.
    public let stepCounts: [Int]?

    public var id: String { key }

    /// Per-user mean. `nil` when nobody was exposed, which is a real state and
    /// not a zero.
    public var mean: Double? {
        guard numberOfSamples > 0 else { return nil }
        return sum / Double(numberOfSamples)
    }

    /// True when this arm's numbers were rejected by the engine's own guards.
    public var isUsable: Bool { validationFailures.isEmpty && numberOfSamples > 0 }

    enum CodingKeys: String, CodingKey {
        case key, method, significant
        case numberOfSamples = "number_of_samples"
        case sum
        case sumSquares = "sum_squares"
        case chanceToWin = "chance_to_win"
        case pValue = "p_value"
        case credibleInterval = "credible_interval"
        case confidenceInterval = "confidence_interval"
        case validationFailures = "validation_failures"
        case stepCounts = "step_counts"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "unknown"
        method = try? c.decodeIfPresent(ExperimentStatsMethod.self, forKey: .method)
        numberOfSamples = try c.decodeIfPresent(Int.self, forKey: .numberOfSamples) ?? 0
        sum = try c.decodeIfPresent(Double.self, forKey: .sum) ?? 0
        sumSquares = try c.decodeIfPresent(Double.self, forKey: .sumSquares) ?? 0
        chanceToWin = try c.decodeIfPresent(Double.self, forKey: .chanceToWin)
        pValue = try c.decodeIfPresent(Double.self, forKey: .pValue)
        significant = try c.decodeIfPresent(Bool.self, forKey: .significant)
        stepCounts = try c.decodeIfPresent([Int].self, forKey: .stepCounts)

        // An unknown failure string must not throw the whole readout away, but
        // it must not vanish either — it is caught by `hasUnknownFailure`.
        let rawFailures = (try? c.decodeIfPresent([String].self, forKey: .validationFailures)) ?? []
        validationFailures = rawFailures.compactMap(ExperimentValidationFailure.init(rawValue:))

        let credible = try? c.decodeIfPresent([Double].self, forKey: .credibleInterval)
        let confidence = try? c.decodeIfPresent([Double].self, forKey: .confidenceInterval)
        interval = Self.range(from: credible ?? nil) ?? Self.range(from: confidence ?? nil)
    }

    /// The schema pins these to exactly two members, but a malformed pair must
    /// not crash `ClosedRange` on a reversed bound.
    private static func range(from bounds: [Double]?) -> ClosedRange<Double>? {
        guard let bounds, bounds.count == 2 else { return nil }
        let lower = min(bounds[0], bounds[1])
        let upper = max(bounds[0], bounds[1])
        guard lower.isFinite, upper.isFinite else { return nil }
        return lower...upper
    }
}

// MARK: - Metric result

/// The decoded `ExperimentQueryResponse` for one metric.
public struct ExperimentMetricResult: Sendable, Hashable, Decodable {
    public let baseline: ExperimentVariantResult?
    public let variants: [ExperimentVariantResult]
    public let significant: Bool?
    public let significanceCode: ExperimentSignificanceCode?
    public let pValue: Double?
    public let probability: [String: Double]
    public let metric: ExperimentMetric?
    /// PostHog reports query failures in the body with HTTP 200.
    public let error: String?

    /// Which engine produced this, taken from the variant rows themselves.
    ///
    /// Preferred over the experiment's configured `stats_config.method` because
    /// it describes the response in hand rather than the setting at read time —
    /// a cached result computed before the setting changed would otherwise be
    /// labelled with statistics that did not produce it.
    public var method: ExperimentStatsMethod? {
        variants.compactMap(\.method).first
    }

    enum CodingKeys: String, CodingKey {
        case baseline, significant, probability, metric, error
        case variantResults = "variant_results"
        case significanceCode = "significance_code"
        case pValue = "p_value"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try? c.decodeIfPresent(ExperimentVariantResult.self, forKey: .baseline)
        variants = (try? c.decodeIfPresent([ExperimentVariantResult].self, forKey: .variantResults)) ?? []
        significant = try c.decodeIfPresent(Bool.self, forKey: .significant)
        significanceCode = try? c.decodeIfPresent(ExperimentSignificanceCode.self, forKey: .significanceCode)
        pValue = try c.decodeIfPresent(Double.self, forKey: .pValue)
        probability = (try? c.decodeIfPresent([String: Double].self, forKey: .probability)) ?? [:]
        metric = try? c.decodeIfPresent(ExperimentMetric.self, forKey: .metric)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    public static func decode(from data: Data) throws -> ExperimentMetricResult {
        try JSONDecoder().decode(ExperimentMetricResult.self, from: data)
    }
}

// MARK: - Comparison

/// One variant measured against the baseline, with everything the screen needs
/// to state direction, size and confidence without reaching back into raw sums.
public struct ExperimentComparison: Sendable, Hashable, Identifiable {
    public let variantKey: String
    public let baselineMean: Double?
    public let variantMean: Double?
    public let exposures: Int
    public let baselineExposures: Int
    public let chanceToWin: Double?
    public let pValue: Double?
    public let interval: ClosedRange<Double>?
    public let isSignificant: Bool
    public let validationFailures: [ExperimentValidationFailure]

    public var id: String { variantKey }

    /// Relative change against the baseline, e.g. `0.19` for a 19% lift.
    ///
    /// `nil` when the baseline mean is zero or missing — dividing by it would
    /// produce an infinity that renders as a plausible-looking number.
    public var relativeDelta: Double? {
        guard let baselineMean, let variantMean, baselineMean != 0 else { return nil }
        return (variantMean - baselineMean) / abs(baselineMean)
    }

    public var isUsable: Bool { validationFailures.isEmpty && exposures > 0 }
}

// MARK: - Verdict

/// The one-line answer to "did the test win?".
///
/// Deliberately closed, and deliberately includes three ways of *not* answering.
/// A screen whose only outputs are winners will invent one.
public enum ExperimentVerdict: Sendable, Hashable {
    /// Draft: never launched, so there is nothing to measure.
    case notStarted
    /// Launched, but the query returned nothing usable.
    case noResults
    /// Numbers exist but the engine refused to judge them.
    case tooEarly(ExperimentValidationFailure)
    /// Enough data, no arm separated from the baseline.
    case noSignificantDifference(leader: String?)
    /// An arm is significantly better than the baseline.
    case significantWin(variant: String)
    /// Every arm that separated from the baseline did so downwards.
    case significantLoss(variant: String)

    /// Short enough to be the first thing read on a phone.
    public var headline: String {
        switch self {
        case .notStarted: "Not started"
        case .noResults: "No results yet"
        case .tooEarly: "Too early to call"
        case .noSignificantDifference: "No clear winner"
        case .significantWin(let variant): "\(variant) is winning"
        case .significantLoss(let variant): "\(variant) is losing"
        }
    }

    /// A sentence that never implies more certainty than the state carries.
    public var explanation: String {
        switch self {
        case .notStarted:
            "This experiment has not been launched, so no one has been exposed to it yet."
        case .noResults:
            "No metric results came back for this experiment."
        case .tooEarly(let failure):
            failure.explanation
        case .noSignificantDifference(let leader):
            if let leader {
                "\(leader) is ahead, but not by enough to rule out chance."
            } else {
                "No variant has separated from the control group."
            }
        case .significantWin(let variant):
            "\(variant) beat the control group by more than chance explains."
        case .significantLoss(let variant):
            "\(variant) did worse than the control group by more than chance explains."
        }
    }

    /// True only when the statistics actually support a call. Drives whether the
    /// screen is allowed to look like an answer.
    public var isDecided: Bool {
        switch self {
        case .significantWin, .significantLoss: true
        default: false
        }
    }
}

// MARK: - Readout

/// A metric's result reduced to a verdict plus its comparisons.
public struct ExperimentReadout: Sendable, Hashable {
    public let metric: ExperimentMetric?
    public let method: ExperimentStatsMethod?
    public let verdict: ExperimentVerdict
    public let comparisons: [ExperimentComparison]
    public let baselineKey: String?
    public let totalExposures: Int

    /// Builds the readout.
    ///
    /// `isRunning` is passed in rather than inferred because a draft experiment
    /// and a running one that has returned nothing are different facts and get
    /// different copy.
    public init(result: ExperimentMetricResult?, isRunning: Bool) {
        metric = result?.metric
        method = result?.method

        guard isRunning else {
            verdict = .notStarted
            comparisons = []
            baselineKey = nil
            totalExposures = 0
            return
        }
        guard let result, let baseline = result.baseline, !result.variants.isEmpty else {
            verdict = .noResults
            comparisons = []
            baselineKey = result?.baseline?.key
            totalExposures = result?.baseline?.numberOfSamples ?? 0
            return
        }

        baselineKey = baseline.key
        let built = result.variants.map { variant in
            ExperimentComparison(
                variantKey: variant.key,
                baselineMean: baseline.mean,
                variantMean: variant.mean,
                exposures: variant.numberOfSamples,
                baselineExposures: baseline.numberOfSamples,
                chanceToWin: variant.chanceToWin,
                pValue: variant.pValue,
                interval: variant.interval,
                isSignificant: variant.significant ?? false,
                validationFailures: variant.validationFailures.isEmpty
                    ? baseline.validationFailures
                    : variant.validationFailures
            )
        }
        comparisons = built
        totalExposures = baseline.numberOfSamples + built.reduce(0) { $0 + $1.exposures }
        verdict = Self.verdict(for: built, code: result.significanceCode)
    }

    private static func verdict(
        for comparisons: [ExperimentComparison],
        code: ExperimentSignificanceCode?
    ) -> ExperimentVerdict {
        let usable = comparisons.filter(\.isUsable)
        guard !usable.isEmpty else {
            // Prefer the engine's own reason over a guess.
            let failure = comparisons.compactMap(\.validationFailures.first).first
            if let failure { return .tooEarly(failure) }
            if code == .notEnoughExposure { return .tooEarly(.notEnoughExposures) }
            return .noResults
        }
        if code == .notEnoughExposure {
            return .tooEarly(.notEnoughExposures)
        }

        let decided = usable.filter(\.isSignificant)
        if let best = decided.max(by: { ($0.relativeDelta ?? 0) < ($1.relativeDelta ?? 0) }) {
            if let delta = best.relativeDelta, delta > 0 {
                return .significantWin(variant: best.variantKey)
            }
            // Every arm that separated did so downwards. Name the least-bad one,
            // because "which of these is losing least" is still the question a
            // reader has.
            return .significantLoss(variant: best.variantKey)
        }

        // Nothing is significant. A leader is still worth naming, as long as the
        // copy is clear that it is not a call.
        let leader = usable.max { a, b in
            switch (a.chanceToWin, b.chanceToWin) {
            case (let x?, let y?): x < y
            default: (a.relativeDelta ?? -.infinity) < (b.relativeDelta ?? -.infinity)
            }
        }
        let named = leader.flatMap { (($0.relativeDelta ?? 0) > 0 || $0.chanceToWin != nil) ? $0.variantKey : nil }
        return .noSignificantDifference(leader: named)
    }
}

// MARK: - Exposures

/// One arm's exposure curve.
public struct ExperimentExposureSeries: Sendable, Hashable, Identifiable, Decodable {
    public let variant: String
    public let days: [Date]
    public let counts: [Double]

    public var id: String { variant }

    enum CodingKeys: String, CodingKey {
        case variant, days
        case counts = "exposure_counts"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? "unknown"
        let raw = (try? c.decodeIfPresent([String].self, forKey: .days)) ?? []
        days = raw.compactMap(PostHogDate.parse)
        counts = (try? c.decodeIfPresent([Double].self, forKey: .counts)) ?? []
    }

    /// Day/count pairs, truncated to the shorter of the two arrays so a ragged
    /// payload cannot index out of bounds.
    public var points: [(date: Date, count: Double)] {
        zip(days, counts).map { (date: $0, count: $1) }
    }
}

/// The decoded `ExperimentExposureQueryResponse`.
public struct ExperimentExposures: Sendable, Hashable, Decodable {
    public let totals: [String: Double]
    public let timeseries: [ExperimentExposureSeries]
    /// Expected traffic split and the p-value of the observed split against it.
    public let expectedSplit: [String: Double]
    public let sampleRatioPValue: Double?
    /// Share of users who saw more than one variant, as a percentage.
    public let multipleVariantPercentage: Double?

    /// The p-value below which the app calls a split mismatched.
    ///
    /// This is *this app's* display threshold, not a value the API reports. It
    /// is deliberately strict: a sample-ratio warning is an instruction to
    /// distrust every number on the screen, so a 1-in-100 false-alarm rate is
    /// the most noise worth carrying.
    public static let sampleRatioMismatchThreshold = 0.01

    public var hasSampleRatioMismatch: Bool {
        guard let sampleRatioPValue else { return false }
        return sampleRatioPValue < Self.sampleRatioMismatchThreshold
    }

    public var totalExposures: Double { totals.values.reduce(0, +) }

    /// Observed share per variant, for showing beside the expected split.
    public var observedSplit: [String: Double] {
        let total = totalExposures
        guard total > 0 else { return [:] }
        return totals.mapValues { $0 / total }
    }

    enum CodingKeys: String, CodingKey {
        case timeseries
        case totals = "total_exposures"
        case sampleRatioMismatch = "sample_ratio_mismatch"
        case biasRisk = "bias_risk"
    }

    private enum SRMKeys: String, CodingKey {
        case expected
        case pValue = "p_value"
    }

    private enum BiasKeys: String, CodingKey {
        case multipleVariantPercentage = "multiple_variant_percentage"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totals = (try? c.decodeIfPresent([String: Double].self, forKey: .totals)) ?? [:]
        timeseries = (try? c.decodeIfPresent([ExperimentExposureSeries].self, forKey: .timeseries)) ?? []

        // `sample_ratio_mismatch` is `anyOf [object, null]`, so the nested
        // container is absent on a healthy read as well as on an old payload.
        // Both mean "no mismatch reported", never "mismatch of zero".
        let srm = try? c.nestedContainer(keyedBy: SRMKeys.self, forKey: .sampleRatioMismatch)
        expectedSplit = (try? srm?.decodeIfPresent([String: Double].self, forKey: .expected)).flatMap { $0 } ?? [:]
        sampleRatioPValue = (try? srm?.decodeIfPresent(Double.self, forKey: .pValue)).flatMap { $0 }

        let bias = try? c.nestedContainer(keyedBy: BiasKeys.self, forKey: .biasRisk)
        multipleVariantPercentage = (try? bias?.decodeIfPresent(Double.self, forKey: .multipleVariantPercentage))
            .flatMap { $0 }
    }

    public static func decode(from data: Data) throws -> ExperimentExposures {
        try JSONDecoder().decode(ExperimentExposures.self, from: data)
    }
}
