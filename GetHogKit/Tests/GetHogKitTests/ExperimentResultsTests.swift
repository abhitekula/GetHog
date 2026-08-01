import Foundation
import Testing

@testable import GetHogKit

// These deterministic fixtures are built to the documented contract for
// `ExperimentQueryResponse`,
// `ExperimentExposureQueryResponse` and the two variant-result schemas — with
// the `/query/` envelope keys (`cache_key`, `is_cached`, `error`, `warnings`)
// around a response node.

@Suite("Experiment lifecycle model")
struct ExperimentModelTests {
    private func experiments() throws -> [Experiment] {
        try Page<Experiment>.decode(from: Fixture.data("experiments.json")).results
    }

    @Test("takes lifecycle state from the API rather than guessing from dates")
    func decodesStatus() throws {
        let all = try experiments()
        #expect(all.count == 4)
        let running = try #require(all.first { $0.id == 7201 })
        let draft = try #require(all.first { $0.id == 7202 })
        let stopped = try #require(all.first { $0.id == 7203 })

        #expect(running.status == .running)
        #expect(draft.status == .draft)
        #expect(stopped.status == .stopped)
        #expect(running.statusText == "Running")
        #expect(draft.statusText == "Draft")
        #expect(stopped.statusText == "Complete")
    }

    @Test("a draft has not launched, a stopped experiment has")
    func launchState() throws {
        let all = try experiments()
        #expect(try #require(all.first { $0.id == 7202 }).hasLaunched == false)
        #expect(try #require(all.first { $0.id == 7201 }).hasLaunched)
        #expect(try #require(all.first { $0.id == 7203 }).hasLaunched)
    }

    @Test("reads variants out of the linked flag's multivariate config")
    func decodesVariants() throws {
        let draft = try #require(try experiments().first { $0.id == 7202 })
        #expect(draft.variants.map(\.key) == [
            "baseline", "inline-help", "modal-guide", "synthetic-observer-7202",
        ])
        #expect(draft.variants.first?.name == "No guidance")
        #expect(draft.variants.first?.rolloutPercentage == 30)
        #expect(draft.baselineVariant?.key == "baseline")
    }

    @Test("the baseline is the control arm, or the first when there is none")
    func baselineFallback() throws {
        let json = Data("""
        {"id":1,"name":"x","feature_flag":{"filters":{"multivariate":{"variants":[
        {"key":"a","rollout_percentage":50},{"key":"b","rollout_percentage":50}]}}}}
        """.utf8)
        let experiment = try JSONDecoder().decode(Experiment.self, from: json)
        #expect(experiment.baselineVariant?.key == "a")
    }

    @Test("carries the recorded human conclusion separately from any statistics")
    func decodesConclusion() throws {
        let stopped = try #require(try experiments().first { $0.id == 7203 })
        #expect(stopped.conclusion == .won)
        #expect(stopped.conclusion?.displayName == "Won")
        #expect(stopped.conclusionComment == "Concise setup copy improved completion for the fictional cohort.")
        // A running experiment has no conclusion — it must not inherit one.
        #expect(try #require(try experiments().first { $0.id == 7201 }).conclusion == nil)
    }

    @Test("keeps the running-time calculator's targets")
    func decodesRunningTime() throws {
        let running = try #require(try experiments().first { $0.id == 7201 })
        #expect(running.runningTime?.recommendedSampleSize == 12_600)
        #expect(running.runningTime?.recommendedRunningTimeDays == 18)
        #expect(running.runningTime?.minimumDetectableEffect == 25)
        // Absent on the stopped one, and absent must stay absent.
        #expect(try #require(try experiments().first { $0.id == 7203 }).runningTime == nil)
    }

    @Test("counts days running against the end date once stopped")
    func daysRunning() throws {
        let stopped = try #require(try experiments().first { $0.id == 7203 })
        #expect(stopped.daysRunning() == 3)
        let draft = try #require(try experiments().first { $0.id == 7202 })
        #expect(draft.daysRunning() == nil)
    }

    @Test("an unknown status string falls back rather than failing the page")
    func unknownStatusDegrades() throws {
        let json = Data(#"{"id":9,"name":"n","status":"teleported","start_date":"2025-06-18T00:00:00Z"}"#.utf8)
        let experiment = try JSONDecoder().decode(Experiment.self, from: json)
        #expect(experiment.status == nil)
        #expect(experiment.statusText == "Running")
        #expect(experiment.hasLaunched)
    }

    @Test("the list endpoint's deferred metrics decode as empty, not as a failure")
    func listHasNoMetrics() throws {
        for experiment in try experiments() {
            #expect(experiment.metrics.isEmpty)
            #expect(experiment.configuredStatsMethod == nil)
        }
    }
}

