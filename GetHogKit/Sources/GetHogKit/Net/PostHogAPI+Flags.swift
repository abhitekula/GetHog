import Foundation

/// The one edit GetHog makes to a feature flag's `filters`, expressed as a
/// transformation of the verbatim JSON rather than of a decoded model.
///
/// **Never executed.** Read out of PostHog's `FeatureFlagSerializer`
/// (`validate_filters`, `update`) on master, fetched 2026-07-31, and checked
/// against the live *read* of flag [REMOVED PRIVATE DATA] on the same day. The key available here
/// is read-only; no PATCH in this family has been sent from this machine, so
/// everything below is documentation-derived and the shape of the request is all
/// that this project's tests can establish.
///
/// ## Why this is a JSON transformation and not a model encode
///
/// `filters` is a Django `JSONField`. A PATCH **replaces the whole object**; it
/// does not merge. PostHog strips two legacy keys of its own (`holdout_groups`,
/// `super_groups`) on save and preserves nothing else on the caller's behalf. So
/// every key the client fails to echo is destroyed — and `FlagFilters` is
/// `Decodable`-only and models a strict subset, missing at minimum `payloads`,
/// `early_exit`, `aggregation_group_type_index`, per-group `variant`, per-group
/// `aggregation_group_type_index`, property `group_type_index` and property
/// `cohort_name`. Two of those were present on the one flag read live.
///
/// Widening the model would not fix it. The failure mode is *unknown* keys, and a
/// type cannot enumerate the keys PostHog adds next year. Carrying the bytes can.
///
/// ## The trap that does not announce itself
///
/// `validate_filters` opens with PostHog's own comment — *"For some weird internal
/// REST framework reason this field gets validated on a partial PATCH call, even
/// if filters isn't being updatd"* — and returns `self.instance.filters` whenever
/// `groups` is absent from a PATCH. So `PATCH {"filters": {"multivariate": …}}`
/// answers **200 with the flag unchanged**. It is the `filterGroup` trap's
/// opposite number: that one 400s the moment it carries data, this one succeeds
/// and does nothing. The transformation below can only produce a body containing
/// `groups`, because it starts from a `filters` object that already has one and
/// refuses anything else.
public enum FlagRollout {

    /// PostHog's own bounds, from `validate_filters`.
    ///
    /// The bool check matters and is not paranoia about Swift: server-side,
    /// `isinstance(value, bool)` is tested *before* `int`, because in Python
    /// `True` is an `int` and would otherwise validate as the percentage 1. Swift
    /// cannot express that mistake through this signature, so it is recorded here
    /// rather than guarded against.
    public static let range: ClosedRange<Double> = 0...100

    /// Returns a copy of `filters` with one release-condition group's
    /// `rollout_percentage` replaced, or `nil` when the edit cannot be made
    /// truthfully.
    ///
    /// Every other key in the object — known, unknown, at any depth — is carried
    /// through byte-for-byte, which is the entire point. Only
    /// `groups[index].rollout_percentage` changes.
    ///
    /// `nil` rather than a best effort in four cases, all of which would otherwise
    /// produce a request that reads as if it worked:
    ///
    /// * `filters` is not an object, or has no `groups` **array** — the write
    ///   would be silently ignored by the server (see the type's note).
    /// * `index` is out of range — a rollout applied to a group that does not
    ///   exist is a rollout applied to whichever group happens to be there.
    /// * the percentage is not finite, or is outside 0…100 — PostHog rejects it,
    ///   and rejecting it here means the user is told before a request is spent.
    /// * the group is not an object — nothing else could be true of it, but the
    ///   alternative is replacing whatever it was with one.
    ///
    /// A whole-number percentage is written as such: `.number(25)` encodes as
    /// `25`, not `25.0`, because `JSONEncoder` renders an integral `Double`
    /// without a fraction. PostHog accepts either — the validator asks only for a
    /// finite non-bool number in range — but the flag's own payload reads `0`, and
    /// a body that matches what the server already stores is one less difference
    /// to explain when someone diffs an activity-log entry.
    public static func filters(
        _ filters: JSONValue,
        settingGroup index: Int,
        toPercentage percentage: Double
    ) -> JSONValue? {
        guard case .object(var root) = filters else { return nil }
        guard case .array(var groups)? = root["groups"] else { return nil }
        guard groups.indices.contains(index) else { return nil }
        guard percentage.isFinite, range.contains(percentage) else { return nil }
        guard case .object(var group) = groups[index] else { return nil }

        group["rollout_percentage"] = .number(percentage)
        groups[index] = .object(group)
        root["groups"] = .array(groups)
        return .object(root)
    }
}

public extension PostHogAPI {

    /// Sets one release-condition group's rollout percentage.
    ///
    /// `PATCH /api/projects/:id/feature_flags/:id/` — the same endpoint
    /// `setFlagActive` uses, and the same `.crud` budget.
    ///
    /// Returns `nil` rather than building a request whenever `FlagRollout` cannot
    /// produce a body it can stand behind; the caller shows the reason instead of
    /// spending a request on a 200 that changes nothing. `FeatureFlag.canEditRollout`
    /// is the cheap form of the same question, for deciding whether to offer the
    /// control at all.
    ///
    /// **Sends `version` when the decoded flag had one.** It is read off the raw
    /// body server-side, so omitting it does not fail closed: the conflict check
    /// is skipped entirely and last write wins, while the row's version is bumped
    /// regardless. Sending it turns a silent clobber of a colleague's edit into a
    /// 409 that can be explained — see `PostHogError.editConflict`. A flag decoded
    /// without a version omits it and is back to the old behaviour, which is why
    /// the field is optional here rather than required.
    ///
    /// Needs `feature_flag:write`, and can answer 409 `approval_required` under an
    /// organisation approval policy — in which case the flag did **not** change,
    /// a change request exists, and approvers were notified.
    ///
    /// - Parameters:
    ///   - groupIndex: which release-condition group to change. There is no "the"
    ///     rollout percentage to set — `FeatureFlag.rolloutPercentage` is a `max()`
    ///     across groups — so the caller must name one.
    static func setFlagRollout(
        projectID: Int,
        flag: FeatureFlag,
        groupIndex: Int,
        percentage: Double
    ) -> Endpoint? {
        guard let raw = flag.filtersRaw,
              let mutated = FlagRollout.filters(raw, settingGroup: groupIndex, toPercentage: percentage)
        else { return nil }

        var payload: [String: JSONValue] = ["filters": mutated]
        if let version = flag.version {
            payload["version"] = .number(Double(version))
        }
        guard let body = try? JSONEncoder().encode(JSONValue.object(payload)) else { return nil }

        return Endpoint(
            path: "/api/projects/\(projectID)/feature_flags/\(flag.id)/",
            method: "PATCH",
            body: body,
            category: .crud
        )
    }
}
