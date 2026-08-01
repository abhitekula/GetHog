import GetHogKit
import SwiftUI

/// Loads everything the detail screen needs to answer "did the test win?".
///
/// PostHog exposes experiment metadata on the detail route and computed numbers
/// through query nodes, so the screen combines:
///
/// 1. the experiment detail, for `metrics` and `stats_config` (the list
///    endpoint's leaner serializer defers both);
/// 2. one `ExperimentExposureQuery`, for exposure counts and the sample-ratio
///    check;
/// 3. one `ExperimentQuery` **per metric** — the query node takes a single
///    `metric`, so N metrics is N requests.
///
/// Metric queries run concurrently but are collected by metric id rather than by
/// arrival, so a slow metric cannot reorder the list under the reader.
@MainActor
@Observable
final class ExperimentResultsStore {
    /// The detail payload, which carries the metric definitions the list lacks.
    private(set) var detail: Experiment?
    private(set) var exposures: ExperimentExposures?
    /// Keyed by `ExperimentMetric.id`.
    private(set) var results: [String: ExperimentMetricResult] = [:]
    /// Metrics whose result request failed, so a row can say so rather than
    /// looking like it is still loading forever.
    private(set) var failedMetrics: Set<String> = []

    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    private(set) var error: String?
    /// Set when exposures specifically failed while metrics succeeded — the
    /// sample-ratio check is then unavailable and must not read as "healthy".
    private(set) var exposuresUnavailable = false

    /// The primary metrics, in the order the API returned them.
    var primaryMetrics: [ExperimentMetric] { detail?.metrics ?? [] }
    var secondaryMetrics: [ExperimentMetric] { detail?.secondaryMetrics ?? [] }

    /// The method actually used, preferring what a result payload states over
    /// what the experiment is configured with. A cached result computed before
    /// the setting changed would otherwise be labelled with statistics that did
    /// not produce it.
    var method: ExperimentStatsMethod? {
        results.values.compactMap(\.method).first ?? detail?.configuredStatsMethod
    }

    /// The headline readout: the first primary metric's, because that is the
    /// metric the experiment was designed around.
    func headlineReadout(for experiment: Experiment) -> ExperimentReadout? {
        guard let first = primaryMetrics.first else { return nil }
        return readout(for: first, experiment: experiment)
    }

    func readout(for metric: ExperimentMetric, experiment: Experiment) -> ExperimentReadout {
        ExperimentReadout(
            result: results[metric.id],
            isRunning: (detail ?? experiment).hasLaunched
        )
    }

    func hasResult(for metric: ExperimentMetric) -> Bool { results[metric.id] != nil }
    func didFail(for metric: ExperimentMetric) -> Bool { failedMetrics.contains(metric.id) }

    func load(client: PostHogClient, projectID: Int, experiment: Experiment) async {
        isLoading = true
        defer { isLoading = false }
        error = nil
        exposuresUnavailable = false

        let loaded: Experiment
        do {
            loaded = try await client.send(
                PostHogAPI.experiment(projectID: projectID, experimentID: experiment.id)
            )
            detail = loaded
        } catch {
            // Without the detail there are no metric definitions, so there is
            // nothing to ask for. The row the sheet was opened from still
            // renders the setup section.
            self.error = message(for: error)
            loadedAt = Date()
            return
        }

        // A draft has never been exposed to anyone. Asking for results would
        // spend two round trips to be told so.
        guard loaded.hasLaunched else {
            results = [:]
            exposures = nil
            failedMetrics = []
            loadedAt = Date()
            return
        }

        async let exposureLoad: Void = loadExposures(client: client, projectID: projectID, experiment: loaded)
        async let metricLoad: Void = loadMetrics(client: client, projectID: projectID, experiment: loaded)
        _ = await (exposureLoad, metricLoad)
        loadedAt = Date()
    }

    private func loadExposures(client: PostHogClient, projectID: Int, experiment: Experiment) async {
        guard let endpoint = PostHogAPI.experimentExposures(projectID: projectID, experiment: experiment) else {
            exposuresUnavailable = true
            return
        }
        do {
            let data = try await client.data(for: endpoint)
            exposures = try ExperimentExposures.decode(from: data)
        } catch {
            exposures = nil
            exposuresUnavailable = true
        }
    }

    private func loadMetrics(client: PostHogClient, projectID: Int, experiment: Experiment) async {
        let metrics = experiment.metrics + experiment.secondaryMetrics
        var collected: [String: ExperimentMetricResult] = [:]
        var failures: Set<String> = []

        await withTaskGroup(of: (String, ExperimentMetricResult?).self) { group in
            for metric in metrics {
                // A metric shape this build cannot interpret gets its own card
                // and no request: spending a query to fetch numbers the screen
                // has already decided it will not draw helps nobody, and the
                // query endpoint is the rate-limited one.
                guard metric.type != nil else {
                    failures.insert(metric.id)
                    continue
                }
                guard let endpoint = PostHogAPI.experimentResult(
                    projectID: projectID, experimentID: experiment.id, metric: metric
                ) else {
                    // No metric_type at all: the request could not be
                    // discriminated by the server. Recorded so the row says so.
                    failures.insert(metric.id)
                    continue
                }
                group.addTask {
                    let data = try? await client.data(for: endpoint)
                    guard let data else { return (metric.id, nil) }
                    return (metric.id, try? ExperimentMetricResult.decode(from: data))
                }
            }
            for await (id, result) in group {
                if let result, result.error == nil {
                    collected[id] = result
                } else {
                    failures.insert(id)
                }
            }
        }
        results = collected
        failedMetrics = failures
    }

    private func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}