@Suite("Experiment fixture graph")
struct ExperimentFixtureGraphTests {
    private func page() throws -> Page<Experiment> {
        try Page<Experiment>.decode(from: Fixture.data("experiments.json"))
    }

    private func runningDetail() throws -> Experiment {
        try JSONDecoder().decode(
            Experiment.self,
            from: Fixture.data("experiment_detail_running.json")
        )
    }

    /// Catches a list row borrowing a neighbouring experiment's flag, observer
    /// arm, or conclusion while still decoding as a plausible experiment.
    @Test("every list row owns its exact flag, arms, and lifecycle")
    func listRowsOwnTheirGraphNodes() throws {
        let page = try page()
        let rows = page.results

        #expect(page.count == 4)
        #expect(rows.map(\.id) == [7201, 7202, 7203, 7204])
        #expect(rows.map(\.name) == [
            "Example App onboarding layout",
            "Example App guidance style",
            "Example App setup copy",
            "Example App synthetic navigation experiment",
        ])
        #expect(rows.map { $0.featureFlagKey ?? "<missing>" } == [
            "onboarding-layout",
            "guidance-style",
            "setup-copy",
            "synthetic-navigation-experiment",
        ])
        #expect(rows.map { $0.featureFlagRaw?["key"]?.stringValue ?? "<missing>" } == [
            "onboarding-layout",
            "guidance-style",
            "setup-copy",
            "synthetic-navigation-experiment",
        ])
        #expect(rows.map { $0.featureFlagRaw?["id"]?.intValue ?? -1 } == [7301, 7302, 7303, 8204])
        #expect(rows.map { $0.featureFlagRaw?["name"]?.stringValue ?? "<missing>" } == [
            "Example App onboarding layout",
            "Example App guidance style",
            "Example App setup copy",
            "Example App synthetic navigation experiment",
        ])
        #expect(rows.map { $0.variants.map(\.key) } == [
            ["baseline", "streamlined", "synthetic-observer-7201"],
            ["baseline", "inline-help", "modal-guide", "synthetic-observer-7202"],
            ["baseline", "concise", "synthetic-observer-7203"],
            ["baseline", "compact-navigation", "synthetic-observer-7204"],
        ])

        let running = try #require(rows.first { $0.id == 7201 })
        #expect(running.status == .running)
        #expect(running.startDate == PostHogDate.parse("2026-01-14T12:00:00.000Z"))
        #expect(running.endDate == nil)
        #expect(running.conclusion == nil)
        #expect(running.conclusionComment == nil)

        let draft = try #require(rows.first { $0.id == 7202 })
        #expect(draft.status == .draft)
        #expect(draft.startDate == nil)
        #expect(draft.endDate == nil)
        #expect(draft.conclusion == nil)
        #expect(draft.conclusionComment == nil)

        let stopped = try #require(rows.first { $0.id == 7203 })
        #expect(stopped.status == .stopped)
        #expect(stopped.startDate == PostHogDate.parse("2026-01-04T20:34:17.000Z"))
        #expect(stopped.endDate == PostHogDate.parse("2026-01-08T17:08:34.000Z"))
        #expect(stopped.conclusion == .won)
        #expect(stopped.conclusionComment == "Concise setup copy improved completion for the fictional cohort.")

        let secondDraft = try #require(rows.first { $0.id == 7204 })
        #expect(secondDraft.status == .draft)
        #expect(secondDraft.startDate == nil)
        #expect(secondDraft.endDate == nil)
        #expect(secondDraft.conclusion == nil)
        #expect(secondDraft.conclusionComment == nil)
    }

    /// Catches the list and detail routes drifting into different experiments,
    /// or a result fixture naming an arm the linked feature flag cannot assign.
    @Test("detail, results, and exposures link to the running list row")
    func detailResultsAndExposuresShareOneGraph() throws {
        let listRow = try #require(try page().results.first { $0.id == 7201 })
        let detail = try runningDetail()

        #expect(detail.id == 7201)
        #expect(detail.name == "Example App onboarding layout")
        #expect(detail.featureFlagKey == "onboarding-layout")
        #expect(detail.featureFlagRaw?["key"]?.stringValue == "onboarding-layout")
        #expect(detail.startDate == PostHogDate.parse("2026-01-14T12:00:00.000Z"))
        #expect(detail.status == .running)
        #expect(detail.variants.map(\.key) == [
            "baseline", "streamlined", "synthetic-observer-7201",
        ])
        #expect(listRow.id == detail.id)
        #expect(listRow.name == detail.name)
        #expect(listRow.featureFlagKey == detail.featureFlagKey)
        #expect(listRow.startDate == detail.startDate)

        let bayesian = try ExperimentMetricResult.decode(
            from: Fixture.data("experiment_result_bayesian.json")
        )
        #expect(bayesian.metric?.uuid == "018f9000-0000-7000-8000-000000000179")
        #expect([bayesian.baseline?.key ?? "<missing>"] + bayesian.variants.map(\.key) == [
            "baseline", "streamlined", "synthetic-observer-7201",
        ])

        let frequentist = try ExperimentMetricResult.decode(
            from: Fixture.data("experiment_result_frequentist.json")
        )
        #expect(frequentist.metric?.uuid == "018f9000-0000-7000-8000-000000000062")
        #expect([frequentist.baseline?.key ?? "<missing>"] + frequentist.variants.map(\.key) == [
            "baseline", "streamlined", "synthetic-observer-7201",
        ])

        let insufficient = try ExperimentMetricResult.decode(
            from: Fixture.data("experiment_result_insufficient.json")
        )
        #expect(insufficient.metric?.uuid == "018f9000-0000-7000-8000-000000000028")
        #expect([insufficient.baseline?.key ?? "<missing>"] + insufficient.variants.map(\.key) == [
            "baseline", "streamlined", "synthetic-observer-7201",
        ])

        let exposures = try ExperimentExposures.decode(
            from: Fixture.data("experiment_exposures.json")
        )
        #expect(exposures.timeseries.map(\.variant) == [
            "baseline", "streamlined", "synthetic-observer-7201",
        ])
        #expect(Set(exposures.totals.keys) == [
            "baseline", "streamlined", "synthetic-observer-7201",
        ])
        #expect(Set(exposures.expectedSplit.keys) == [
            "baseline", "streamlined", "synthetic-observer-7201",
        ])
        let startDate = try #require(detail.startDate)
        #expect(exposures.timeseries.flatMap(\.days).allSatisfy { $0 >= startDate })
    }
}

