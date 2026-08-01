import Foundation
import Testing

@testable import GetHogKit

/// What the app says when PostHog stops a query for running too long.
///
/// An authored representative 504 detail:
///
///     {"type":"server_error","code":"error","detail":"Query has hit the max
///      execution time before completing. See our docs for how to improve your
///      query performance. You may need to materialize.","attr":null}
///
/// The contract keeps technical advice available for disclosure without using
/// it as the primary user-facing message.
@Suite("Query timeout")
struct QueryTimeoutTests {

    private static let posthogDetail = """
        Query has hit the max execution time before completing. See our docs for \
        how to improve your query performance. You may need to materialize.
        """

    @Test("does not repeat PostHog's advice to the reader")
    func doesNotShoutTheRawDetail() {
        let error = PostHogError.queryTimeout(Self.posthogDetail)
        let message = error.localizedDescription
        #expect(!message.contains("materialize"))
        #expect(!message.lowercased().contains("docs"))
    }

    @Test("says the plain thing that happened")
    func saysWhatHappened() {
        let error = PostHogError.queryTimeout(Self.posthogDetail)
        #expect(!error.localizedDescription.isEmpty)
        #expect(error.localizedDescription.contains("too long"))
    }

    @Test("is retryable, unlike a malformed response")
    func retryable() {
        // A timeout is a transient property of the cluster, not proof that the
        // request itself is permanently invalid.
        #expect(PostHogError.queryTimeout(Self.posthogDetail).isRetryable)
        #expect(!PostHogError.decoding("typeMismatch").isRetryable)
    }

    @Test("keeps the server detail available for disclosure rather than dropping it")
    func keepsDetail() {
        let error = PostHogError.queryTimeout(Self.posthogDetail)
        #expect(error.technicalDetail == Self.posthogDetail)
    }

    @Test("a timeout can describe itself; a decoding failure cannot")
    func readableDescription() {
        // These two must not collapse: both now carry a `technicalDetail`, so
        // "has a detail" can no longer stand in for "its own message is unfit".
        #expect(PostHogError.queryTimeout(nil).hasReadableDescription)
        #expect(!PostHogError.decoding("typeMismatch").hasReadableDescription)
        #expect(PostHogError.unauthorized.hasReadableDescription)
    }

    @Test("recognises the timeout from the response body whatever the status code")
    func recognisesFromBody() {
        // Observed as 504. Keyed on the body as well, because the same condition
        // has no documented status and the message is what identifies it.
        #expect(PostHogError.isQueryTimeout(detail: Self.posthogDetail))
        #expect(!PostHogError.isQueryTimeout(detail: "Queries are a little too busy right now."))
        #expect(!PostHogError.isQueryTimeout(detail: nil))
    }
}
