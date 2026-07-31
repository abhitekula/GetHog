import Foundation
import Observation
import GetHogKit

struct AnnotationComposerMessage: Identifiable, Equatable {
    enum Kind { case failure, notice }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// Owns the one write GetHog makes that is easier from a phone than from a
/// desk.
///
/// Every other write in this app is a decision you could equally have made
/// sitting down — flipping a flag, resolving an issue. An annotation is not: it
/// records *when something happened*, and the moments worth recording are
/// disproportionately the ones where nobody is at a desk. "We deployed at 14:05"
/// is worth almost nothing written from memory at 19:00 and a great deal written
/// from a phone at 14:07.
///
/// Modelled on `FlagToggleController` and `ErrorTriageController`, which between
/// them are the app's whole vocabulary for a mutation. The same three
/// commitments hold:
///
/// * Nothing in here asks the user anything. The caller shows the confirmation
///   dialog first, and that dialog names the text, the instant and the scope —
///   see `AnnotationComposerView`.
/// * The row appears the moment the user confirms and is *withdrawn* if the
///   write fails. Rollback is honest because the optimistic row is tagged: it
///   carries a negative id, PostHog's are positive, so removing it can never
///   remove a real annotation.
/// * The server's copy wins as soon as there is one. On success the placeholder
///   is replaced by the decoded response rather than being promoted in place, so
///   the id, the author and the created timestamp on screen are PostHog's and
///   not this app's guesses at them.
///
/// No biometric gate, for `ErrorTriageController`'s reason: `BiometricGate`
/// exists because flipping a flag changes what production serves to users right
/// now. Writing a note changes nothing that runs. Putting Face ID in front of it
/// would train people to authenticate reflexively, which is what makes the gate
/// on the flag screen worth having.
@MainActor
@Observable
final class AnnotationComposer {

    /// The ids this session handed out, most recent first. Only ever negative.
    private var nextPlaceholderID = -1

    private(set) var isSaving = false
    private(set) var message: AnnotationComposerMessage?

    /// Monotonic counters drive `.sensoryFeedback`; two annotations written in a
    /// row must still each produce a tap.
    private(set) var successCount = 0
    private(set) var failureCount = 0

    /// Not a `Capability.writeScope`. Annotations have no `Capability` case of
    /// their own — the screen is gated on `.dashboards`, because annotations
    /// exist to be drawn on insights — and inventing one would change what
    /// onboarding asks every user to tick. Named here so the 403 path can still
    /// say exactly which box to tick.
    let requiredWriteScope = "annotation:write"

    func dismissMessage() { message = nil }

    /// Writes a confirmed annotation, showing it immediately and withdrawing it
    /// if PostHog refuses.
    ///
    /// - Returns: whether the annotation is now on the server. The sheet stays
    ///   open on `false` so the text the user typed is still there to retry with
    ///   — a note lost to a 403 is a note nobody rewrites.
    @discardableResult
    func create(
        content: String,
        dateMarker: Date,
        target: AnnotationTarget,
        store: AnnotationsStore,
        client: PostHogClient,
        projectID: Int
    ) async -> Bool {
        guard !isSaving else { return false }
        message = nil
        isSaving = true
        defer { isSaving = false }

        let placeholderID = nextPlaceholderID
        nextPlaceholderID -= 1

        // `createdAt` is left nil rather than set to `Date()`. It is not what the
        // row shows — `effectiveDate` prefers `dateMarker`, which is the whole
        // point of an annotation — and filling it in would be this app asserting
        // a server timestamp it has not been told. `createdByName` likewise: the
        // byline says nothing until PostHog says who.
        let placeholder = Annotation(
            id: placeholderID,
            content: content,
            dateMarker: dateMarker,
            creationType: .user,
            scope: target.scope
        )
        store.insert(placeholder)

        do {
            let created: Annotation = try await client.send(
                PostHogAPI.createAnnotation(
                    projectID: projectID,
                    content: content,
                    dateMarker: dateMarker,
                    target: target
                )
            )
            store.replace(id: placeholderID, with: created)
            successCount += 1
            return true
        } catch {
            store.remove(id: placeholderID)
            failureCount += 1
            message = failureMessage(for: error)
            return false
        }
    }

    private func failureMessage(for error: any Error) -> AnnotationComposerMessage {
        var text = "Couldn't save the annotation. \(error.localizedDescription)"

        if let posthogError = error as? PostHogError {
            switch posthogError {
            case .forbidden:
                // A read-scoped key passes every preflight probe the app runs and
                // fails only here, so this is the first moment the user can learn
                // what to tick.
                text = """
                    Couldn't save the annotation: your personal API key is missing the \
                    \(requiredWriteScope) scope. Add it to the key in PostHog, then try again.
                    """
            case .unauthorized:
                text = "Couldn't save the annotation: your API key was rejected. Reconnect in Settings."
            case .decoding:
                // The write may well have landed. PostHog answers a create with
                // the created object, so a decode failure means the annotation
                // probably exists and this app could not read it back — which is
                // the one failure where "it wasn't saved" would be the wrong
                // thing to say. The row has already been withdrawn, so a refresh
                // is what settles it.
                text = """
                    The annotation may have been saved — PostHog answered, but not in a shape \
                    this app could read. Pull to refresh to see whether it is there.
                    """
            default:
                text = "Couldn't save the annotation. \(posthogError.localizedDescription)"
            }
        }

        return AnnotationComposerMessage(kind: .failure, text: text)
    }
}
