import Observation
import GetHogKit
import SwiftUI

// MARK: - List

/// The browsable list of stored AI summaries.
///
/// Filtering is **server-side** for every axis the screen offers. `?outcome=`
/// and `?has_exceptions=` are indexed on PostHog's side, so a filter change is
/// one request against the whole project rather than a scan of whichever page
/// this app happens to be holding — which would silently answer "26 failures"
/// with however few of them landed in the first fifty rows.
@MainActor
@Observable
final class SessionSummariesStore {
    static let limit = 50

    private(set) var rows: [SessionSummaryRow] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?

    /// `nil` is "every outcome", which is a different request from any of the
    /// three named ones — not a client-side pass over all of them.
    var outcome: SessionSummaryOutcomeFilter?
    var exceptionsOnly = false

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<SessionSummaryRow> = try await client.send(
                PostHogAPI.sessionSummaries(
                    projectID: projectID,
                    limit: Self.limit,
                    outcome: outcome,
                    // Sent only when switched on: `has_exceptions=false` is a
                    // real filter that would hide every session with an
                    // exception, which is the opposite of what the toggle means
                    // when it is off.
                    hasExceptions: exceptionsOnly ? true : nil
                )
            )
            rows = page.results
            total = page.count
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Detail

/// One session's stored summary.
///
/// Three states rather than two, because "no summary" is not a failure. Most
/// sessions in any project have never been summarised, and the API says so with
/// a clean `404 {"detail":"No stored summary found for this session."}`.
/// Collapsing that into `error` would put a red card on the majority of session
/// screens for a feature behaving exactly as designed.
@MainActor
@Observable
final class SessionSummaryStore {
    private struct Generation {
        let operationID: UInt
        let priorState: State
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded(SessionSummaryDetail)
        /// Nobody has summarised this session. Normal.
        case absent
        case generating
        case generationFailed(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var loadedAt: Date?
    private var operationID: UInt = 0
    private var generation: Generation?

    var detail: SessionSummaryDetail? {
        if case .loaded(let detail) = state { return detail }
        return nil
    }

    var isLoading: Bool { state == .loading }
    var isGenerating: Bool { state == .generating }

    func generate(
        client: PostHogClient,
        projectID: Int,
        sessionID: String
    ) async {
        guard generation == nil, detail == nil, !isLoading else { return }
        let operationID = nextOperationID()
        generation = Generation(operationID: operationID, priorState: state)
        state = .generating
        do {
            _ = try await client.data(
                for: PostHogAPI.generateIndividualSessionSummary(
                    projectID: projectID,
                    sessionID: sessionID
                )
            )
            guard !Task.isCancelled else {
                restoreCancelledGeneration(operationID: operationID)
                return
            }
            await loadGeneratedSummary(
                client: client,
                projectID: projectID,
                sessionID: sessionID,
                operationID: operationID
            )
        } catch {
            guard isCurrentGeneration(operationID) else { return }
            guard !Task.isCancelled else {
                restoreCancelledGeneration(operationID: operationID)
                return
            }
            state = .generationFailed(
                Self.generationFailureMessage(for: error)
            )
            generation = nil
        }
    }

    private static func generationFailureMessage(for error: Error) -> String {
        if case let .forbidden(_, detail) = error as? PostHogError,
           let detail, !detail.isEmpty {
            return detail
        }
        return (error as? PostHogError)?.localizedDescription
            ?? error.localizedDescription
    }

    func load(client: PostHogClient, projectID: Int, sessionID: String) async {
        guard generation == nil else { return }
        let operationID = nextOperationID()
        state = .loading
        do {
            let detail: SessionSummaryDetail = try await client.send(
                PostHogAPI.sessionSummary(projectID: projectID, sessionID: sessionID)
            )
            guard isCurrentOperation(operationID) else { return }
            state = .loaded(detail)
            loadedAt = Date()
        } catch let error as PostHogError where SessionSummaryDetail.isMissingSummary(error) {
            guard isCurrentOperation(operationID) else { return }
            state = .absent
            loadedAt = Date()
        } catch {
            guard isCurrentOperation(operationID) else { return }
            state = .failed(
                (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
            )
        }
    }

    private func loadGeneratedSummary(
        client: PostHogClient,
        projectID: Int,
        sessionID: String,
        operationID: UInt
    ) async {
        do {
            let detail: SessionSummaryDetail = try await client.send(
                PostHogAPI.sessionSummary(projectID: projectID, sessionID: sessionID)
            )
            guard isCurrentGeneration(operationID) else { return }
            guard !Task.isCancelled else {
                restoreCancelledGeneration(operationID: operationID)
                return
            }
            state = .loaded(detail)
            loadedAt = Date()
            generation = nil
        } catch let error as PostHogError where SessionSummaryDetail.isMissingSummary(error) {
            guard isCurrentGeneration(operationID) else { return }
            guard !Task.isCancelled else {
                restoreCancelledGeneration(operationID: operationID)
                return
            }
            state = .absent
            loadedAt = Date()
            generation = nil
        } catch {
            guard isCurrentGeneration(operationID) else { return }
            guard !Task.isCancelled else {
                restoreCancelledGeneration(operationID: operationID)
                return
            }
            state = .failed(
                (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
            )
            generation = nil
        }
    }

    private func nextOperationID() -> UInt {
        operationID &+= 1
        return operationID
    }

    private func isCurrentOperation(_ operationID: UInt) -> Bool {
        self.operationID == operationID
    }

    private func isCurrentGeneration(_ operationID: UInt) -> Bool {
        generation?.operationID == operationID && isCurrentOperation(operationID)
    }

    private func restoreCancelledGeneration(operationID: UInt) {
        guard let generation, generation.operationID == operationID,
              isCurrentOperation(operationID)
        else { return }
        state = generation.priorState
        self.generation = nil
    }
}
