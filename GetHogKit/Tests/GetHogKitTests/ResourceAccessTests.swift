import Foundation
import Testing

@testable import GetHogKit

/// One classifier for "why can't I see this", shared by every gated screen.
///
/// Replaces two byte-identical enums that two parallel efforts produced for
/// Logs and Tracing. They differed only in their fallback strings.
///
/// The cases matter because the remedies are genuinely different, and a screen
/// that says the wrong one sends someone to the wrong place: editing an API key
/// cannot fix an org role, and nothing at all fixes an endpoint that refuses
/// personal keys as a category.
@Suite("Resource access states")
struct ResourceAccessTests {

    @Test("an org-level denial names the resource, not a scope")
    func deniedResource() {
        let state = ResourceAccessState(
            failure: PostHogError.accessDenied(resource: "tracing"),
            resource: "tracing",
            defaultScope: "query:read"
        )
        #expect(state == .denied(resource: "tracing"))
        #expect(state.isBlocked)
    }

    /// PostHog scrapes the resource out of prose, so it can go missing if the
    /// wording changes. Staying locked beats falling through to a retryable
    /// failure that would never succeed.
    @Test("falls back to the caller's resource name when PostHog omits it")
    func deniedWithoutResource() {
        let state = ResourceAccessState(
            failure: PostHogError.accessDenied(resource: nil),
            resource: "logs",
            defaultScope: "logs:read"
        )
        #expect(state == .denied(resource: "logs"))
    }

    @Test("a missing scope is reported as the scope the user must add")
    func missingScope() {
        let state = ResourceAccessState(
            failure: PostHogError.forbidden(missingScope: "logs:read"),
            resource: "logs",
            defaultScope: "logs:read"
        )
        #expect(state == .missingScope("logs:read"))
    }

    @Test("a payment-required failure is a billing problem, not a permission one")
    func paidPlan() {
        let state = ResourceAccessState(
            failure: PostHogError.paymentRequired("Audit logs requires a paid PostHog plan."),
            resource: "activity_log",
            defaultScope: "activity_log:read"
        )
        guard case .needsPlan(let detail) = state else {
            Issue.record("expected .needsPlan, got \(state)")
            return
        }
        #expect(detail?.contains("paid") == true)
        #expect(state.isBlocked)
    }

    /// Some endpoints contractually reject personal API key access. No scope
    /// grant or plan upgrade fixes that response, so suggesting a key edit would
    /// be misleading.
    @Test("recognises an endpoint that refuses personal API keys outright")
    func personalKeyUnsupported() {
        let state = ResourceAccessState(
            failure: PostHogError.forbidden(
                missingScope: nil,
                detail: "This action does not support personal API key access"
            ),
            resource: "evaluation_runs",
            defaultScope: "evaluations:read"
        )
        #expect(state == .unsupportedForPersonalKeys)
        #expect(state.isBlocked)
    }

    /// Distinct again: `metrics` answers "requires feature flag 'metrics'".
    /// PostHog has to enable it; neither the user nor their admin can.
    @Test("recognises a feature-flagged product")
    func featureFlagged() {
        let state = ResourceAccessState(
            failure: PostHogError.forbidden(
                missingScope: nil,
                detail: "This action requires feature flag 'metrics' to be enabled"
            ),
            resource: "metrics",
            defaultScope: "metrics:read"
        )
        #expect(state == .featureFlagged("metrics"))
        #expect(state.isBlocked)
    }

    @Test("a server error stays retryable rather than looking like a lockout")
    func serverErrorIsNotABlock() {
        let state = ResourceAccessState(
            failure: PostHogError.http(status: 500, detail: "boom"),
            resource: "logs",
            defaultScope: "logs:read"
        )
        guard case .failed = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        // The difference that matters: a blocked screen offers no retry, and
        // offering one for a 500 — or withholding one for a 403 — is the whole
        // point of separating these.
        #expect(!state.isBlocked)
    }

    @Test("no rows is empty, which is not a failure")
    func emptyIsNotFailure() {
        #expect(ResourceAccessState.resolved(rowCount: 0) == .empty)
        #expect(ResourceAccessState.resolved(rowCount: 3) == .loaded)
        #expect(!ResourceAccessState.empty.isBlocked)
    }
}

/// Why a 403's *detail* has to be read rather than assumed.
///
/// `PostHogErrorEnvelope.missingScope` scrapes a scope out of prose, because
/// PostHog does not return one as a structured field. The consequence is easy to
/// state and easy to forget: **`missingScope` is nil precisely when the 403 is
/// not about a scope** — so a caller that substitutes its own guess whenever the
/// scope is missing is at its most specific exactly where it is least applicable.
///
/// Both details below are real, and both are already documented in this
/// repository's README as walls a personal key hits. Neither contains a
/// `scope:verb` pair, so neither can match `/([a-z_]+:(?:read|write))/`. This
/// pins that, so the app-side `WriteForbiddenMessageTests` are testing against a
/// property of the payload rather than against an assumption about it.
@Suite("Forbidden detail parsing")
struct ForbiddenDetailTests {

    private func envelope(detail: String) throws -> PostHogErrorEnvelope {
        let json = try JSONEncoder().encode(["type": "authentication_error", "detail": detail])
        return try JSONDecoder().decode(PostHogErrorEnvelope.self, from: json)
    }

    @Test("a session-auth-only refusal names no scope")
    func personalKeyRefusalHasNoScope() throws {
        let envelope = try envelope(detail: "This action does not support personal API key access")
        #expect(envelope.missingScope == nil)
    }

    @Test("a project-scoped-key refusal names no scope")
    func scopedProjectRefusalHasNoScope() throws {
        let envelope = try envelope(
            detail: "API keys with scoped projects are only supported on project-based endpoints."
        )
        #expect(envelope.missingScope == nil)
    }

    /// The contrast case, so the two above are not passing because the regex is
    /// broken outright.
    @Test("a genuine scope refusal is still read")
    func realScopeIsExtracted() throws {
        let envelope = try envelope(
            detail: "You do not have the feature_flag:write scope for this action."
        )
        #expect(envelope.missingScope == "feature_flag:write")
    }

    /// The classifier the write path now shares with every gated read screen.
    /// A 403 that names no scope but *does* refuse personal keys must not be
    /// answered with the caller's fallback scope.
    @Test("the shared classifier separates a category refusal from a missing scope")
    func classifierSeparatesCategoryRefusal() {
        let refusal = ResourceAccessState(
            failure: PostHogError.forbidden(
                missingScope: nil,
                detail: "This action does not support personal API key access"
            ),
            resource: "feature flag",
            defaultScope: "feature_flag:write"
        )
        #expect(refusal == .unsupportedForPersonalKeys)

        // …while a 403 that really is a scope still resolves to one.
        let scoped = ResourceAccessState(
            failure: PostHogError.forbidden(missingScope: "experiment:write", detail: nil),
            resource: "experiment",
            defaultScope: "feature_flag:write"
        )
        #expect(scoped == .missingScope("experiment:write"))
    }
}