@Suite("Experiment detail")
struct ExperimentDetailTests {
    private func detail() throws -> Experiment {
        try JSONDecoder().decode(Experiment.self, from: Fixture.data("experiment_detail_running.json"))
    }

    @Test("decodes primary and secondary metrics with their types")
    func decodesMetrics() throws {
        let experiment = try detail()
        #expect(experiment.metrics.count == 4)
        #expect(experiment.metrics.map(\.type) == [.funnel, .mean, .retention, .retention])
        #expect(experiment.metrics.first?.displayName == "Meteor report opened")
        #expect(experiment.secondaryMetrics.count == 2)
        #expect(experiment.secondaryMetrics.contains { $0.isDecreaseGoal })
    }

    @Test("keeps each metric definition exactly so it can be sent back")
    func keepsRawMetric() throws {
        let metric = try #require(try detail().metrics.first)
        #expect(metric.rawMetric["metric_type"]?.stringValue == "funnel")
        // The series must survive intact — it is what makes this a funnel.
        guard case .array(let series)? = metric.rawMetric["series"] else {
            Issue.record("funnel metric lost its series")
            return
        }
        #expect(series.count == 3)
        #expect(series.first?["event"]?.stringValue == "checkout_completed")
    }

    @Test("reads the configured statistical method out of stats_config")
    func decodesStatsMethod() throws {
        #expect(try detail().configuredStatsMethod == .bayesian)
    }

