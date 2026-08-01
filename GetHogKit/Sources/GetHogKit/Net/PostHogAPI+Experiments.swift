import Foundation

// Experiment reads.
//
// Experiment metadata is read from the viewset. Results and exposures are
// computed by posting the public `ExperimentQuery` and
// `ExperimentExposureQuery` nodes to `/query/`.

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

    // MARK: - Lifecycle (write)
    //
    // The paths, bodies and side effects below follow PostHog's published server
    // contract and documentation. Tests exercise only synthetic endpoints and
    // never mutate a remote project.
    //
    // ## The design problem is the word, not the endpoint
    //
    // There are five actions on this viewset and the English word "stop" maps to
    // at least two of them with completely different blast radii:
    //
    //     end/     freezes the results window. Does NOT touch the feature flag.
    //              Users keep their assigned variants; exposures keep firing.
    //     pause/   calls set_flag_active(flag, False). Nobody sees the variant
    //              any more. The experiment row itself is not written at all.
    //
    // So "stop the experiment" is ambiguous in the direction that matters: one
    // reading changes a production feature flag and the other changes a date. A
    // dialog that does not distinguish them is worse than having no button, which
    // is why `endExperiment` and `pauseExperiment` are separate calls with
    // separate confirmations rather than one `stop(…)` with a parameter.
    //
    // ## Two actions this file will not build
    //
    // `ship_variant/` rewrites the linked flag's variant distribution to 100% for
    // one arm and can prepend a catch-all release condition. `open_cleanup_pr` —
    // an optional field on `end/` — starts a task that opens a draft pull request
    // deleting the flag's code from the experiment's linked GitHub repository,
    // and escalates the token's required scopes to include `task:write` at
    // request time. An API field whose blast radius is a git repository does not
    // belong behind a thumb. Neither is expressible here: there is no builder for
    // the first, and `open_cleanup_pr` is not a parameter of the second, so it
    // cannot be sent by mistake or by a future caller passing `true` through.
    //
    // ## A scope surface worth knowing about
    //
    // `pause/` and `resume/` declare `required_scopes=["experiment:write"]` and
    // then flip a feature flag. Their neighbours escalate — `archive/` to
    // `feature_flag:write` when `disable_feature_flag` is set, `end/` to
    // `task:write` when `open_cleanup_pr` is — so an `experiment:write`-only key
    // can turn a production flag off. Read from the decorators; not probed.

    /// Ends an experiment and records the team's conclusion.
    ///
    /// `POST /api/projects/:id/experiments/:id/end/`. Sets `end_date = now`,
    /// `conclusion` and `conclusion_comment`, and **does not touch the linked
    /// feature flag** — users keep the variant they were assigned and
    /// `$feature_flag_called` keeps firing. Ending an experiment is a statement
    /// about the analysis window, not about what production serves.
    ///
    /// **`conclusion` is required here although the API makes it optional**, and
    /// that is the whole reason this signature is shaped the way it is.
    /// `end_experiment` assigns `experiment.conclusion = conclusion`
    /// *unconditionally*, with the serializer defaulting an absent field to
    /// `None` — so ending an experiment without naming a conclusion writes `null`
    /// over whatever was already recorded. An app that offered "End" as a bare
    /// button would be offering, on some experiments, a button that silently
    /// erases a colleague's written verdict. Making the parameter non-optional
    /// means that request cannot be constructed.
    ///
    /// `conclusion_comment` is sent only when it has content: PostHog accepts a
    /// blank string, and writing `""` where the user typed nothing is the same
    /// unconditional-overwrite problem one field over.
    ///
    /// `open_cleanup_pr` is deliberately absent — see the note above this
    /// section. `EndExperimentSerializer` accepts it; nothing here can produce it.
    ///
    /// Needs `experiment:write`.
    static func endExperiment(
        projectID: Int,
        experimentID: Int,
        conclusion: ExperimentConclusion,
        comment: String? = nil
    ) -> Endpoint {
        var payload: [String: Any] = ["conclusion": conclusion.rawValue]
        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["conclusion_comment"] = comment
        }
        let body = try? JSONSerialization.data(withJSONObject: payload)
        return Endpoint(
            path: "/api/projects/\(projectID)/experiments/\(experimentID)/end/",
            method: "POST",
            body: body,
            category: .crud
        )
    }

    /// Stops serving the experiment's variants by **deactivating its feature
    /// flag**.
    ///
    /// `POST /api/projects/:id/experiments/:id/pause/`. Writes nothing on the
    /// experiment row: the handler calls `set_flag_active(feature_flag, False,
    /// …)` and the experiment's `status` then *derives* as `paused` because
    /// `status_label` reads the flag. That is why `ExperimentStatus.paused`
    /// cannot be PATCHed onto an experiment — it is not a stored value.
    ///
    /// The caller's dialog must say a production feature flag changes. This is
    /// the only experiment action that alters what users are served, and it is
    /// reached by the same English word as `end/`, which alters nothing they can
    /// see.
    ///
    /// Because it goes through `set_flag_active`, it also inherits the flag
    /// serializer's approval gate — so it can answer 409 `approval_required`
    /// rather than doing the thing. See `PostHogError.approvalRequired`.
    static func pauseExperiment(projectID: Int, experimentID: Int) -> Endpoint {
        experimentAction(projectID: projectID, experimentID: experimentID, action: "pause")
    }

    /// Re-activates the experiment's feature flag so variants are served again.
    ///
    /// `POST /api/projects/:id/experiments/:id/resume/`. The exact inverse of
    /// `pause/`, with the same blast radius in the other direction and the same
    /// approval gate.
    static func resumeExperiment(projectID: Int, experimentID: Int) -> Endpoint {
        experimentAction(projectID: projectID, experimentID: experimentID, action: "resume")
    }

    /// The two bodyless actions, built in one place so their method, category and
    /// body cannot drift apart.
    ///
    /// **Sends `{}` rather than no body at all.** Both actions are declared
    /// `request=None` server-side, so an empty body is what they expect; an empty
    /// *dictionary* is also what DRF parses an absent body into, so the two are
    /// equivalent as far as the serializer is concerned. `{}` is sent because
    /// `PostHogClient` only sets `Content-Type: application/json` when there is a
    /// body, and a POST with neither a body nor a content type is the shape most
    /// likely to meet a proxy or a parser that objects. **Which of the two this
    /// deployment prefers has not been measured** — no request in this family has
    /// been sent — so this is a choice made on the safer-looking of two
    /// unverified options, not a finding.
    private static func experimentAction(
        projectID: Int,
        experimentID: Int,
        action: String
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/experiments/\(experimentID)/\(action)/",
            method: "POST",
            body: Data("{}".utf8),
            category: .crud
        )
    }
}
