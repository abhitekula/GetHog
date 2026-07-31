import GetHogKit
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
        case .notice: Color.secondary
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
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
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
    ///   - writeScope: the scope a 403 here almost certainly means is missing.
    static func message(
        for error: any Error,
        object: String,
        action: String,
        writeScope: String
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
        case .forbidden:
            // A read-scoped key passes every preflight probe the app runs and
            // fails only here, so this is the first moment the user can learn
            // what to tick.
            return WriteOutcomeMessage(
                kind: .failure,
                text: """
                    Couldn't \(action) \(object): your personal API key is missing the \
                    \(writeScope) scope. Add it to the key in PostHog, then try again.
                    """
            )
        case .unauthorized:
            return WriteOutcomeMessage(
                kind: .failure,
                text: "Couldn't \(action) \(object): your API key was rejected. Reconnect in Settings."
            )
        default:
            return WriteOutcomeMessage(
                kind: .failure,
                text: "Couldn't \(action) \(object). \(posthog.localizedDescription)"
            )
        }
    }
}