    @Test("a metric type this build cannot draw is still named, never blank")
    func unknownMetricTypeIsNamed() throws {
        let json = Data(#"{"kind":"ExperimentMetric","metric_type":"quantile","name":null}"#.utf8)
        let metric = try JSONDecoder().decode(ExperimentMetric.self, from: json)
        #expect(metric.type == nil)
        #expect(metric.rawType == "quantile")
        #expect(metric.displayName == "Quantile metric")
    }

    @Test("keeps the flag payload the exposure query requires")
    func keepsFlagPayload() throws {
        let experiment = try detail()
        #expect(experiment.featureFlagRaw?["key"]?.stringValue == "onboarding-layout")
        #expect(experiment.exposureCriteriaRaw?["filterTestAccounts"] == .bool(true))
    }
}

@Suite("Experiment results — Bayesian")
struct ExperimentBayesianTests {
    private func result() throws -> ExperimentMetricResult {
        try ExperimentMetricResult.decode(from: Fixture.data("experiment_result_bayesian.json"))
    }

    @Test("the method comes from the variant rows, not from a setting")
    func methodFromResponse() throws {
        #expect(try result().method == .bayesian)
        #expect(ExperimentStatsMethod.bayesian.intervalName == "credible interval")
    }

    @Test("decodes chance to win and the credible interval")
    func decodesBayesianFields() throws {
        let decoded = try result()
        let variant = try #require(decoded.variants.first { $0.key == "streamlined" })
        #expect(variant.key == "streamlined")
        #expect(variant.chanceToWin == 0.83)
        #expect(variant.pValue == nil)
        #expect(variant.interval == 0.04...0.28)
        #expect(variant.significant == true)
        #expect(variant.numberOfSamples == 8383)
    }

    @Test("computes the per-arm mean and the relative delta against the baseline")
    func computesDelta() throws {
        let readout = ExperimentReadout(result: try result(), isRunning: true)
        let comparison = try #require(readout.comparisons.first { $0.variantKey == "streamlined" })
        #expect(abs(try #require(comparison.baselineMean) - 0.149840) < 0.00001)
        #expect(abs(try #require(comparison.variantMean) - 0.178540) < 0.00001)
        #expect(abs(try #require(comparison.relativeDelta) - 0.19154) < 0.0001)
    }

    @Test("calls a significant positive result a win, and names the variant")
    func verdictIsWin() throws {
        let readout = ExperimentReadout(result: try result(), isRunning: true)
        #expect(readout.verdict == .significantWin(variant: "streamlined"))
        #expect(readout.verdict.isDecided)
        #expect(readout.verdict.headline == "streamlined is winning")
        #expect(readout.baselineKey == "baseline")
        #expect(readout.totalExposures == 16_811)
    }
}

@Suite("Experiment results — frequentist")
struct ExperimentFrequentistTests {
    private func result() throws -> ExperimentMetricResult {
        try ExperimentMetricResult.decode(from: Fixture.data("experiment_result_frequentist.json"))
    }

