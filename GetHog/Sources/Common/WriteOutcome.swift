import GetHogKit
import GetHogUI
import SwiftUI

/// The result of one write, in the three shapes a write can actually end in.
///
/// There used to be two of these — `FlagToggleMessage` and `ErrorTriageMessage` —
/// identical but for their names, and adding two more for experiments and surveys
/// would have made four. They are one type now because the third case is the
/// reason: a write can be **filed** rather than applied or rejected, and a
/// per-feature copy of this enum is a per-feature opportunity to forget that and
/// report a pending change request as a failure.
///
/// `ErrorTriageMessage` is the one holdout, deliberately: error-tracking writes do
/// not go through PostHog's approval gate — it decorates the feature-flag
/// serializer — so that controller has no `.filed` path to get wrong, and
/// migrating it would be a rename touching a screen and its tests for no change
/// in behaviour.
struct WriteOutcomeMessage: Identifiable, Equatable {
    enum Kind {
        /// The write was refused, and the object is as it was.
        case failure
        /// The write landed, and there is something worth saying about what
        /// happens next.
        case notice
        /// The write reached PostHog, the object did **not** change, and a change
        /// request now exists that humans have been asked to approve. Neither a
        /// success nor a failure, and the whole reason this enum has three cases.
        case filed
    }

    let id = UUID()
    let kind: Kind
    let text: String

    /// The one message a caller cannot compose from a template, because the
    /// sentence has to *contradict* the branch it is built in — this is produced
    /// inside a `catch`, and nothing about it is a failure.
    ///
    /// Leads with the action and the object so a reader scanning a list of
    /// messages sees which change it is about before reading what happened to it.
    static func filed(_ outcome: ApprovalOutcome, object: String, action: String) -> Self {
        // Only the first character is raised: `action` is a bare verb phrase
        // ("change the rollout for"), and `.capitalized` would title-case every
        // word of it.
        let verb = action.isEmpty ? action : action.prefix(1).uppercased() + action.dropFirst()
        var text = "\(verb) \(object): \(outcome.summary)"
        if let id = outcome.changeRequestID {
            text += " Change request \(id)."
        }
        return WriteOutcomeMessage(kind: .filed, text: text)
    }
}

/// The two names the old message types carried, kept so the flag screen and its
/// tests are not renamed by a change that is about approval handling.
typealias FlagToggleMessage = WriteOutcomeMessage

/// Which credential family a write denial should prescribe for.
///
/// A declined OAuth scope and a missing key scope fail identically (403) but
/// are fixed in opposite places: one is granted in Settings, the other is
/// added to the key in PostHog. Naming the wrong one sends the user to edit
/// something that was never the problem.
enum WriteRemedy: Sendable, Equatable {
    case personalKey
    case oauthCloud
}

/// Maps a client's auth family to the remedy its write denials prescribe.
/// One spelling so the six write paths cannot disagree about the mapping.
func writeRemedy(for client: PostHogClient) -> WriteRemedy {
    client.authenticatesWithOAuth ? .oauthCloud : .personalKey
}

/// Inline outcome of the last write attempt, drawn where the control was.
///
/// One view rather than the two near-identical private ones the flag and triage
/// screens each had, and the difference that made it worth unifying is the middle
/// state: a filed change request is not an error and must not be painted like
/// one, but it is also not a quiet success and must not be painted like that
/// either. It gets its own glyph and its own tint, and — because state must never
/// be carried by colour alone here — its own leading word in the text the caller
/// builds.
struct WriteOutcomeMessageView: View {
    let message: WriteOutcomeMessage
    var onDismiss: () -> Void

    private var symbol: String {
        switch message.kind {
        case .failure: "exclamationmark.triangle.fill"
        case .notice: "info.circle.fill"
        case .filed: "person.badge.clock.fill"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .failure: Theme.Status.critical
        case .notice: Theme.neutralMark
        case .filed: Theme.Status.warningInk
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(message.text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .minimumHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.neutralMark)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.vertical, 2)
    }
}

/// The shared failure/approval translation every lifecycle controller needs.
///
/// Written once because the thing it exists to get right is easy to get wrong in
/// exactly one direction: `PostHogError.approvalRequired` is thrown from a
/// `catch` block, so the natural reading of the code that handles it is "the
/// write failed". It did not. The optimistic state still has to roll back — the
/// object really is unchanged — but what the reader is told is that their change
/// was filed and who has to approve it.
enum WriteFailure {

