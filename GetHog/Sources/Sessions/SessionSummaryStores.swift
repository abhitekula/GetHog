import GetHogKit
import Observation
import Foundation

// MARK: - List

/// Recent Replay Vision summaries emitted as `$recording_observed` events.
///
/// This is the same current data path PostHog's Replay Vision UI uses for
/// summary output. It deliberately has no retired single-session-summary API
/// fallback: an unavailable current query is shown as an error instead.
@MainActor
@Observable
final class SessionSummariesStore {
    static let limit = 50

    private(set) var rows: [ReplayVisionSummaryDigest] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    var frictionOnly = false

    @ObservationIgnored private var requestAuthority: ResourceRequestAuthority?
    @ObservationIgnored private var generation = 0

    func prepare(authority: ResourceRequestAuthority?) {
        guard requestAuthority != authority else { return }
        generation += 1
        requestAuthority = authority
        rows = []
        error = nil
        loadedAt = nil
        isLoading = authority != nil
    }

    func load(client: PostHogClient, authority: ResourceRequestAuthority) async {
        prepare(authority: authority)
        generation += 1
        let token = generation
        isLoading = true
        defer {
            if token == generation, requestAuthority == authority {
                isLoading = false
            }
        }

        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.replayVisionSummaryDigests(
                    projectID: authority.projectID,
                    limit: Self.limit
                )
            )
            guard token == generation, requestAuthority == authority else { return }
            rows = ReplayVisionSummaryDigest.rows(from: response)
            error = nil
            loadedAt = Date()
        } catch {
            guard token == generation, requestAuthority == authority else { return }
            self.error = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

// MARK: - Detail

/// The current Replay Vision summary for one recording.
///
/// Inline scans are asynchronous. The POST returns a scan identity and the
/// observation row can appear a little later, so generation is completed by
/// polling that scanner's observations endpoint on PostHog's three-second
/// cadence. A missing row gets the same 30-second grace as PostHog's web app.
@MainActor
@Observable
final class ReplayVisionSummaryStore {
    typealias PollDelay = @Sendable () async throws -> Void

    enum State: Equatable {
        case idle
        case loading
        case loaded(ReplayVisionObservation)
        case absent
        case generating
        case retryable(ReplayVisionObservation)
        case generationFailed(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var loadedAt: Date?

    @ObservationIgnored private let pollDelay: PollDelay
    @ObservationIgnored private let maximumPollAttempts: Int
    @ObservationIgnored private var requestAuthority: ResourceRequestAuthority?
    private var operationID: UInt = 0
    private var currentObservation: ReplayVisionObservation?

    init(
        maximumPollAttempts: Int = 11,
        pollDelay: @escaping PollDelay = {
            try await Task.sleep(for: .seconds(3))
        }
    ) {
        self.maximumPollAttempts = max(1, maximumPollAttempts)
        self.pollDelay = pollDelay
    }

    var observation: ReplayVisionObservation? { currentObservation }
    var summary: ReplayVisionSummary? { currentObservation?.summary }
    var isLoading: Bool { state == .loading }
    var isGenerating: Bool { state == .generating }

    func prepare(authority: ResourceRequestAuthority?) {
        guard requestAuthority != authority else { return }
        operationID &+= 1
        requestAuthority = authority
        currentObservation = nil
        loadedAt = nil
        state = .idle
    }

    func load(
        client: PostHogClient,
        authority: ResourceRequestAuthority,
        sessionID: String
    ) async {
        prepare(authority: authority)
        guard validate(client: client, authority: authority) else { return }
        guard !isGenerating else { return }
        let token = nextOperationID()
        state = .loading

        do {
            let observation = try await fetchObservation(
                client: client,
                authority: authority,
                sessionID: sessionID
            )
            guard isCurrent(token, authority: authority), !Task.isCancelled else { return }
            if let observation, observation.status.isInFlight {
                currentObservation = observation
                state = .generating
                await poll(
                    client: client,
                    authority: authority,
                    sessionID: sessionID,
                    scannerID: observation.scannerID,
                    token: token,
                    cancelledState: .absent
                )
            } else {
                publish(observation)
            }
        } catch {
            guard isCurrent(token, authority: authority), !Task.isCancelled else { return }
            state = .failed(Self.message(for: error))
        }
    }

    func generate(
        client: PostHogClient,
        authority: ResourceRequestAuthority,
        sessionID: String
    ) async {
        prepare(authority: authority)
        guard validate(client: client, authority: authority) else { return }
        guard !isLoading, !isGenerating, summary == nil else { return }
        let priorState = state
        let token = nextOperationID()
        state = .generating

        do {
            let response: ReplayVisionInlineScanResponse = try await client.send(
                PostHogAPI.generateReplayVisionSummary(
                    projectID: authority.projectID,
                    sessionID: sessionID
                )
            )
            guard isCurrent(token, authority: authority) else { return }
            guard !Task.isCancelled else {
                state = priorState
                return
            }
            if let refusal = Self.refusalMessage(in: response) {
                state = .generationFailed(refusal)
                return
            }
            guard let scannerID = response.scanID else {
                state = .generationFailed(
                    "PostHog didn't identify the Replay Vision scanner it started."
                )
                return
            }
            await poll(
                client: client,
                authority: authority,
                sessionID: sessionID,
                scannerID: scannerID,
                token: token,
                cancelledState: priorState
            )
        } catch {
            guard isCurrent(token, authority: authority) else { return }
            guard !Task.isCancelled else {
                state = priorState
                return
            }
            state = .generationFailed(Self.generationMessage(for: error))
        }
    }

    func retry(
        client: PostHogClient,
        authority: ResourceRequestAuthority,
        sessionID: String
    ) async {
        prepare(authority: authority)
        guard validate(client: client, authority: authority) else { return }
        guard !isLoading, !isGenerating,
              let observation = currentObservation,
              observation.status.isRetryable
        else { return }
        let priorState = state
        let token = nextOperationID()
        state = .generating

        do {
            let _: ReplayVisionRetryResponse = try await client.send(
                PostHogAPI.retryReplayVisionObservation(
                    projectID: authority.projectID,
                    observationID: observation.id
                )
            )
            guard isCurrent(token, authority: authority) else { return }
            guard !Task.isCancelled else {
                state = priorState
                return
            }
            currentObservation = nil
            await poll(
                client: client,
                authority: authority,
                sessionID: sessionID,
                scannerID: observation.scannerID,
                token: token,
                cancelledState: priorState
            )
        } catch {
            guard isCurrent(token, authority: authority) else { return }
            guard !Task.isCancelled else {
                state = priorState
                return
            }
            state = .generationFailed(Self.generationMessage(for: error))
        }
    }

    private func poll(
        client: PostHogClient,
        authority: ResourceRequestAuthority,
        sessionID: String,
        scannerID: String,
        token: UInt,
        cancelledState: State
    ) async {
        for attempt in 0..<maximumPollAttempts {
            guard isCurrent(token, authority: authority) else { return }
            guard !Task.isCancelled else {
                state = cancelledState
                return
            }

            do {
                let observation = try await fetchObservation(
                    client: client,
                    authority: authority,
                    sessionID: sessionID,
                    scannerID: scannerID
                )
                guard isCurrent(token, authority: authority) else { return }
                if let observation {
                    currentObservation = observation
                    if !observation.status.isInFlight {
                        publish(observation)
                        return
                    }
                }
            } catch {
                guard isCurrent(token, authority: authority) else { return }
                state = .generationFailed(Self.generationMessage(for: error))
                return
            }

            guard attempt < maximumPollAttempts - 1 else { break }
            do {
                try await pollDelay()
            } catch {
                guard isCurrent(token, authority: authority) else { return }
                state = cancelledState
                return
            }
        }

        guard isCurrent(token, authority: authority) else { return }
        state = .generationFailed(
            "PostHog is still processing this Replay Vision summary. Try refreshing in a moment."
        )
    }

    private func fetchObservation(
        client: PostHogClient,
        authority: ResourceRequestAuthority,
        sessionID: String,
        scannerID: String? = nil
    ) async throws -> ReplayVisionObservation? {
        let endpoint = if let scannerID {
            PostHogAPI.replayVisionScannerObservations(
                projectID: authority.projectID,
                scannerID: scannerID,
                sessionID: sessionID
            )
        } else {
            PostHogAPI.replayVisionObservations(
                projectID: authority.projectID,
                sessionID: sessionID
            )
        }
        let page: Page<ReplayVisionObservation> = try await client.send(
            endpoint
        )
        return page.results.first(where: \.isSummarizer)
    }

    private func publish(_ observation: ReplayVisionObservation?) {
        currentObservation = observation
        loadedAt = Date()
        guard let observation else {
            state = .absent
            return
        }
        switch observation.status {
        case .succeeded where observation.summary != nil:
            state = .loaded(observation)
        case .failed, .ineligible:
            state = .retryable(observation)
        case .pending, .running:
            state = .generating
        case .succeeded, .unknown:
            state = .failed(
                "PostHog returned a Replay Vision observation without a readable summary."
            )
        }
    }

    private func nextOperationID() -> UInt {
        operationID &+= 1
        return operationID
    }

    private func isCurrent(
        _ token: UInt,
        authority: ResourceRequestAuthority
    ) -> Bool {
        operationID == token && requestAuthority == authority
    }

    private func validate(
        client: PostHogClient,
        authority: ResourceRequestAuthority
    ) -> Bool {
        guard client.region == authority.region else {
            state = .failed("The Replay Vision request no longer matches the active PostHog host.")
            return false
        }
        return true
    }

    private static func refusalMessage(
        in response: ReplayVisionInlineScanResponse
    ) -> String? {
        let outcomes = response.results.map(\.outcome)
        if outcomes.contains(.skippedQuota) {
            return "The Replay Vision quota is exhausted for this billing period."
        }
        if outcomes.contains(.skippedScannerLimit) {
            return "The Replay Vision scanner has reached its credit limit."
        }
        if outcomes.contains(.skippedLimit) {
            return "PostHog is already processing the maximum number of Replay Vision scans. Try again in a few minutes."
        }
        if !outcomes.isEmpty, outcomes.allSatisfy({ $0 == .failed }) {
            return "PostHog couldn't start the Replay Vision summary. Try again in a moment."
        }
        if response.scanID == nil, response.started == 0 {
            return "PostHog didn't start a Replay Vision summary for this session."
        }
        return nil
    }

    private static func generationMessage(for error: Error) -> String {
        if case let .forbidden(missingScope, detail) = error as? PostHogError,
           missingScope == "replay_scanner:write"
                || detail?.contains("replay_scanner:write") == true {
            return "Summary generation needs a personal API key with replay_scanner:write and session_recording:read. Update the key's scopes in PostHog, then try again."
        }
        return message(for: error)
    }

    private static func message(for error: Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}