    @Test("labels itself frequentist and reports a p-value, never a chance to win")
    func methodAndFields() throws {
        let decoded = try result()
        #expect(decoded.method == .frequentist)
        #expect(ExperimentStatsMethod.frequentist.intervalName == "confidence interval")
        let variant = try #require(decoded.variants.first { $0.key == "streamlined" })
        #expect(abs(try #require(variant.pValue) - 0.0438) < 0.000_000_1)
        #expect(variant.chanceToWin == nil)
        let interval = try #require(variant.interval)
        #expect(abs(interval.lowerBound - (-0.0758)) < 0.000_000_1)
        #expect(abs(interval.upperBound - (-0.0142)) < 0.000_000_1)
    }

    @Test("a significant negative result is a loss, not a win")
    func verdictIsLoss() throws {
        let readout = ExperimentReadout(result: try result(), isRunning: true)
        // control mean 9871/4210 = 2.3446, dense 9402/4188 = 2.2450 → −4.2%
        let comparison = try #require(readout.comparisons.first { $0.variantKey == "streamlined" })
        #expect(try #require(comparison.relativeDelta) < 0)
        #expect(readout.verdict == .significantLoss(variant: "streamlined"))
        #expect(readout.verdict.isDecided)
        #expect(readout.verdict.headline == "streamlined is losing")
    }
}

@Suite("Experiment results — degraded states")
struct ExperimentDegradedTests {
    @Test("too few exposures yields no verdict and says why")
    func tooFewExposures() throws {
        let result = try ExperimentMetricResult.decode(
            from: Fixture.data("experiment_result_insufficient.json")
        )
        #expect(result.significanceCode == nil)
        let readout = ExperimentReadout(result: result, isRunning: true)
        #expect(readout.verdict == .tooEarly(.notEnoughExposures))
        #expect(readout.verdict.isDecided == false)
        #expect(readout.verdict.headline == "Too early to call")
        #expect(readout.verdict.explanation.contains("Too few people"))
    }

    @Test("a draft is never described as having no results — it has not run")
    func draftIsNotStarted() {
        let readout = ExperimentReadout(result: nil, isRunning: false)
        #expect(readout.verdict == .notStarted)
        #expect(readout.comparisons.isEmpty)
        #expect(readout.verdict.isDecided == false)
    }

    @Test("a running experiment with nothing back says so, distinctly from a draft")
    func runningWithNoResults() {
        let readout = ExperimentReadout(result: nil, isRunning: true)
        #expect(readout.verdict == .noResults)
        #expect(readout.verdict.headline == "No results yet")
    }

    @Test("non-significant numbers name a leader without calling it a winner")
    func leaderWithoutWin() throws {
        let json = Data("""
        {"significant":false,"significance_code":"low_win_probability",
         "baseline":{"key":"control","number_of_samples":2000,"sum":300.0,"sum_squares":300.0,
                     "validation_failures":[]},
         "variant_results":[{"key":"test","method":"bayesian","number_of_samples":2000,
                     "sum":318.0,"sum_squares":318.0,"chance_to_win":0.71,
                     "credible_interval":[-0.04,0.19],"significant":false,
                     "validation_failures":[]}]}
        """.utf8)
        let readout = ExperimentReadout(
            result: try ExperimentMetricResult.decode(from: json), isRunning: true
        )
        #expect(readout.verdict == .noSignificantDifference(leader: "test"))
        #expect(readout.verdict.isDecided == false)
        #expect(readout.verdict.explanation.contains("not by enough"))
    }

    @Test("a zero baseline mean produces no delta rather than an infinity")
    func zeroBaselineHasNoDelta() throws {
        let json = Data("""
        {"baseline":{"key":"control","number_of_samples":500,"sum":0.0,"sum_squares":0.0,
                     "validation_failures":["baseline-mean-is-zero"]},
         "variant_results":[{"key":"test","method":"bayesian","number_of_samples":500,
                     "sum":12.0,"sum_squares":12.0,"significant":false,
                     "validation_failures":["baseline-mean-is-zero"]}]}
        """.utf8)
        let readout = ExperimentReadout(
            result: try ExperimentMetricResult.decode(from: json), isRunning: true
        )
        #expect(readout.comparisons.first?.relativeDelta == nil)
        #expect(readout.verdict == .tooEarly(.baselineMeanIsZero))
    }