    /// - Parameters:
    ///   - object: what was being changed, named as the user would name it.
    ///   - action: a bare verb phrase completing "Couldn't …", e.g. `"pause"`.
    ///   - writeScope: the scope this call site *expects* a 403 to be about.
    ///     A fallback, never an assertion — it is used only when PostHog named
    ///     no scope of its own, and is then phrased as a possibility. See the
    ///     `.forbidden` case below for why that distinction is load-bearing.
    static func message(
        for error: any Error,
        object: String,
        action: String,
        writeScope: String,
        remedy: WriteRemedy = .personalKey
    ) -> WriteOutcomeMessage {
        guard let posthog = error as? PostHogError else {
            return WriteOutcomeMessage(
                kind: .failure,
                text: "Couldn't \(action) \(object). \(error.localizedDescription)"
            )
        }

        switch posthog {
        case .approvalRequired(let outcome):
            return .filed(outcome, object: object, action: action)
        case .editConflict(let detail):
            return WriteOutcomeMessage(
                kind: .failure,
                text: """
                    Couldn't \(action) \(object): somebody else changed it while this screen was \
                    open, so nothing was written. Pull to refresh and decide again.\
                    \(detail.map { " PostHog said: \($0)" } ?? "")
                    """
            )
        case .forbidden(let named, let detail):
            // A read-scoped key passes every preflight probe the app runs and
            // fails only here, so this is the first moment the user can learn
            // what to tick — but "add a scope" is only one of the walls a 403
            // can be, and it used to be the only one this helper could say.
            //
            // This case previously matched `.forbidden` binding *nothing*,
            // discarding both associated values and asserting `writeScope`, a
            // constant hardcoded at each call site. That was wrong in the worst
            // available direction: `missingScope` is nil *precisely when* the
            // 403 is not about a scope, so the sentence was most confident
            // exactly where it was least applicable. The two supported 403
            // examples below do not match
            // `PostHogErrorEnvelope.missingScope`'s `/([a-z_]+:(?:read|write))/`,
            // because neither contains a `scope:verb` pair at all:
            //
            //   "This action does not support personal API key access"
            //   "API keys with scoped projects are only supported on
            //    project-based endpoints."
            //
            // `GetHogKit`'s `ForbiddenDetailTests` pins that neither detail
            // yields a scope; `WriteForbiddenMessageTests` pins what this
            // helper says about each of them.
            //
            // Classification is delegated rather than rewritten. `ResourceAccessState`
            // is the kit's existing reader of this exact payload — the only
            // place that knows a "personal API key" detail is a category
            // refusal and a "feature flag" detail is PostHog-side. Sharing that
            // classifier means a new wall understood by the read path is also
            // understood by every write without duplicating the switch. A fifth
            // wall discovered on a read is understood by every write for free,
            // which is the reason not to hand-roll another copy of this
            // switch. Only the *sentences* are write-shaped; `ResourceCopy`'s
            // read phrasing ("re-check") does not fit here.
            let wall = ResourceAccessState(
                failure: posthog,
                resource: object,
                defaultScope: writeScope
            )
            let opener = "Couldn't \(action) \(object)"

            switch wall {
            case .unsupportedForPersonalKeys:
                return WriteOutcomeMessage(
                    kind: .failure,
                    text: """
                        \(opener): PostHog refuses personal API keys on this endpoint, so no \
                        scope and no plan will open it. This has to be done in PostHog itself.
                        """
                )

            case .featureFlagged(let flag):
                return WriteOutcomeMessage(
                    kind: .failure,
                    text: flag.isEmpty
                        ? "\(opener): PostHog has to enable this feature for your organization first."
                        : """
                          \(opener): this is behind the `\(flag)` feature flag. PostHog has to \
                          enable it for your organization — neither a new key nor an admin can.
                          """
                )

            case .missingScope(let scope) where named != nil:
                // PostHog named the scope itself, so this is the one branch
                // entitled to assert one.
                if remedy == .oauthCloud {
                    return WriteOutcomeMessage(
                        kind: .failure,
                        text: """
                            \(opener): PostHog Cloud sign-in didn't include the \(scope) \
                            scope. Grant it in Settings, then try again.
                            """
                    )
                }
                return WriteOutcomeMessage(
                    kind: .failure,
                    text: """
                        \(opener): your personal API key is missing the \(scope) scope. \
                        Add it to the key in PostHog, then try again.
                        """
                )

            default:
                // PostHog named no scope and the detail matched no known wall.
                // Its own sentence is the only true statement available, so it
                // leads; `writeScope` follows as the guess it has always been,
                // marked as a guess. PostHog also applies role-based access
                // control to some objects, whose 403 is about the user's
                // organization role rather than the key — a remedy this app
                // cannot distinguish from here, and would previously have
                // hidden behind "edit your key". **Unverified**: safely producing
                // that permission combination is outside deterministic unit tests.
                let said = detail.map { " PostHog said: \($0)" } ?? ""
                if remedy == .oauthCloud {
                    return WriteOutcomeMessage(
                        kind: .failure,
                        text: """
                            \(opener): PostHog refused the change and didn't say which permission \
                            was missing.\(said) If PostHog Cloud sign-in is missing the \
                            \(writeScope) scope, grant it in Settings; otherwise ask an \
                            organization admin to check your role.
                            """
                    )
                }
                return WriteOutcomeMessage(
                    kind: .failure,
                    text: """
                        \(opener): PostHog refused the change and didn't say which permission \
                        was missing.\(said) If your key is missing the \(writeScope) scope, \
                        adding it may fix this; otherwise ask an organization admin to check \
                        your role.
                        """
                )
            }
        case .unauthorized:
            return WriteOutcomeMessage(
                kind: .failure,
                text: remedy == .oauthCloud
                    ? "Couldn't \(action) \(object): PostHog Cloud sign-in expired. Reconnect in Settings."
                    : "Couldn't \(action) \(object): your API key was rejected. Reconnect in Settings."
            )
        default:
            return WriteOutcomeMessage(
                kind: .failure,
                text: "Couldn't \(action) \(object). \(posthog.localizedDescription)"
            )
        }
    }
}
