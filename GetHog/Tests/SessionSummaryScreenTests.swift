import Foundation
import GetHogKit
import Testing
import UIKit

@testable import GetHog

private actor SummaryGenerationTransport: HTTPTransport {
    private var generated = false
    private var generationStatuses: [Int]
    private let storedSummary = DemoTransport()
    private let holdsFirstGeneration: Bool
    private var generationRequestCount = 0
    private var summaryRequestCount = 0
    private var firstGenerationStarted = false
    private var firstGenerationWaiter: CheckedContinuation<Void, Never>?
    private var firstGenerationGate: CheckedContinuation<Void, Never>?

    init(
        generationStatuses: [Int] = [200],
        holdsFirstGeneration: Bool = false
    ) {
        self.generationStatuses = generationStatuses
        self.holdsFirstGeneration = holdsFirstGeneration
    }

    func waitForFirstGenerationRequest() async {
        guard !firstGenerationStarted else { return }
        await withCheckedContinuation { firstGenerationWaiter = $0 }
    }

    func releaseFirstGeneration() {
        firstGenerationGate?.resume()
        firstGenerationGate = nil
    }

    func requestCounts() -> (generations: Int, summaries: Int) {
        (generationRequestCount, summaryRequestCount)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""

        if request.httpMethod == "POST",
           path.hasSuffix("/create_session_summaries_individually/") {
            generationRequestCount += 1
            if holdsFirstGeneration, generationRequestCount == 1 {
                firstGenerationStarted = true
                firstGenerationWaiter?.resume()
                firstGenerationWaiter = nil
                await withCheckedContinuation { firstGenerationGate = $0 }
            }
            let generationStatus = generationStatuses.count > 1
                ? generationStatuses.removeFirst()
                : (generationStatuses.first ?? 200)
            generated = generationStatus == 200
            let data = generationStatus == 200
                ? Data(#"{}"#.utf8)
                : Data(
                    generationStatus == 429
                        ? #"{"detail":"Synthetic generation rate limit"}"#.utf8
                        : #"{"detail":"Missing session recording read scope"}"#.utf8
                )
            return response(for: request, status: generationStatus, data: data)
        }

        if path.contains("/single_session_summaries/"), !generated {
            summaryRequestCount += 1
            return response(
                for: request,
                status: 404,
                data: Data(
                    #"{"detail":"No stored summary found for this session."}"#.utf8
                )
            )
        }

        if path.contains("/single_session_summaries/") {
            summaryRequestCount += 1
        }
        return try await storedSummary.send(request)
    }

    private func response(
        for request: URLRequest,
        status: Int,
        data: Data
    ) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

/// The session-summary screens, end to end over the demo fixtures.
///
/// The kit tests cover decoding and the chapter join in isolation. What is left
/// — and what is not visible from either side alone — is that the offsets those
/// chapters resolve to are **positions in the replay this app actually plays**.
/// The demo holds one summarised session and its recording, so that claim can be
/// checked rather than assumed.
@Suite("Session summaries")
struct SessionSummaryScreenTests {

    /// The one session in the demo that has a stored summary, and the one whose
    /// snapshots the demo player boots from.
    private static let summarised = "018f1000-0000-7000-8000-000000000001"

    private func client() -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
    }

    // MARK: - Demo routing

    @Test("the demo serves the summaries list rather than an empty page")
    func listResolves() async throws {
        let page: Page<SessionSummaryRow> = try await client().send(
            PostHogAPI.sessionSummaries(projectID: 1_001)
        )
        #expect(page.results.count == 1)
        // The first row is the session the demo player plays, so the whole
        // path — list, summary, replay — is one coherent story.
        #expect(page.results.first?.id == Self.summarised)
        #expect(page.results.allSatisfy { $0.outcome?.succeeded == true })
    }

    /// Three states, not two. A 404 here is the ordinary case — most sessions
    /// were never summarised — and if the store ever collapsed it into `failed`,
    /// the majority of session screens would grow an error card overnight.
    @Test("a session with no summary reads as absent, not as a failure")
    @MainActor
    func missingSummaryIsAbsent() async throws {
        let store = SessionSummaryStore()
        await store.load(
            client: client(),
            projectID: 1_001,
            sessionID: "018f1000-0000-7000-8000-000000000099"
        )
        #expect(store.state == .absent)
        #expect(store.detail == nil)
        // And it counts as loaded, so the screen stamps a freshness date rather
        // than sitting in a spinner for a request that answered perfectly well.
        #expect(store.loadedAt != nil)
    }

    @Test("the summarised session loads its narrative and chapters")
    @MainActor
    func summaryLoads() async throws {
        let store = SessionSummaryStore()
        await store.load(client: client(), projectID: 1_001, sessionID: Self.summarised)

        let detail = try #require(store.detail)
        #expect(detail.id == Self.summarised)
        #expect(detail.outcome?.succeeded == true)
        #expect(detail.chapters.count == 2)
        #expect(detail.sentiment?.frustrationScore == 0.2)
    }

    @Test("generation transitions an absent summary through generating to loaded")
    @MainActor
    func generationLoadsCanonicalSummary() async throws {
        let transport = SummaryGenerationTransport(holdsFirstGeneration: true)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )
        let store = SessionSummaryStore()

        await store.load(client: client, projectID: 1_001, sessionID: Self.summarised)
        #expect(store.state == .absent)

        let generation = Task {
            await store.generate(
                client: client, projectID: 1_001, sessionID: Self.summarised
            )
        }
        await transport.waitForFirstGenerationRequest()
        #expect(store.state == .generating)
        await transport.releaseFirstGeneration()
        await generation.value
        #expect(store.detail?.id == Self.summarised)
        #expect(store.loadedAt != nil)
    }

    @Test("a generation failure remains retryable and distinct from load failure")
    @MainActor
    func generationFailureIsDistinct() async {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: SummaryGenerationTransport(generationStatuses: [403])
        )
        let store = SessionSummaryStore()

        await store.generate(client: client, projectID: 1_001, sessionID: Self.summarised)
        guard case .generationFailed(let message) = store.state else {
            Issue.record("expected a generation-specific failure")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("scope"))
    }

    @Test("a rate limit is reported as generation failure")
    @MainActor
    func generationRateLimitIsVisible() async {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: SummaryGenerationTransport(generationStatuses: [429])
        )
        let store = SessionSummaryStore()

        await store.generate(client: client, projectID: 1_001, sessionID: Self.summarised)
        guard case .generationFailed(let message) = store.state else {
            Issue.record("expected a generation-specific failure")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("rate"))
    }

    @Test("retry can recover a failed generation")
    @MainActor
    func generationRetryLoadsSummary() async {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: SummaryGenerationTransport(generationStatuses: [403, 200])
        )
        let store = SessionSummaryStore()

        await store.generate(client: client, projectID: 1_001, sessionID: Self.summarised)
        guard case .generationFailed = store.state else {
            Issue.record("expected the first generation to fail")
            return
        }

        await store.generate(client: client, projectID: 1_001, sessionID: Self.summarised)
        #expect(store.detail?.id == Self.summarised)
    }

    @Test("generation never replaces an already loaded summary")
    @MainActor
    func loadedSummaryIsPreserved() async throws {
        let store = SessionSummaryStore()
        await store.load(client: client(), projectID: 1_001, sessionID: Self.summarised)
        let existing = try #require(store.detail)

        await store.generate(client: client(), projectID: 1_001, sessionID: Self.summarised)

        #expect(store.detail == existing)
    }

    @Test("a refresh cannot supersede a generation or create a second POST")
    @MainActor
    func refreshCannotDuplicateGeneration() async {
        let transport = SummaryGenerationTransport(holdsFirstGeneration: true)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )
        let store = SessionSummaryStore()

        await store.load(client: client, projectID: 1_001, sessionID: Self.summarised)
        #expect(store.state == .absent)

        let original = Task {
            await store.generate(
                client: client, projectID: 1_001, sessionID: Self.summarised
            )
        }
        await transport.waitForFirstGenerationRequest()

        await store.load(client: client, projectID: 1_001, sessionID: Self.summarised)
        let duplicate = Task {
            await store.generate(
                client: client, projectID: 1_001, sessionID: Self.summarised
            )
        }
        await duplicate.value

        let whileGenerating = await transport.requestCounts()
        #expect(whileGenerating.generations == 1)
        #expect(whileGenerating.summaries == 1)
        #expect(store.state == .generating)

        await transport.releaseFirstGeneration()
        await original.value

        let completed = await transport.requestCounts()
        #expect(completed.generations == 1)
        #expect(completed.summaries == 2)
        #expect(store.detail?.id == Self.summarised)
    }

    @Test("cancelling generation restores its prior absent state")
    @MainActor
    func cancelledGenerationDoesNotReportFailure() async {
        let transport = SummaryGenerationTransport(holdsFirstGeneration: true)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
            transport: transport
        )
        let store = SessionSummaryStore()

        await store.load(client: client, projectID: 1_001, sessionID: Self.summarised)
        #expect(store.state == .absent)

        let generation = Task {
            await store.generate(
                client: client, projectID: 1_001, sessionID: Self.summarised
            )
        }
        await transport.waitForFirstGenerationRequest()
        generation.cancel()
        await transport.releaseFirstGeneration()
        await generation.value

        #expect(store.state == .absent)
        #expect(store.detail == nil)
        let counts = await transport.requestCounts()
        #expect(counts.summaries == 1)
    }

    // MARK: - Chapters as player positions

    /// The claim the whole feature rests on: a chapter is a place in the replay.
    ///
    /// `SessionDetailView` passes `loader.replayStart ?? recording.startTime` as
    /// the origin, and in the demo those two are the same instant — the first
    /// rrweb snapshot's timestamp is exactly the recording's `start_time`. So the
    /// offsets computed here are the ones `ReplayPlayerController.seek(to:)`
    /// receives, and they have to land inside the recording.
    @Test("every chapter seeks to a position inside the recording")
    @MainActor
    func chaptersLandInsideTheRecording() async throws {
        let client = self.client()
        let recording: SessionRecording = try await client.send(
            PostHogAPI.sessionRecording(projectID: 1_001, recordingID: Self.summarised)
        )
        let store = SessionSummaryStore()
        await store.load(client: client, projectID: 1_001, sessionID: Self.summarised)

        let detail = try #require(store.detail)
        let origin = try #require(recording.startTime)
        let duration = try #require(recording.recordingDuration)

        let offsets = detail.chapters.map { $0.startOffset(from: origin) }
        #expect(offsets.allSatisfy { $0 != nil })

        let seconds = offsets.compactMap { $0 }
        #expect(seconds.count == 2)
        for value in seconds {
            #expect(value >= 0)
            // A chapter past the end of the replay would seek to a frame that
            // does not exist and leave the playhead wherever it already was —
            // a control that silently does nothing.
            #expect(value < duration, "chapter at \(value)s is past the \(duration)s recording")
        }
        // Strictly ascending, which is what makes this a table of contents
        // rather than a list of bookmarks.
        #expect(seconds == seconds.sorted())
        #expect(Set(seconds).count == seconds.count)
        // The first chapter is not at zero: sessions begin before anything
        // worth naming happens, and pretending otherwise would seek past it.
        #expect(seconds[0] > 0)
    }

    /// The other half of the claim: the player accepts those positions.
    ///
    /// This drives the exact closure `SessionDetailView` installs —
    /// `player.seek(to: offset, resume: true)` — with each chapter's own offset,
    /// against a controller put into the state the real one reaches when rrweb
    /// reports itself ready. Everything Swift owns in the seek path is exercised;
    /// only the one-line `window.GetHogReplay.seek(…)` call into the web view
    /// is not, and that is the same call the event timeline has always made.
    @Test("the player takes every chapter offset as a playhead position")
    @MainActor
    func playerAcceptsChapterOffsets() async throws {
        let client = self.client()
        let recording: SessionRecording = try await client.send(
            PostHogAPI.sessionRecording(projectID: 1_001, recordingID: Self.summarised)
        )
        let store = SessionSummaryStore()
        await store.load(client: client, projectID: 1_001, sessionID: Self.summarised)
        let detail = try #require(store.detail)

        let player = ReplayPlayerController()
        // The transport ignores every command until rrweb says it is ready,
        // which is why `SessionDetailView` gates the chapter's play button on
        // `player.isReady` rather than offering one that would do nothing.
        #expect(!player.isReady)
        player.seek(to: 42)
        #expect(player.currentTime == 0)

        player.handle(message: ["type": "ready", "totalTime": 3_269_000.0])
        #expect(player.isReady)

        for chapter in detail.chapters {
            let offset = try #require(chapter.startOffset(from: recording.startTime))
            player.seek(to: offset, resume: true)
            #expect(abs(player.currentTime - offset) < 0.001)
        }
    }

    /// The origin matters, and getting it wrong is silent. rrweb counts from its
    /// first snapshot; `milliseconds_since_start` counts from
    /// `session_start_time`. When they differ, every chapter is wrong by the
    /// same amount and the replay simply plays the wrong moment.
    @Test("a later replay origin shifts every chapter by the same amount")
    @MainActor
    func originShiftsEveryChapterEqually() async throws {
        let store = SessionSummaryStore()
        await store.load(client: client(), projectID: 1_001, sessionID: Self.summarised)
        let detail = try #require(store.detail)
        let origin = try #require(detail.startTime)

        let base = detail.chapters.compactMap { $0.startOffset(from: origin) }
        let shifted = detail.chapters.compactMap { $0.startOffset(from: origin.addingTimeInterval(0.25)) }
        #expect(base.count == shifted.count)
        for (a, b) in zip(base, shifted) {
            #expect(abs((a - b) - 0.25) < 0.001)
        }
    }

    // MARK: - Never colour alone

    /// A mistyped symbol renders as nothing at all — no build error, no crash,
    /// just an outcome whose second encoding has quietly vanished. On this screen
    /// that matters twice over: the glyph is what tells a chapter that succeeded
    /// from one that did not without relying on the tint.
    @Test("every symbol these screens name actually resolves")
    func symbolsResolve() {
        let outcomes: [SessionOutcome?] = [
            try? JSONDecoder().decode(SessionOutcome.self, from: Data(#"{"success":true}"#.utf8)),
            try? JSONDecoder().decode(SessionOutcome.self, from: Data(#"{"success":false}"#.utf8)),
            nil,
        ]
        let signals: [SessionSignalKind] = [
            .abandonment, .confusionLoop, .deadClick, .rageClick,
            .repeatedError, .errorCascade, .backtracking, .longPause,
            .unknown("keyboard_smashing"),
        ]
        let symbols = outcomes.map(SessionOutcomeStyle.systemImage)
            + signals.map(\.systemImage)
            + [
                AppTab.sessionSummaries.systemImage,
                "text.append", "text.badge.xmark", "list.number",
                "play.rectangle.on.rectangle", "play.circle", "chevron.right",
                "sparkles.rectangle.stack", "xmark.circle",
                "line.3.horizontal.decrease.circle", "exclamationmark.triangle",
            ]
        for symbol in symbols {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol) is not an SF Symbol")
        }
    }

    /// The three outcomes must be distinguishable by glyph, not only by tint —
    /// two of them sharing a symbol would leave colour carrying the state.
    @Test("each outcome has its own glyph")
    func outcomeGlyphsAreDistinct() throws {
        let succeeded = try JSONDecoder().decode(
            SessionOutcome.self, from: Data(#"{"success":true}"#.utf8)
        )
        let failed = try JSONDecoder().decode(
            SessionOutcome.self, from: Data(#"{"success":false}"#.utf8)
        )
        let glyphs = [succeeded, failed, nil].map(SessionOutcomeStyle.systemImage)
        #expect(Set(glyphs).count == 3)

        // And each one is named in words as well.
        let words = [succeeded, failed, nil].map(SessionOutcomeStyle.title)
        #expect(Set(words).count == 3)
        #expect(words.allSatisfy { !$0.isEmpty })
    }

    /// The band words have to change across the range, or the number is doing
    /// all the work and the meter is decoration.
    @Test("the frustration band reads differently across the range")
    func frustrationBandsAreDistinct() {
        let bands = [0, 0.2, 0.5, 0.9].map(FrustrationBand.title)
        #expect(Set(bands).count == 4)
        #expect(FrustrationBand.title(0) == "None reported")
    }

    // MARK: - Counts

    /// A count the model never reported must not be drawn as a count of nought.
    @Test("a chapter reports only the counts it actually has")
    @MainActor
    func chapterCountsAreNeverInvented() async throws {
        let store = SessionSummaryStore()
        await store.load(client: client(), projectID: 1_001, sessionID: Self.summarised)
        let detail = try #require(store.detail)

        // The demo summary carries `confusion_count: 0` on every chapter — a
        // measured nought — and it must still not be shown, because "0
        // confusions" is noise beside a chapter that is fine.
        #expect(detail.chapters.allSatisfy { chapter in
            !chapter.noteworthyCounts.contains { $0.label.contains("0 ") }
        })
        // One chapter reports difficulty counts; the other measured none.
        #expect(detail.chapters.filter { !$0.noteworthyCounts.isEmpty }.count == 1)
    }
}