    @Test("an unknown validation-failure string does not throw the readout away")
    func unknownFailureDegrades() throws {
        let json = Data("""
        {"baseline":{"key":"control","number_of_samples":100,"sum":10.0,"sum_squares":10.0,
                     "validation_failures":["some-new-guard"]},
         "variant_results":[{"key":"t","method":"bayesian","number_of_samples":100,
                     "sum":12.0,"sum_squares":12.0,"significant":false,
                     "validation_failures":["some-new-guard"]}]}
        """.utf8)
        let result = try ExperimentMetricResult.decode(from: json)
        #expect(result.variants.first?.validationFailures.isEmpty == true)
        #expect(result.variants.count == 1)
    }

    @Test("a reversed interval pair is normalised instead of trapping")
    func reversedInterval() throws {
        let json = Data("""
        {"key":"t","number_of_samples":10,"sum":1.0,"sum_squares":1.0,
         "credible_interval":[0.4,0.1]}
        """.utf8)
        let variant = try JSONDecoder().decode(ExperimentVariantResult.self, from: json)
        #expect(variant.interval == 0.1...0.4)
    }

    @Test("zero exposures gives no mean rather than a zero")
    func zeroExposuresHasNoMean() throws {
        let json = Data(#"{"key":"t","number_of_samples":0,"sum":0.0,"sum_squares":0.0}"#.utf8)
        let variant = try JSONDecoder().decode(ExperimentVariantResult.self, from: json)
        #expect(variant.mean == nil)
        #expect(variant.isUsable == false)
    }
}

@Suite("Experiment exposures")
struct ExperimentExposureTests {
    private func exposures() throws -> ExperimentExposures {
        try ExperimentExposures.decode(from: Fixture.data("experiment_exposures.json"))
    }

    @Test("decodes totals, the expected split and the per-day curves")
    func decodesExposures() throws {
        let decoded = try exposures()
        #expect(decoded.totals["baseline"] == 8420.7)
        #expect(decoded.totals["streamlined"] == 8376.7)
        #expect(decoded.totalExposures == 16_798.4)
        #expect(decoded.expectedSplit["baseline"] == 0.47)
        #expect(decoded.timeseries.count == 3)
        let baseline = try #require(decoded.timeseries.first { $0.variant == "baseline" })
        #expect(baseline.points.count == 6)
        #expect(baseline.counts.last == 6046)
    }

    @Test("a healthy split is not flagged as a sample ratio mismatch")
    func healthySplit() throws {
        let decoded = try exposures()
        #expect(abs(try #require(decoded.sampleRatioPValue) - 0.6606) < 0.000_000_1)
        #expect(decoded.hasSampleRatioMismatch == false)
        #expect(abs(try #require(decoded.observedSplit["baseline"]) - 0.50131) < 0.0001)
    }

    @Test("a low p-value is flagged, because it invalidates every number above it")
    func mismatchFlagged() throws {
        let json = Data("""
        {"date_range":{},"total_exposures":{"control":5200.0,"test":4100.0},
         "timeseries":[],"sample_ratio_mismatch":{"expected":{"control":0.5,"test":0.5},
         "p_value":0.0004}}
        """.utf8)
        let decoded = try ExperimentExposures.decode(from: json)
        #expect(decoded.hasSampleRatioMismatch)
        #expect(decoded.sampleRatioPValue == 0.0004)
    }

