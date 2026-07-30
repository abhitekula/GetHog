import Foundation

// Experiment reads.
//
// Measured against this deployment on 2026-07-30, project [REMOVED PRIVATE DATA]:
//
//   GET /api/projects/[REMOVED PRIVATE DATA]/experiments/            → 200, {"count":0,...}
//   GET /api/projects/[REMOVED PRIVATE DATA]/experiments/999999/     → 404 {"detail":"Not found."}
//   GET .../experiments/999999/results/              → 404 {"detail":"Endpoint not found."}
//   GET .../experiments/999999/{timeseries,stats,exposures,secondary_results,metrics}/
//                                                    → 404 {"detail":"Endpoint not found."}
//
// "Not found." is DRF failing to find the *object*; "Endpoint not found." is
// PostHog's handler for an unrouted URL. So the detail route exists and there
// are **no results sub-routes on the experiments viewset at all** on this
// version — results are computed by posting a query node to `/query/`, which is
// what the two builders below do.
//
// `ExperimentQuery` was confirmed reachable: posting `{"kind":"ExperimentQuery"}`
// returns a pydantic 400 naming `metric` as required, and supplying a valid
// metric returns `{"detail":"experiment_id is required"}`. That last error is
// also the wall — with no experiments in the project, no results payload could
// be observed end to end.

public extension PostHogAPI {
    /// One experiment in full.
    ///
    /// Distinct from the list endpoint on purpose: the list uses
    /// `ExperimentBasicSerializer`, which defers `metrics`, `metrics_secondary`
    /// and `saved_metrics` so the index query need not touch the large JSON
    /// columns. Every one of those is required to ask for a result, so the
    /// detail screen has to re-fetch rather than reuse the row it was opened
    /// from.
    static func experiment(projectID: Int, experimentID: Int) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/experiments/\(experimentID)/",
            category: .crud
        )
    }

    /// Results for one metric of one experiment.
    ///
    /// The metric definition is echoed back **verbatim** as it arrived on the
    /// experiment. Rebuilding it from parsed fields would drop conversion
    /// windows, winsorisation bounds and breakdown filters that this build does
    /// not model, and would then compute a different number than PostHog's own
    /// screen shows for the same metric — a silent disagreement being the worst
    /// possible failure for a screen whose entire job is to be trusted.
    ///
    /// Returns `nil` when the metric carries no `metric_type`. That field is the
    /// discriminator `ExperimentQuery.metric` is keyed on, so without it the
    /// server cannot resolve which of the four metric schemas was meant and
    /// answers 400. Declining to build the request keeps that as a stated
    /// "can't render this metric" rather than a failed network call the screen
    /// would have to explain.
    static func experimentResult(
        projectID: Int,
        experimentID: Int,
        metric: ExperimentMetric
    ) -> Endpoint? {
        guard case .object = metric.rawMetric,
              let rawType = metric.rawType, !rawType.isEmpty
        else { return nil }
        let node = JSONValue.object([
            "kind": .string("ExperimentQuery"),
            "experiment_id": .number(Double(experimentID)),
            "metric": metric.rawMetric,
        ])
        guard let body = try? JSONEncoder().encode(JSONValue.object(["query": node])) else {
            return nil
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/query/",
            method: "POST",
            body: body,
            category: .query
        )
    }

    /// Exposure counts and the sample-ratio check.
    ///
    /// `ExperimentExposureQuery` requires `experiment_name` and the whole
    /// `feature_flag` object — not the flag key — which is why `Experiment`
    /// keeps the flag payload verbatim. Returns `nil` without one rather than
    /// sending a request that cannot mean what the caller intended.
    static func experimentExposures(
        projectID: Int,
        experiment: Experiment
    ) -> Endpoint? {
        guard let flag = experiment.featureFlagRaw, case .object = flag else { return nil }
        var node: [String: JSONValue] = [
            "kind": .string("ExperimentExposureQuery"),
            "experiment_id": .number(Double(experiment.id)),
            "experiment_name": .string(experiment.name),
            "feature_flag": flag,
        ]
        if let criteria = experiment.exposureCriteriaRaw, case .object = criteria {
            node["exposure_criteria"] = criteria
        }
        if let start = experiment.startDate {
            node["start_date"] = .string(PostHogDate.iso8601(start))
        }
        if let end = experiment.endDate {
            node["end_date"] = .string(PostHogDate.iso8601(end))
        }
        guard let body = try? JSONEncoder().encode(JSONValue.object(["query": .object(node)])) else {
            return nil
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/query/",
            method: "POST",
            body: body,
            category: .query
        )
    }
}
