import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// The console and network panes of the replay screen.
///
/// The kit tests cover parsing in isolation. What is left — and what is not
/// visible from either side alone — is that the panes get their entries from
/// **the same fetch the player already made**, and that the waterfall places a
/// bar where the request actually happened.
@Suite("Replay console and network panes")
struct ReplayDiagnosticsScreenTests {

    /// The demo's replayable session: the one whose snapshots the demo player
    /// boots from.
    private static let replayable = "018f1000-0000-7000-8000-000000000001"

    private func client() -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
    }

    private func recording() async throws -> SessionRecording {
        let page: Page<SessionRecording> = try await client().send(
            PostHogAPI.sessionRecordings(projectID: 1_001)
        )
        return try #require(page.results.first { $0.id == Self.replayable })
    }

    // MARK: - End to end, through the loader

    /// The claim this whole feature rests on: the console and network panes cost
    /// **no extra request**. The loader fetches snapshot blobs to feed the web
    /// player, and both panes are read out of events in those same blobs.
    ///
    /// Asserted by counting the requests the transport saw, which is the only
    /// way to check it that a comment cannot get wrong.
    @Test("both panes are filled by the player's own snapshot fetch, with no extra request")
    @MainActor
    func costsNoExtraRequest() async throws {
        let transport = CountingDemoTransport()
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: transport
        )
        let loader = ReplayLoader()
        await loader.start(client: client, projectID: 1_001, recording: try await recording())

        #expect(loader.availability == .ready)
        #expect(!loader.diagnostics.network.isEmpty)

        // One listing plus the blob ranges the player needed. Nothing else.
        let paths = await transport.paths
        #expect(paths.allSatisfy { $0.contains("/snapshots") })
        #expect(await transport.count == paths.count)
    }

    @Test("the demo session yields one fictional console line and request")
    @MainActor
    func demoSessionDiagnostics() async throws {
        let loader = ReplayLoader()
        await loader.start(client: client(), projectID: 1_001, recording: try await recording())

        let diagnostics = loader.diagnostics
        #expect(diagnostics.console.count == 1)
        #expect(diagnostics.network.count == 1)
        #expect(Set(diagnostics.network.map(\.id)).count == diagnostics.network.count)
        #expect(diagnostics.console.first?.summary == "Dashboard widgets loaded")
        #expect(diagnostics.network.first?.url == "https://app.example.com/api/widgets")

        #expect(diagnostics.capture.status(.console, hasEntries: true) == .captured)
        #expect(diagnostics.capture.status(.network, hasEntries: true) == .captured)
    }

    /// The panes are positioned against the replay's own origin, which is the
    /// first snapshot event and not `start_time`. Same origin the timeline and
    /// the chapter list seek on.
    @Test("request offsets land inside the session the player is showing")
    @MainActor
    func offsetsAreWithinTheSession() async throws {
        let recording = try await recording()
        let loader = ReplayLoader()
        await loader.start(client: client(), projectID: 1_001, recording: recording)

        let origin = try #require(loader.replayStart)
        let duration = try #require(recording.recordingDuration)
        let offsets = loader.diagnostics.network.map { $0.offset(from: origin) }

        // Buffered performance entries predate the recorder, so a few are
        // negative — but nothing may sit past the end of the recording, and
        // nothing may claim to be from before the session existed. Bounded by
        // the recording's own span rather than a chosen number, so this stays
        // true if the demo fixtures are replaced.
        #expect(offsets.allSatisfy { $0 < duration })
        #expect(offsets.allSatisfy { $0 > -duration })
        #expect(offsets.contains { $0 > 0 })
    }

    @Test("asking beyond the one synthetic blob does not refetch it")
    @MainActor
    func rangesDoNotDouble() async throws {
        let loader = ReplayLoader()
        await loader.start(client: client(), projectID: 1_001, recording: try await recording())

        let firstRange = loader.loadedRangeCount
        let before = loader.diagnostics.network.count
        #expect(before == 1)

        loader.ensureCoverage(upTo: 100_000)
        #expect(loader.loadedRangeCount == firstRange)
        #expect(loader.diagnostics.network.count == before)
    }

    @Test("a reset clears the panes so a retry does not double them")
    @MainActor
    func resetClearsDiagnostics() async throws {
        let loader = ReplayLoader()
        await loader.start(client: client(), projectID: 1_001, recording: try await recording())
        #expect(!loader.diagnostics.network.isEmpty)

        loader.reset()
        #expect(loader.diagnostics.network.isEmpty)
        #expect(loader.diagnostics.capture.consoleEnabled == nil)
    }

    // MARK: - Waterfall geometry

    @Test("a bar is placed by when the request happened, not by its position in the list")
    func barPlacement() {
        let scale = WaterfallScale(start: 0, end: 100)

        #expect(scale.bar(at: 0, duration: 10).x == 0)
        #expect(abs(scale.bar(at: 0, duration: 10).width - 0.1) < 0.0001)
        #expect(abs(scale.bar(at: 50, duration: 25).x - 0.5) < 0.0001)
        #expect(abs(scale.bar(at: 50, duration: 25).width - 0.25) < 0.0001)
    }

    /// A 20 ms request in a 20 minute session is 1/60000 of the width. Drawn
    /// truthfully it is invisible — and short failed requests are exactly what
    /// someone opens a waterfall to find.
    @Test("a request too short to draw still gets a visible bar")
    func minimumBarWidth() {
        let scale = WaterfallScale(start: 0, end: 1200)
        #expect(scale.bar(at: 10, duration: 0.02).width == WaterfallScale.minimumBarFraction)
        #expect(scale.bar(at: 10, duration: 0).width == WaterfallScale.minimumBarFraction)
    }

    @Test("the window is clamped so nothing is drawn outside the waterfall")
    func clampsToWindow() {
        let scale = WaterfallScale(start: 0, end: 100)
        #expect(scale.fraction(at: -50) == 0)
        #expect(scale.fraction(at: 500) == 1)
        // A request that outruns the window ends at the right edge rather than
        // overflowing the card.
        #expect(scale.bar(at: 90, duration: 999).width <= 0.1 + 0.0001)
    }

    /// The bars and the playhead rule have to share a coordinate system, or the
    /// rule points at the wrong request.
    @Test("the window covers negative offsets and the whole playable duration")
    func windowCoversEverything() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let early = entry(at: origin.addingTimeInterval(-4), duration: 2)
        let late = entry(at: origin.addingTimeInterval(10), duration: 1)

        let scale = WaterfallScale(entries: [early, late], origin: origin, duration: 300)
        #expect(scale.start == -4)
        #expect(scale.end == 300)
        // Playhead at 150s of a 300s session sits halfway between −4 and 300.
        #expect(abs(scale.fraction(at: 150) - (154.0 / 304.0)) < 0.0001)
    }

    @Test("an empty session still produces a usable scale rather than dividing by zero")
    func emptyScale() {
        let scale = WaterfallScale(entries: [], origin: nil, duration: 0)
        #expect(scale.span > 0)
        #expect(scale.fraction(at: 0).isFinite)
    }

    // MARK: - Filters

    @Test("the network filters split requests the way someone reads them")
    func networkFilters() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let document = entry(at: origin, duration: 1, initiator: "navigation")
        let api = entry(at: origin, duration: 1, method: "POST", status: 200, initiator: "fetch")
        let broken = entry(at: origin, duration: 1, method: "GET", status: 500, initiator: "fetch")
        let asset = entry(at: origin, duration: 1, status: 200, initiator: "script")
        let all = [document, api, broken, asset]

        #expect(all.filter(ReplayNetworkFilter.all.matches).count == 4)
        #expect(all.filter(ReplayNetworkFilter.failed.matches) == [broken])
        #expect(all.filter(ReplayNetworkFilter.api.matches) == [api, broken])
        #expect(all.filter(ReplayNetworkFilter.documents.matches) == [document])
    }

    /// A 304 is not a failure and a request whose status was never reported —
    /// which is every cross-origin timing entry — is not one either.
    @Test("only a 4xx or 5xx counts as failed")
    func failureThreshold() {
        let origin = Date(timeIntervalSince1970: 1_000)
        #expect(!entry(at: origin, duration: 1, status: 304).isFailure)
        #expect(!entry(at: origin, duration: 1, status: nil).isFailure)
        #expect(entry(at: origin, duration: 1, status: 404).isFailure)
        #expect(entry(at: origin, duration: 1, status: 503).isFailure)
    }

    @Test("the console filters map onto the counts the session header already shows")
    func consoleFilters() {
        let entries = [
            console(.error, "boom"),
            console(.warn, "hmm"),
            console(.log, "hello"),
            console(.error, "boom again"),
        ]
        #expect(entries.filter(ReplayConsoleFilter.all.matches).count == 4)
        #expect(entries.filter(ReplayConsoleFilter.errors.matches).count == 2)
        #expect(entries.filter(ReplayConsoleFilter.warnings.matches).count == 1)
        #expect(entries.filter(ReplayConsoleFilter.logs.matches).count == 1)
    }

    // MARK: - Hosts

    /// A row says where it went only when that is news.
    ///
    @Test("the recorded site is the primary host")
    @MainActor
    func primaryHost() async throws {
        let loader = ReplayLoader()
        await loader.start(client: client(), projectID: 1_001, recording: try await recording())

        let entries = loader.diagnostics.network
        let host = try #require(ReplayNetworkHosts.primary(of: entries))
        #expect(host == "app.example.com")
        #expect(entries.allSatisfy { $0.host == host })
    }

    @Test("a third-party request is not the primary host, so its row names it")
    func foreignHostIsDisclosed() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let own = (0..<5).map { entry(at: origin, duration: 1, url: "https://app.example.com/x/\($0)") }
        let third = entry(at: origin, duration: 1, url: "https://example.org/lib.js")

        let host = ReplayNetworkHosts.primary(of: own + [third])
        #expect(host == "app.example.com")
        #expect(third.host != host)
        #expect(third.pathLabel == "/lib.js")
    }

    /// Two hosts with the same count must resolve the same way every time, or
    /// the row labels flip as later chunks arrive.
    @Test("a tie resolves deterministically rather than by dictionary order")
    func primaryHostTieIsStable() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let pair = [
            entry(at: origin, duration: 1, url: "https://bbb.example.com/a"),
            entry(at: origin, duration: 1, url: "https://aaa.example.com/b"),
        ]
        let picks = (0..<20).map { _ in ReplayNetworkHosts.primary(of: pair.shuffled()) }
        #expect(Set(picks).count == 1)
    }

    @Test("an empty list has no primary host rather than an invented one")
    func primaryHostOfNothing() {
        #expect(ReplayNetworkHosts.primary(of: []) == nil)
    }

    // MARK: - Empty states

    /// The whole point of the four-way status. "Nothing was logged" and "nobody
    /// can tell you whether anything was logged" must not be the same sentence,
    /// because the second one is the one a reader has no way to catch.
    @Test("each reason for an empty pane gets wording of its own")
    func noticesAreDistinct() {
        let statuses: [ReplayCaptureStatus] = [.disabled, .enabledButNone, .unknown]
        let console = statuses.map { ReplayCaptureNotice.console($0) }
        let network = statuses.map { ReplayCaptureNotice.network($0) }

        #expect(Set(console.map(\.detail)).count == 3)
        #expect(Set(network.map(\.detail)).count == 3)

        // The unknown case must not claim either fact.
        let unknown = ReplayCaptureNotice.console(.unknown).detail
        #expect(unknown.contains("can't tell"))
        #expect(!unknown.contains("was on"))
        #expect(!unknown.contains("was off"))

        // The two it *can* claim have to say so plainly.
        #expect(ReplayCaptureNotice.console(.disabled).detail.contains("did not load"))
        #expect(ReplayCaptureNotice.console(.enabledButNone).detail.contains("was on"))
    }

    @Test("byte sizes are absent rather than zero when nobody reported one")
    func absentSizes() {
        #expect(ReplayByteFormat.short(nil) == nil)
        #expect(ReplayByteFormat.short(0) != nil)
    }

    @Test("a sub-millisecond request does not render as 0 ms")
    func shortDurations() {
        #expect(ReplayByteFormat.duration(0) == "<1 ms")
        #expect(ReplayByteFormat.duration(0.0004) == "<1 ms")
        #expect(ReplayByteFormat.duration(0.022) == "22 ms")
        #expect(ReplayByteFormat.duration(3.5).hasSuffix("s"))
    }

    // MARK: - Builders

    private func entry(
        at start: Date,
        duration: TimeInterval,
        method: String? = nil,
        status: Int? = nil,
        initiator: String? = nil,
        url: String = "https://example.com/thing"
    ) -> ReplayNetworkEntry {
        ReplayNetworkEntry(
            id: "\(start.timeIntervalSince1970)-\(method ?? "")-\(status ?? 0)-\(initiator ?? "")-\(url)",
            url: url,
            method: method,
            status: status,
            initiator: initiator,
            contentType: nil,
            start: start,
            duration: duration,
            waiting: nil,
            transferSize: nil,
            encodedBodySize: nil,
            decodedBodySize: nil,
            isInitial: false
        )
    }

    private func console(_ level: ReplayConsoleLevel, _ message: String) -> ReplayConsoleEntry {
        ReplayConsoleEntry(
            id: message,
            level: level,
            rawLevel: level.rawValue,
            parts: [message],
            trace: [],
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
    }
}

/// `DemoTransport` with a tally, so "this costs no extra request" is a
/// measurement rather than a claim.
private actor CountingDemoTransport: HTTPTransport {
    private let inner = DemoTransport()
    private(set) var paths: [String] = []

    var count: Int { paths.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        paths.append(request.url?.path ?? "")
        return try await inner.send(request)
    }
}