    @Test("no sample-ratio block at all is not a mismatch")
    func absentSRMIsNotAMismatch() throws {
        let json = Data(#"{"date_range":{},"total_exposures":{"a":10.0},"timeseries":[]}"#.utf8)
        let decoded = try ExperimentExposures.decode(from: json)
        #expect(decoded.sampleRatioPValue == nil)
        #expect(decoded.hasSampleRatioMismatch == false)
    }

    @Test("carries the multiple-variant bias share")
    func biasRisk() throws {
        #expect(abs(try #require(exposures().multipleVariantPercentage) - 0.331) < 0.000_000_1)
    }

    @Test("a ragged day/count payload truncates instead of crashing")
    func raggedSeries() throws {
        let json = Data("""
        {"variant":"a","days":["2025-11-26","2025-11-27","2025-11-28"],"exposure_counts":[1.0,2.0]}
        """.utf8)
        let series = try JSONDecoder().decode(ExperimentExposureSeries.self, from: json)
        #expect(series.points.count == 2)
    }
}

@Suite("Experiment endpoints")
struct ExperimentEndpointTests {
    private func detail() throws -> Experiment {
        try JSONDecoder().decode(Experiment.self, from: Fixture.data("experiment_detail_running.json"))
    }

    @Test("builds the detail path")
    func detailPath() {
        let endpoint = PostHogAPI.experiment(projectID: 1_001, experimentID: 4101)
        #expect(endpoint.path == "/api/projects/1001/experiments/4101/")
        #expect(endpoint.method == "GET")
    }

    @Test("results POST to /query/ as an ExperimentQuery carrying the metric exactly")
    func resultEndpoint() throws {
        let metric = try #require(try detail().metrics.first)
        let endpoint = try #require(
            PostHogAPI.experimentResult(projectID: 1_001, experimentID: 4101, metric: metric)
        )
        #expect(endpoint.path == "/api/projects/1001/query/")
        #expect(endpoint.method == "POST")
        #expect(endpoint.category == .query)
        let body = String(decoding: try #require(endpoint.body), as: UTF8.self)
        #expect(body.contains("\"kind\":\"ExperimentQuery\""))
        #expect(body.contains("\"experiment_id\":4101"))
        // The whole funnel definition rides along, not just its type.
        #expect(body.contains("checkout_completed"))
    }

    @Test("a metric with no metric_type yields no request rather than a 400")
    func untypedMetricYieldsNoEndpoint() throws {
        // `metric_type` is the discriminator the server keys `ExperimentQuery.metric`
        // on; sending a metric without one is a guaranteed 400.
        let metric = try JSONDecoder().decode(
            ExperimentMetric.self, from: Data(#"{"kind":"ExperimentMetric","name":"orphan"}"#.utf8)
        )
        #expect(metric.rawType == nil)
        #expect(PostHogAPI.experimentResult(projectID: 1_001, experimentID: 1, metric: metric) == nil)
    }

    @Test("the exposure query echoes the whole flag object, as the schema requires")
    func exposureEndpoint() throws {
        let endpoint = try #require(
            PostHogAPI.experimentExposures(projectID: 1_001, experiment: try detail())
        )
        #expect(endpoint.path == "/api/projects/1001/query/")
        #expect(endpoint.method == "POST")
        let body = String(decoding: try #require(endpoint.body), as: UTF8.self)
        #expect(body.contains("\"kind\":\"ExperimentExposureQuery\""))
        #expect(body.contains("\"experiment_name\":\"Example App onboarding layout\""))
        #expect(body.contains("\"feature_flag\""))
        #expect(body.contains("onboarding-layout"))
        #expect(body.contains("\"exposure_criteria\""))
    }

    @Test("no flag payload means no exposure request rather than a broken one")
    func exposureNeedsFlag() throws {
        let bare = try JSONDecoder().decode(
            Experiment.self, from: Data(#"{"id":1,"name":"x"}"#.utf8)
        )
        #expect(PostHogAPI.experimentExposures(projectID: 1_001, experiment: bare) == nil)
    }

    @Test("dates sent to the query round-trip through the parser that reads them")
    func dateRoundTrip() throws {
        let start = try #require(PostHogDate.parse("2025-11-27T09:00:00.000Z"))
        #expect(PostHogDate.parse(PostHogDate.iso8601(start)) == start)
    }
}
