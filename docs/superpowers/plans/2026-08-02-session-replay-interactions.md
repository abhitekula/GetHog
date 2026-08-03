# Session Replay Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full-screen replay, on-demand PostHog AI summary generation, semantic key-event markers on the scrubber, and responsive preview scrubbing.

**Architecture:** Keep SwiftUI authoritative for playback controls and use the bundled rrweb player only for rendering. Add a typed generation endpoint and store state machine, derive marker values through a pure model, retain replay events in memory for a short-lived expanded renderer, and drive high-frequency scrub behavior through a deterministic coordinator rather than the large detail view.

**Tech Stack:** Swift 6, SwiftUI, Observation, WebKit/WKWebView, Swift Testing, XCTest/XCUITest, XcodeGen, bundled rrweb-player JavaScript.

## Global Constraints

- `project.yml` remains the project source of truth; run `xcodegen generate` after adding source files.
- Use Swift 6 strict concurrency and four-space indentation.
- Replay assets remain bundled and offline; no runtime script, stylesheet, or page-resource fetches.
- Replay events and AI summaries remain in memory only and are never logged or persisted by GetHog.
- Every committed fixture, test value, screenshot, example, and document remains deterministic and synthetic.
- Use `Theme` and `Theme.Status` colors rather than literal SwiftUI colors.
- Keep the event timeline, console, and network panes usable when replay or summary work fails.
- Do not use `xcrun simctl` or `-derivedDataPath`.
- Report nonzero executed test counts and the final `TEST SUCCEEDED`, not command exit status alone.
- Preserve the existing unrelated worktree edits. Every commit below stages only the paths named in that task.

## File Structure

- `GetHogKit/Sources/GetHogKit/Net/PostHogAPI+SessionSummaries.swift`: read and generation endpoint builders.
- `GetHog/Sources/Sessions/SessionSummaryStores.swift`: stored-summary loading and generation state machine.
- `GetHog/Sources/Sessions/SessionSummaryCard.swift`: absent, generating, failure, and retry presentation.
- `GetHog/Sources/App/DemoTransport.swift`: deterministic, instance-local summary-generation simulation.
- `GetHog/Sources/Player/ReplayTimelineMarkers.swift`: pure marker derivation, active-marker lookup, and marker-track rendering.
- `GetHog/Sources/Player/ReplayScrubCoordinator.swift`: deterministic drag/throttle/buffering policy.
- `GetHog/Sources/Player/ReplayLoader.swift`: in-memory chronological event archive.
- `GetHog/Sources/Player/ExpandedReplayView.swift`: short-lived full-screen renderer and handoff.
- `GetHog/Sources/Player/ReplayPlayerView.swift`: feature integration and compact-player presentation.
- `GetHog/Sources/Sessions/SessionDetailView.swift`: summary generation action and marker data flow.
- `GetHogKit/Tests/GetHogKitTests/SessionSummaryTests.swift`: endpoint contract coverage.
- `GetHog/Tests/SessionSummaryScreenTests.swift`: store state-machine coverage.
- `GetHog/Tests/DemoTransportTests.swift`: deterministic generation-route coverage; edit around the user's existing changes rather than replacing the file.
- `GetHog/Tests/ReplayTimelineMarkerTests.swift`: marker conversion and lookup coverage.
- `GetHog/Tests/ReplayArchiveTests.swift`: archive lifecycle coverage.
- `GetHog/Tests/ReplayScrubCoordinatorTests.swift`: scrub command coverage.
- `GetHogUITests/ReplayInteractionTests.swift`: rendered generation, marker, expansion, close, and playhead-handoff coverage.

---

### Task 1: Build the PAT-compatible individual-summary endpoint

**Files:**
- Modify: `GetHogKit/Sources/GetHogKit/Net/PostHogAPI+SessionSummaries.swift:20-100`
- Test: `GetHogKit/Tests/GetHogKitTests/SessionSummaryTests.swift:366-405`

**Interfaces:**
- Consumes: `Endpoint(path:method:query:body:category:)` and `RateLimitGovernor.Category.query`.
- Produces: `PostHogAPI.generateIndividualSessionSummary(projectID:sessionID:) -> Endpoint`.

- [ ] **Step 1: Add the failing endpoint contract test**

Add this test under `// MARK: - Endpoints`:

```swift
@Test("builds a PAT-compatible individual summary generation request")
func generationEndpoint() throws {
    let sessionID = "018f1000-0000-7000-8000-000000000001"
    let endpoint = PostHogAPI.generateIndividualSessionSummary(
        projectID: 1_001,
        sessionID: sessionID
    )

    #expect(
        endpoint.path
            == "/api/projects/1001/session_summaries/create_session_summaries_individually/"
    )
    #expect(endpoint.method == "POST")
    #expect(endpoint.category == .query)

    let body = try #require(endpoint.body)
    let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object.keys.sorted() == ["session_ids"])
    #expect(object["session_ids"] as? [String] == [sessionID])
}
```

- [ ] **Step 2: Run the test and confirm the missing API fails**

Run:

```bash
swift test --package-path GetHogKit --filter generationEndpoint
```

Expected: compilation fails because `generateIndividualSessionSummary` does not exist.

- [ ] **Step 3: Add the minimal endpoint builder**

Replace the read-only class comment and add this function inside the existing `PostHogAPI` extension:

```swift
/// Starts one server-side, individually persisted replay summary.
///
/// This endpoint accepts a personal API key with `session_recording:read`.
/// Generation performs query and LLM work, so it belongs to the shared query
/// budget rather than the CRUD budget used by stored-summary reads.
static func generateIndividualSessionSummary(
    projectID: Int,
    sessionID: String
) -> Endpoint {
    let body = try? JSONSerialization.data(
        withJSONObject: ["session_ids": [sessionID]]
    )
    return Endpoint(
        path: "/api/projects/\(projectID)/session_summaries/"
            + "create_session_summaries_individually/",
        method: "POST",
        body: body,
        category: .query
    )
}
```

The file comment must state that config is optional server context and that GetHog neither reads nor edits it during generation.

- [ ] **Step 4: Run the endpoint and full summary-model tests**

Run:

```bash
swift test --package-path GetHogKit --filter SessionSummaryTests
```

Expected: the generation contract and existing summary tests pass with a nonzero test count.

- [ ] **Step 5: Commit only the endpoint task**

```bash
git add GetHogKit/Sources/GetHogKit/Net/PostHogAPI+SessionSummaries.swift GetHogKit/Tests/GetHogKitTests/SessionSummaryTests.swift
git diff --cached --check
git commit -m "Add session summary generation endpoint"
```

---

### Task 2: Add summary generation states and card actions

**Files:**
- Modify: `GetHog/Sources/Sessions/SessionSummaryStores.swift:48-104`
- Modify: `GetHog/Sources/Sessions/SessionSummaryCard.swift:66-230`
- Modify: `GetHog/Sources/Sessions/SessionDetailView.swift:1-190`
- Test: `GetHog/Tests/SessionSummaryScreenTests.swift:43-74`

**Interfaces:**
- Consumes: `PostHogAPI.generateIndividualSessionSummary(projectID:sessionID:)` from Task 1.
- Produces: `SessionSummaryStore.State.generating`, `.generationFailed(String)`, `isGenerating`, and `generate(client:projectID:sessionID:) async`; `SessionSummaryCard.onGenerate`.

- [ ] **Step 1: Add a sequenced synthetic transport and failing store tests**

Add this actor below the test suite imports:

```swift
private actor SummaryGenerationTransport: HTTPTransport {
    private var generated = false
    private var generationStatuses: [Int]
    private let storedSummary = DemoTransport()

    init(generationStatuses: [Int] = [200]) {
        self.generationStatuses = generationStatuses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""

        if request.httpMethod == "POST",
           path.hasSuffix("/create_session_summaries_individually/") {
            try? await Task.sleep(for: .milliseconds(30))
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
            return response(
                for: request,
                status: 404,
                data: Data(
                    #"{"detail":"No stored summary found for this session."}"#.utf8
                )
            )
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
```

Add these tests to `SessionSummaryScreenTests`:

```swift
@Test("generation transitions an absent summary through generating to loaded")
@MainActor
func generationLoadsCanonicalSummary() async throws {
    let client = PostHogClient(
        auth: PersonalKeyAuthProvider(key: "synthetic", region: .usCloud),
        transport: SummaryGenerationTransport()
    )
    let store = SessionSummaryStore()

    await store.load(client: client, projectID: 1_001, sessionID: Self.summarised)
    #expect(store.state == .absent)

    let generation = Task {
        await store.generate(
            client: client, projectID: 1_001, sessionID: Self.summarised
        )
    }
    try await Task.sleep(for: .milliseconds(5))
    #expect(store.state == .generating)
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
        return Issue.record("expected a generation-specific failure")
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
        return Issue.record("expected a generation-specific failure")
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
        return Issue.record("expected the first generation to fail")
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
```

- [ ] **Step 2: Run the store tests and verify the new states are missing**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/SessionSummaryScreenTests
```

Expected: compilation fails on `generate` and `generationFailed`.

- [ ] **Step 3: Implement the store state machine**

Change `SessionSummaryStore.State` and add generation:

```swift
enum State: Equatable {
    case idle
    case loading
    case loaded(SessionSummaryDetail)
    case absent
    case generating
    case generationFailed(String)
    case failed(String)
}

var isLoading: Bool { state == .loading }
var isGenerating: Bool { state == .generating }

func generate(
    client: PostHogClient,
    projectID: Int,
    sessionID: String
) async {
    guard state != .generating, detail == nil else { return }
    state = .generating
    do {
        _ = try await client.data(
            for: PostHogAPI.generateIndividualSessionSummary(
                projectID: projectID,
                sessionID: sessionID
            )
        )
        await load(client: client, projectID: projectID, sessionID: sessionID)
    } catch {
        state = .generationFailed(
            (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        )
    }
}
```

Keep the existing 404-to-absent behavior in `load` unchanged.

- [ ] **Step 4: Add the card states and wire the action from the detail screen**

Add `var onGenerate: (() -> Void)?` to `SessionSummaryCard` and render these cases:

```swift
case .absent:
    SectionEmptyState(
        text: "No AI summary has been generated for this session.",
        systemImage: "text.badge.xmark",
        actionTitle: onGenerate == nil ? nil : "Generate AI summary",
        action: onGenerate
    )
case .generating:
    HStack(spacing: Theme.Space.s) {
        ProgressView().controlSize(.small)
        Text("PostHog is generating this session's AI summary…")
            .font(.footnote)
            .foregroundStyle(Theme.Ink.secondary)
    }
case .generationFailed(let message):
    SectionEmptyState(
        text: "Couldn't generate the summary.",
        systemImage: "exclamationmark.triangle",
        detail: message,
        actionTitle: onGenerate == nil ? nil : "Try again",
        action: onGenerate
    )
```

In `SessionDetailView`, add `@State private var summaryGenerationTask: Task<Void, Never>?`, then pass:

```swift
onGenerate: {
    summaryGenerationTask?.cancel()
    summaryGenerationTask = Task { await generateSummary() }
},
onRetry: { Task { await loadSummary() } }
```

and add:

```swift
private func generateSummary() async {
    guard let client = model.client, let projectID = model.projectID else { return }
    await summary.generate(
        client: client,
        projectID: projectID,
        sessionID: recording.id
    )
}
```

Cancel only the client task when the screen leaves; the server endpoint exposes no PAT cancellation operation:

```swift
.onDisappear {
    summaryGenerationTask?.cancel()
    summaryGenerationTask = nil
}
```

The standalone summary-detail caller must either pass `onGenerate: nil` or rely on the default nil value; do not create a second generation path there.

- [ ] **Step 5: Run the focused app tests**

Run the same `xcodebuild` command from Step 2.

Expected: `SessionSummaryScreenTests` executes a nonzero count and passes.

- [ ] **Step 6: Commit only the store and card task**

```bash
git add GetHog/Sources/Sessions/SessionSummaryStores.swift GetHog/Sources/Sessions/SessionSummaryCard.swift GetHog/Sources/Sessions/SessionDetailView.swift GetHog/Tests/SessionSummaryScreenTests.swift
git diff --cached --check
git commit -m "Allow generating session AI summaries"
```

---

### Task 3: Simulate generation deterministically in demo mode

**Files:**
- Modify: `GetHog/Sources/App/DemoTransport.swift:1-170,270-301,995-1018`
- Modify: `GetHog/Tests/DemoTransportTests.swift` around existing session-summary routing tests; preserve the user's current edits.

**Interfaces:**
- Consumes: the Task 1 endpoint and Task 2 store state machine.
- Produces: `DemoTransport(summaryInitiallyAbsent:)`, instance-local `DemoSummaryGenerationState`, and launch environment `GETHOG_DEMO_SUMMARY_GENERATION`.

- [ ] **Step 1: Add a failing end-to-end demo transport test**

Add this test to `DemoTransportTests`:

```swift
@Test("demo summary generation changes one transport from absent to stored")
@MainActor
func demoSummaryGenerationPersistsForTheRun() async {
    let transport = DemoTransport(summaryInitiallyAbsent: true)
    let client = PostHogClient(
        auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
        transport: transport
    )
    let store = SessionSummaryStore()

    await store.load(
        client: client,
        projectID: Self.projectID,
        sessionID: "018f1000-0000-7000-8000-000000000001"
    )
    #expect(store.state == .absent)

    await store.generate(
        client: client,
        projectID: Self.projectID,
        sessionID: "018f1000-0000-7000-8000-000000000001"
    )
    #expect(store.detail?.chapters.count == 2)
}
```

- [ ] **Step 2: Run only the demo generation test and confirm the initializer is missing**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/DemoTransportTests/demoSummaryGenerationPersistsForTheRun
```

Expected: compilation fails because `summaryInitiallyAbsent` does not exist.

- [ ] **Step 3: Add instance-local generation state**

Add this private actor above `DemoTransport`:

```swift
private actor DemoSummaryGenerationState {
    private let startsAbsent: Bool
    private var generated = false

    init(startsAbsent: Bool) {
        self.startsAbsent = startsAbsent
    }

    var shouldReturnMissing: Bool { startsAbsent && !generated }

    func markGenerated() {
        generated = true
    }
}
```

Add to `DemoTransport`:

```swift
static let summaryGenerationEnvironment = "GETHOG_DEMO_SUMMARY_GENERATION"
private let summaryGeneration: DemoSummaryGenerationState

init(
    emptyCollection: EmptyCollection? = nil,
    summaryInitiallyAbsent: Bool? = nil
) {
    self.emptyCollection = emptyCollection ?? ProcessInfo.processInfo.environment[
        Self.emptyCollectionEnvironment
    ].flatMap(EmptyCollection.init(rawValue:))
    let startsAbsent = summaryInitiallyAbsent
        ?? (ProcessInfo.processInfo.environment[Self.summaryGenerationEnvironment] == "1")
    summaryGeneration = DemoSummaryGenerationState(startsAbsent: startsAbsent)
}
```

Before `writeFixture` in `send`, handle only the canonical synthetic session:

```swift
if request.httpMethod == "POST",
   path.hasSuffix("/create_session_summaries_individually/"),
   body.contains(Self.summarisedDemoSession) {
    await summaryGeneration.markGenerated()
    return Self.jsonReply(
        url: request.url!, data: Data(#"{}"#.utf8), status: 200
    )
}

if path.hasSuffix("/single_session_summaries/\(Self.summarisedDemoSession)/"),
   await summaryGeneration.shouldReturnMissing {
    return Self.jsonReply(url: request.url!, data: Self.noStoredSummary, status: 404)
}
```

Extract the repeated `HTTPURLResponse` construction into:

```swift
private static func jsonReply(
    url: URL,
    data: Data,
    status: Int
) -> (Data, HTTPURLResponse) {
    (
        data,
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}
```

Do not add mutable static state. Each test and app launch owns its actor through one transport value.

- [ ] **Step 4: Run the focused demo and summary suites**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/DemoTransportTests -only-testing:GetHogTests/SessionSummaryScreenTests
```

Expected: both suites execute nonzero tests and pass; the normal demo still begins with its existing stored summary.

- [ ] **Step 5: Commit only the demo-generation edits**

Inspect the diff carefully because both files already contain unrelated user edits:

```bash
git diff -- GetHog/Sources/App/DemoTransport.swift GetHog/Tests/DemoTransportTests.swift
git add GetHog/Sources/App/DemoTransport.swift GetHog/Tests/DemoTransportTests.swift
git diff --cached --check
git commit -m "Simulate replay summary generation in demo mode"
```

If the unrelated edits cannot be separated safely at file granularity, use `git add -p` and stage only the summary-generation hunks.

---

### Task 4: Derive and render semantic replay markers

**Files:**
- Create: `GetHog/Sources/Player/ReplayTimelineMarkers.swift`
- Create: `GetHog/Tests/ReplayTimelineMarkerTests.swift`
- Modify: `GetHog/Sources/Player/ReplayPlayerView.swift:681-824`
- Modify: `GetHog/Sources/Sessions/SessionDetailView.swift:25-105`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SessionSummaryDetail.chapters`, `SessionSummaryKeyEvent.timestamp`, `.offset`, `ReplayLoader.replayStart`, and replay duration.
- Produces: `SessionReplayMarker`, `SessionReplayMarker.make(detail:origin:duration:)`, `active(in:at:)`, `previous(in:before:)`, `next(in:after:)`, and `ReplayMarkerTrack`.

- [ ] **Step 1: Add failing marker-model tests**

Create `ReplayTimelineMarkerTests.swift`:

```swift
import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay timeline markers")
struct ReplayTimelineMarkerTests {
    private func detail() async throws -> SessionSummaryDetail {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
        return try await client.send(
            PostHogAPI.sessionSummary(
                projectID: 1_001,
                sessionID: "018f1000-0000-7000-8000-000000000001"
            )
        )
    }

    @Test("maps every timed key event onto the replay clock")
    func mapsKeyEvents() async throws {
        let origin = try #require(PostHogDate.parse("2026-01-15T12:00:00Z"))
        let markers = SessionReplayMarker.make(
            detail: try await detail(), origin: origin, duration: 10
        )

        #expect(markers.map(\.id) == ["event-open", "event-refresh"])
        #expect(markers.map(\.offset) == [0.5, 0.9])
        #expect(markers.map(\.kind) == [.keyAction, .struggle])
        #expect(markers[1].label == "The user pressed the fictional refresh button.")
    }

    @Test("selects the active, previous and next semantic moments")
    func markerNavigation() async throws {
        let origin = try #require(PostHogDate.parse("2026-01-15T12:00:00Z"))
        let markers = SessionReplayMarker.make(
            detail: try await detail(), origin: origin, duration: 10
        )

        #expect(SessionReplayMarker.active(in: markers, at: 0.4) == nil)
        #expect(SessionReplayMarker.active(in: markers, at: 0.7)?.id == "event-open")
        #expect(SessionReplayMarker.active(in: markers, at: 1.0)?.id == "event-refresh")
        #expect(SessionReplayMarker.previous(in: markers, before: 1.0)?.id == "event-open")
        #expect(SessionReplayMarker.next(in: markers, after: 0.5)?.id == "event-refresh")
    }
}
```

Add this decoder-only synthetic edge case to the same file:

```swift
@Test("deduplicates, omits untimed events, and clamps to duration")
func sanitizesMarkerOffsets() throws {
    let detail = try SessionSummaryDetail.decode(from: Data(#"""
        {
          "session_id":"synthetic-session",
          "summary":{
            "segments":[{"index":0,"name":"Synthetic moments"}],
            "key_actions":[{"segment_index":0,"events":[
              {"event_id":"duplicate","description":"Untimed duplicate"},
              {"event_id":"duplicate","description":"Timed duplicate",
               "milliseconds_since_start":1000},
              {"event_id":"past-duration","description":"Past duration",
               "milliseconds_since_start":12000,"exception":"high"},
              {"event_id":"missing-time","description":"No time"}
            ]}]
          }
        }
        """#.utf8))

    let markers = SessionReplayMarker.make(
        detail: detail, origin: nil, duration: 10
    )

    #expect(markers.map(\.id) == ["duplicate", "past-duration"])
    #expect(markers.map(\.offset) == [1, 10])
    #expect(markers.map(\.kind) == [.keyAction, .exception])
    #expect(markers.first?.label == "Timed duplicate")
    #expect(
        SessionReplayMarker.make(detail: nil, origin: nil, duration: 10).isEmpty
    )
}
```

- [ ] **Step 2: Run the new suite and confirm the marker type is missing**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/ReplayTimelineMarkerTests
```

Expected: compilation fails because `SessionReplayMarker` does not exist.

- [ ] **Step 3: Implement the pure marker model**

Create the model at the top of `ReplayTimelineMarkers.swift`:

```swift
import Foundation
import GetHogKit
import SwiftUI

struct SessionReplayMarker: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyAction
        case struggle
        case exception
    }

    let id: String
    let offset: TimeInterval
    let label: String
    let kind: Kind

    static func make(
        detail: SessionSummaryDetail?,
        origin: Date?,
        duration: TimeInterval
    ) -> [Self] {
        guard let detail else { return [] }
        var seen = Set<String>()
        let upperBound = max(0, duration)

        return detail.chapters
            .flatMap(\.events)
            .compactMap { event -> Self? in
                let rawOffset: TimeInterval?
                if let origin, let timestamp = event.timestamp {
                    rawOffset = timestamp.timeIntervalSince(origin)
                } else {
                    rawOffset = event.offset
                }
                guard let rawOffset, rawOffset.isFinite else { return nil }
                guard seen.insert(event.id).inserted else { return nil }
                let label = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let kind: Kind = if event.exception != nil {
                    .exception
                } else if event.confusion == true || event.abandonment == true {
                    .struggle
                } else {
                    .keyAction
                }
                return Self(
                    id: event.id,
                    offset: min(upperBound, max(0, rawOffset)),
                    label: label.isEmpty ? (event.event ?? "Key event") : label,
                    kind: kind
                )
            }
            .sorted { left, right in
                left.offset == right.offset ? left.id < right.id : left.offset < right.offset
            }
    }

    static func active(in markers: [Self], at position: TimeInterval) -> Self? {
        markers.last { $0.offset <= position }
    }

    static func previous(in markers: [Self], before position: TimeInterval) -> Self? {
        markers.last { $0.offset < position - 0.001 }
    }

    static func next(in markers: [Self], after position: TimeInterval) -> Self? {
        markers.first { $0.offset > position + 0.001 }
    }
}
```

- [ ] **Step 4: Run marker-model tests and verify green**

Run the Step 2 command.

Expected: all marker tests pass with a nonzero count.

- [ ] **Step 5: Add the noninteractive marker track and active callout**

In the same file, add:

```swift
struct ReplayMarkerTrack: View {
    let markers: [SessionReplayMarker]
    let duration: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let usableWidth = max(0, proxy.size.width - 28)
            ZStack(alignment: .leading) {
                ForEach(markers) { marker in
                    Capsule()
                        .fill(tint(for: marker.kind))
                        .frame(width: 3, height: 12)
                        .offset(
                            x: 14 + usableWidth * marker.offset / max(duration, 1)
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tint(for kind: SessionReplayMarker.Kind) -> Color {
        switch kind {
        case .keyAction: Theme.accent
        case .struggle: Theme.accentWarm
        case .exception: Theme.Status.critical
        }
    }
}
```

Change `PlayerTransportBar` to accept `var markers: [SessionReplayMarker] = []` and `var positionAccessibilityLabel = "Playback position"`. Put `ReplayMarkerTrack` in a `ZStack` with the slider, use `positionAccessibilityLabel` for the slider label, and show the active marker label above it:

```swift
if let active = SessionReplayMarker.active(
    in: markers,
    at: position.wrappedValue
) {
    Text(active.label)
        .font(.caption2.weight(.medium))
        .lineLimit(2)
        .foregroundStyle(Theme.Ink.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
}
```

Add previous/next key-event accessibility actions to the slider, both calling `onScrubCommitted(marker.offset)` in this task. Include marker count and active label in its accessibility value.

- [ ] **Step 6: Flow markers from the loaded summary into the player**

Add `var summary: SessionSummaryDetail?` to `ReplayPlayerView` and derive:

```swift
private var markers: [SessionReplayMarker] {
    SessionReplayMarker.make(
        detail: summary,
        origin: loader.replayStart ?? recording.startTime,
        duration: duration
    )
}
```

Pass `summary: summary.detail` from `SessionDetailView`, then pass `markers` into `PlayerTransportBar`.

- [ ] **Step 7: Run marker, summary, and layout tests**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/ReplayTimelineMarkerTests -only-testing:GetHogTests/SessionSummaryScreenTests -only-testing:GetHogTests/AccessibilitySizeFitTests
```

Expected: all selected suites execute and pass.

- [ ] **Step 8: Commit the marker slice**

```bash
git add GetHog.xcodeproj/project.pbxproj GetHog/Sources/Player/ReplayTimelineMarkers.swift GetHog/Sources/Player/ReplayPlayerView.swift GetHog/Sources/Sessions/SessionDetailView.swift GetHog/Tests/ReplayTimelineMarkerTests.swift
git diff --cached --check
git commit -m "Mark replay key events on the scrubber"
```

---

### Task 5: Retain an in-memory replay archive

**Files:**
- Modify: `GetHog/Sources/Player/ReplayLoader.swift:45-230`
- Create: `GetHog/Tests/ReplayArchiveTests.swift`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: parsed, sorted `[SnapshotEvent]` batches already produced by `ReplayLoader.loadNextRange()`.
- Produces: `ReplayLoader.archivedEvents: [SnapshotEvent]`, `archivedEventCount: Int`, and archive reset semantics.

- [ ] **Step 1: Add the failing archive lifecycle test**

Create `ReplayArchiveTests.swift`:

```swift
import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay event archive")
struct ReplayArchiveTests {
    @Test("draining player events does not erase the full-screen archive")
    @MainActor
    func drainKeepsArchive() async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
        let recording: SessionRecording = try await client.send(
            PostHogAPI.sessionRecording(
                projectID: 1_001,
                recordingID: "018f1000-0000-7000-8000-000000000001"
            )
        )
        let loader = ReplayLoader()
        await loader.start(client: client, projectID: 1_001, recording: recording)

        let archived = loader.archivedEvents
        #expect(archived.count >= 2)
        #expect(archived.map(\.timestamp) == archived.map(\.timestamp).sorted())
        #expect(loader.drainPending().count == archived.count)
        #expect(loader.archivedEvents == archived)

        loader.reset()
        #expect(loader.archivedEvents.isEmpty)
        #expect(loader.archivedEventCount == 0)
    }
}
```

- [ ] **Step 2: Run the archive test and confirm the API is absent**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/ReplayArchiveTests
```

Expected: compilation fails on `archivedEvents`.

- [ ] **Step 3: Add archive storage without changing the pending queue**

Add:

```swift
private(set) var archivedEvents: [SnapshotEvent] = []
var archivedEventCount: Int { archivedEvents.count }
```

In `ingest`, immediately after sorting:

```swift
archivedEvents.append(contentsOf: sorted)
```

In `reset`:

```swift
archivedEvents.removeAll(keepingCapacity: false)
```

Do not alter `drainPending`; the compact renderer still owns that queue.

- [ ] **Step 4: Run archive and diagnostics tests**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/ReplayArchiveTests -only-testing:GetHogTests/ReplayDiagnosticsScreenTests
```

Expected: both selected suites execute and pass.

- [ ] **Step 5: Commit the archive slice**

```bash
git add GetHog.xcodeproj/project.pbxproj GetHog/Sources/Player/ReplayLoader.swift GetHog/Tests/ReplayArchiveTests.swift
git diff --cached --check
git commit -m "Retain replay events for expanded playback"
```

---

### Task 6: Present and synchronize a full-screen replay

**Files:**
- Create: `GetHog/Sources/Player/ExpandedReplayView.swift`
- Modify: `GetHog/Sources/Player/ReplayPlayerView.swift:330-824`
- Create: `GetHogUITests/ReplayInteractionTests.swift`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ReplayLoader.archivedEvents`, `archivedEventCount`, `SessionReplayMarker`, `ReplayPlayerController.submit`, and `PlayerTransportBar`.
- Produces: `ExpandedReplayView`, compact-to-expanded starting position, expanded archive cursor, and expanded-to-compact dismissal handoff.

- [ ] **Step 1: Add the failing rendered expansion test**

Create `ReplayInteractionTests.swift`:

```swift
import XCTest

final class ReplayInteractionTests: XCTestCase {
    private func launchReadyReplay() -> XCUIApplication {
        let app = DemoLaunch.launch(
            openURL: "gethog://replay/\(DemoLaunch.replaySessionID)"
        )
        let slider = app.sliders["Playback position"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if slider.exists && slider.isEnabled { break }
            DemoLaunch.pause(0.5)
        }
        XCTAssertTrue(slider.exists && slider.isEnabled)
        return app
    }

    func testReplayExpandsAndReturnsItsPlayhead() {
        let app = launchReadyReplay()
        let compact = app.sliders["Playback position"]
        compact.adjust(toNormalizedSliderPosition: 0.2)

        let expand = app.buttons["Expand replay"]
        XCTAssertTrue(DemoLaunch.wait(for: expand))
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        expand.tap()

        let full = app.sliders["Full-screen playback position"]
        XCTAssertTrue(DemoLaunch.wait(for: full, timeout: 120))
        full.adjust(toNormalizedSliderPosition: 0.8)
        let expandedValue = full.value as? String

        let close = app.buttons["Close full-screen replay"]
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()

        XCTAssertTrue(DemoLaunch.wait(for: compact))
        XCTAssertEqual(compact.value as? String, expandedValue)
    }

    func testTappingReplayStageExpandsIt() {
        let app = launchReadyReplay()
        let stage = DemoLaunch.elements(labelled: "Session replay", in: app).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: stage))
        stage.tap()

        XCTAssertTrue(
            DemoLaunch.wait(for: app.sliders["Full-screen playback position"], timeout: 120)
        )
        app.buttons["Close full-screen replay"].tap()
        XCTAssertTrue(DemoLaunch.wait(for: app.sliders["Playback position"]))
    }
}
```

- [ ] **Step 2: Run the UI test and verify the expand control is absent**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogUITests/ReplayInteractionTests/testReplayExpandsAndReturnsItsPlayhead
```

Expected: the test fails because `Expand replay` does not exist.

- [ ] **Step 3: Add expanded renderer state and archive cursor**

Create `ExpandedReplayView.swift` with this public shape:

```swift
import GetHogKit
import SwiftUI

struct ExpandedReplayView: View {
    let recording: SessionRecording
    let loader: ReplayLoader
    let initialPosition: TimeInterval
    let initialSpeed: Double
    let markers: [SessionReplayMarker]
    let onClose: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = ReplayPlayerController()
    @State private var archiveCursor = 0
    @State private var didRestorePosition = false
    @State private var didClose = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.m) {
                if let failure = controller.failure {
                    SectionEmptyState(
                        text: "Couldn't display the expanded replay.",
                        systemImage: "play.slash",
                        detail: failure
                    )
                    .padding(Theme.Space.l)
                } else {
                    WKWebViewRepresentable(controller: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .accessibilityRepresentation {
                            Rectangle().accessibilityLabel("Full-screen session replay")
                        }
                }

                PlayerTransportBar(
                    controller: controller,
                    duration: duration,
                    buffered: loader.bufferedSeconds,
                    markers: markers,
                    positionAccessibilityLabel: "Full-screen playback position",
                    onScrubCommitted: { controller.seek(to: $0) }
                )
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.cardBackground)
            }
            .background(Theme.cardBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { close() }
                        .accessibilityLabel("Close full-screen replay")
                }
            }
            .onChange(of: controller.isDocumentReady, initial: true) { _, _ in
                feedArchive()
            }
            .onChange(of: loader.archivedEventCount) { _, _ in
                feedArchive()
            }
            .onChange(of: controller.isReady) { _, ready in
                guard ready, !didRestorePosition else { return }
                didRestorePosition = true
                controller.setSpeed(initialSpeed)
                controller.seek(to: initialPosition, resume: false)
            }
        }
        .interactiveDismissDisabled()
        .onDisappear { finishOnce() }
    }
}
```

Implement `duration`, `feedArchive`, and `close` exactly as follows:

```swift
private var duration: TimeInterval {
    max(recording.recordingDuration ?? 0, controller.playerDuration)
}

private func feedArchive() {
    guard controller.isDocumentReady,
          archiveCursor < loader.archivedEvents.count
    else { return }
    let events = Array(loader.archivedEvents[archiveCursor...])
    archiveCursor = loader.archivedEvents.count
    controller.submit(events: events, reduceMotion: reduceMotion, colorScheme: colorScheme)
}

private func close() {
    finishOnce()
    dismiss()
}

private func finishOnce() {
    guard !didClose else { return }
    didClose = true
    onClose(controller.currentTime)
}
```

Do not persist the archive or current frame.

- [ ] **Step 4: Add expansion and compact-player handoff**

In `ReplayPlayerView`, add state for presentation, original play state, and returned position. Add an expand button to the header:

```swift
Button {
    expand()
} label: {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
        .minimumHitTarget()
}
.disabled(!controller.isReady)
.accessibilityLabel("Expand replay")
```

Add a tap gesture to the stage and make its accessibility representation a `Button` with the hint "Opens the replay full screen." Both call the same `expand()` function.

Present:

```swift
.fullScreenCover(isPresented: $isExpanded) {
    ExpandedReplayView(
        recording: recording,
        loader: loader,
        initialPosition: expandedStartPosition,
        initialSpeed: controller.speed,
        markers: markers,
        onClose: { expandedEndPosition = $0 }
    )
}
.onChange(of: isExpanded) { wasExpanded, expanded in
    guard wasExpanded, !expanded else { return }
    controller.seek(to: expandedEndPosition, resume: resumeAfterExpansion)
}
```

`expand()` captures `controller.currentTime` and `controller.isPlaying`, pauses the compact controller, then presents. The compact player must not be recreated.

- [ ] **Step 5: Run focused UI and accessibility tests**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogUITests/ReplayInteractionTests -only-testing:GetHogUITests/ReplayStageAccessibilityTests -only-testing:GetHogUITests/HitTargetTests/testReplayTransportSkipButtons
```

Expected: all selected tests pass; inspect output for a nonzero executed count and `TEST SUCCEEDED`.

- [ ] **Step 6: Commit the full-screen slice**

```bash
git add GetHog.xcodeproj/project.pbxproj GetHog/Sources/Player/ExpandedReplayView.swift GetHog/Sources/Player/ReplayPlayerView.swift GetHogUITests/ReplayInteractionTests.swift
git diff --cached --check
git commit -m "Expand session replays full screen"
```

---

### Task 7: Make scrubbing preview promptly and buffer during drag

**Files:**
- Create: `GetHog/Sources/Player/ReplayScrubCoordinator.swift`
- Create: `GetHog/Tests/ReplayScrubCoordinatorTests.swift`
- Modify: `GetHog/Sources/Player/ReplayPlayerView.swift:35-250,390-420,650-824`
- Modify: `GetHog/Sources/Player/ExpandedReplayView.swift`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: controller seek/pause APIs and loader `ensureCoverage(upTo:)`.
- Produces: `ReplayScrubCoordinator`, `ReplayScrubUpdate`, `ReplayScrubCommit`, throttled previews, immediate coverage requests, and exact pending-target completion.

- [ ] **Step 1: Add failing deterministic scrub-policy tests**

Create `ReplayScrubCoordinatorTests.swift`:

```swift
import Testing

@testable import GetHog

@Suite("Replay scrub coordination")
struct ReplayScrubCoordinatorTests {
    @Test("a drag pauses once, previews at 120ms, and requests remote coverage immediately")
    func previewAndCoverage() {
        var scrub = ReplayScrubCoordinator()
        #expect(scrub.begin(isPlaying: true) == true)

        let first = scrub.update(position: 10, buffered: 30, now: 0)
        #expect(first.previewPosition == 10)
        #expect(first.coverageTarget == nil)

        let throttled = scrub.update(position: 12, buffered: 30, now: 0.05)
        #expect(throttled.previewPosition == nil)

        let next = scrub.update(position: 14, buffered: 30, now: 0.12)
        #expect(next.previewPosition == 14)

        let remote = scrub.update(position: 90, buffered: 30, now: 0.13)
        #expect(remote.previewPosition == nil)
        #expect(remote.coverageTarget == 90)
    }

    @Test("a remote commit waits for coverage and preserves prior playback")
    func pendingCommit() {
        var scrub = ReplayScrubCoordinator()
        _ = scrub.begin(isPlaying: true)

        #expect(scrub.end(position: 90, buffered: 30) == .waiting(target: 90))
        #expect(scrub.coverageAdvanced(to: 89) == nil)
        #expect(scrub.coverageAdvanced(to: 90) == .seek(target: 90, resume: true))
    }

    @Test("a new drag replaces an older pending target")
    func replacesPendingTarget() {
        var scrub = ReplayScrubCoordinator()
        _ = scrub.begin(isPlaying: false)
        _ = scrub.end(position: 90, buffered: 30)

        _ = scrub.begin(isPlaying: false)
        #expect(scrub.end(position: 50, buffered: 30) == .waiting(target: 50))
        #expect(scrub.coverageAdvanced(to: 50) == .seek(target: 50, resume: false))
    }
}
```

- [ ] **Step 2: Run the scrub tests and confirm the policy is missing**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/ReplayScrubCoordinatorTests
```

Expected: compilation fails because the coordinator types do not exist.

- [ ] **Step 3: Implement the pure scrub policy**

Create `ReplayScrubCoordinator.swift`:

```swift
import Foundation

struct ReplayScrubUpdate: Equatable {
    let previewPosition: TimeInterval?
    let coverageTarget: TimeInterval?
}

enum ReplayScrubCommit: Equatable {
    case waiting(target: TimeInterval)
    case seek(target: TimeInterval, resume: Bool)
}

struct ReplayScrubCoordinator {
    static let previewInterval: TimeInterval = 0.12

    private var resumeAfterCommit = false
    private var lastPreviewAt: TimeInterval?
    private(set) var pendingTarget: TimeInterval?

    mutating func begin(isPlaying: Bool) -> Bool {
        resumeAfterCommit = isPlaying
        lastPreviewAt = nil
        pendingTarget = nil
        return isPlaying
    }

    mutating func update(
        position: TimeInterval,
        buffered: TimeInterval,
        now: TimeInterval
    ) -> ReplayScrubUpdate {
        guard position <= buffered else {
            return ReplayScrubUpdate(
                previewPosition: nil,
                coverageTarget: position
            )
        }
        let canPreview = lastPreviewAt.map {
            now - $0 >= Self.previewInterval
        } ?? true
        if canPreview { lastPreviewAt = now }
        return ReplayScrubUpdate(
            previewPosition: canPreview ? position : nil,
            coverageTarget: nil
        )
    }

    mutating func end(
        position: TimeInterval,
        buffered: TimeInterval
    ) -> ReplayScrubCommit {
        if position > buffered {
            pendingTarget = position
            return .waiting(target: position)
        }
        pendingTarget = nil
        return .seek(target: position, resume: resumeAfterCommit)
    }

    mutating func coverageAdvanced(to buffered: TimeInterval) -> ReplayScrubCommit? {
        guard let pendingTarget, buffered >= pendingTarget else { return nil }
        self.pendingTarget = nil
        return .seek(target: pendingTarget, resume: resumeAfterCommit)
    }
}
```

- [ ] **Step 4: Run scrub-policy tests and verify green**

Run the Step 2 command.

Expected: all three tests pass.

- [ ] **Step 5: Move high-frequency thumb state into `PlayerTransportBar`**

Remove `scrubPosition` from `ReplayPlayerController`. Keep only:

```swift
@ObservationIgnored var isScrubbing = false
```

In `PlayerTransportBar`, add local state:

```swift
@State private var scrub = ReplayScrubCoordinator()
@State private var scrubPosition: TimeInterval = 0
@State private var isEditing = false
```

Change the bar's closures to:

```swift
let onPreviewSeek: (TimeInterval) -> Void
let onCoverageRequested: (TimeInterval) -> Void
let onScrubCommitted: (TimeInterval, Bool) -> Void
let onMarkerSeek: (TimeInterval) -> Void
```

Implement the high-frequency path inside `PlayerTransportBar`, rather than mutating observable controller position on every drag sample:

```swift
private var position: Binding<Double> {
    Binding(
        get: {
            isEditing || scrub.pendingTarget != nil
                ? scrubPosition
                : controller.currentTime
        },
        set: { target in
            scrubPosition = target
            guard isEditing else { return }
            let update = scrub.update(
                position: target,
                buffered: buffered,
                now: ProcessInfo.processInfo.systemUptime
            )
            if let preview = update.previewPosition {
                onPreviewSeek(preview)
            }
            if let coverage = update.coverageTarget {
                onCoverageRequested(coverage)
            }
        }
    )
}

private func editingChanged(_ editing: Bool) {
    if editing {
        isEditing = true
        scrubPosition = controller.currentTime
        controller.isScrubbing = true
        if scrub.begin(isPlaying: controller.isPlaying) {
            controller.pause()
        }
        return
    }

    isEditing = false
    controller.isScrubbing = false
    switch scrub.end(position: scrubPosition, buffered: buffered) {
    case .seek(let target, let resume):
        onScrubCommitted(target, resume)
    case .waiting(let target):
        onCoverageRequested(target)
    }
}
```

Add `.onChange(of: buffered)` to call `coverageAdvanced`; when it returns `.seek`, call `onScrubCommitted(target, resume)` and release the pending thumb. While `pendingTarget != nil`, display `scrubPosition` and the text "Buffering selected moment…" rather than snapping the thumb back to `controller.currentTime`.

Update the previous/next key-event accessibility actions added in Task 4 to call `onMarkerSeek(marker.offset)`. They are discrete navigation actions, not drag samples, so they use the deferred programmatic seek path below.

- [ ] **Step 6: Wire compact and expanded replay effects**

In both replay views, pass `buffered: loader.isComplete ? duration : loader.bufferedSeconds`, so a complete archive never waits for coverage that cannot advance. Wire slider effects as:

```swift
onPreviewSeek: { controller.seek(to: $0, resume: false) },
onCoverageRequested: {
    loader.ensureCoverage(upTo: $0 + ReplayLoader.prefetchLead)
},
onScrubCommitted: { target, resume in
    seek(to: target, resume: resume)
},
onMarkerSeek: { target in
    seek(to: target, resume: controller.isPlaying)
}
```

Do **not** delete the programmatic deferred-seek path. The coordinator owns only slider drags; diagnostics and key-event actions can still jump beyond the loaded range. Replace the compact view's `TimeInterval?` with:

```swift
private struct DeferredReplaySeek {
    let target: TimeInterval
    let resume: Bool
}

@State private var pendingSeek: DeferredReplaySeek?

private func seek(to seconds: TimeInterval, resume: Bool? = nil) {
    let target = max(0, seconds)
    let shouldResume = resume ?? controller.isPlaying
    if target > loader.bufferedSeconds, !loader.isComplete {
        pendingSeek = DeferredReplaySeek(target: target, resume: shouldResume)
        loader.ensureCoverage(upTo: target + ReplayLoader.prefetchLead)
        controller.seek(to: max(0, loader.bufferedSeconds - 1), resume: false)
    } else {
        pendingSeek = nil
        controller.seek(to: target, resume: shouldResume)
    }
}
```

Update the existing `loader.bufferedSeconds` observer to seek to `pending.target` with `resume: pending.resume` once covered. Add the same small deferred-seek helper to `ExpandedReplayView` for its marker accessibility actions; the expanded slider itself commits only after `ReplayScrubCoordinator` reports coverage. Keep playback-driven prefetch from `controller.currentTime` unchanged.

- [ ] **Step 7: Run controller, scrub, marker, and replay interaction tests**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/ReplayScrubCoordinatorTests -only-testing:GetHogTests/ReplayTimelineMarkerTests -only-testing:GetHogTests/SessionSummaryScreenTests -only-testing:GetHogUITests/ReplayInteractionTests
```

Expected: selected app and UI tests execute nonzero counts and pass. Do not change range size, initial coverage, or prefetch lead in this task; the verified delay is the missing during-drag preview and coverage request.

- [ ] **Step 8: Commit the scrubbing slice**

```bash
git add GetHog.xcodeproj/project.pbxproj GetHog/Sources/Player/ReplayScrubCoordinator.swift GetHog/Sources/Player/ReplayPlayerView.swift GetHog/Sources/Player/ExpandedReplayView.swift GetHog/Tests/ReplayScrubCoordinatorTests.swift
git diff --cached --check
git commit -m "Make replay scrubbing respond during drag"
```

---

### Task 8: Verify the complete synthetic simulator journey

**Files:**
- Modify: `GetHogUITests/ReplayInteractionTests.swift`
- Review boundaries: production files owned by Tasks 2, 4, 6, and 7; edit one only after its named focused regression test reproduces the journey failure.

**Interfaces:**
- Consumes: demo generation environment, summary button/state, marker accessibility value, full-screen controls, and synchronized transport.
- Produces: one deterministic end-to-end UI regression test and final executed-count evidence.

- [ ] **Step 1: Add the complete journey regression test**

Add to `ReplayInteractionTests`:

```swift
func testGenerateSummaryAddsKeyEventsAndKeepsThemFullScreen() {
    let app = DemoLaunch.launch(
        openURL: "gethog://replay/\(DemoLaunch.replaySessionID)",
        environment: ["GETHOG_DEMO_SUMMARY_GENERATION": "1"]
    )

    let generate = app.buttons["Generate AI summary"]
    for _ in 0..<12 where !generate.isHittable {
        app.swipeUp(velocity: .slow)
        DemoLaunch.pause(0.3)
    }
    XCTAssertTrue(generate.exists && generate.isHittable)
    generate.tap()

    let chapter = app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Chapter 1,")
    ).firstMatch
    XCTAssertTrue(DemoLaunch.wait(for: chapter, timeout: 120))

    let compact = app.sliders["Playback position"]
    for _ in 0..<12 where !compact.isHittable {
        app.swipeDown(velocity: .slow)
        DemoLaunch.pause(0.3)
    }
    XCTAssertTrue(compact.exists && compact.isEnabled)
    compact.adjust(toNormalizedSliderPosition: 0.1)
    XCTAssertTrue((compact.value as? String)?.contains("2 key events") == true)
    XCTAssertTrue(
        (compact.value as? String)?.contains("fictional refresh button") == true
    )

    app.buttons["Expand replay"].tap()
    let full = app.sliders["Full-screen playback position"]
    XCTAssertTrue(DemoLaunch.wait(for: full, timeout: 120))
    XCTAssertTrue((full.value as? String)?.contains("2 key events") == true)
}
```

- [ ] **Step 2: Run the new journey before any polish**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogUITests/ReplayInteractionTests/testGenerateSummaryAddsKeyEventsAndKeepsThemFullScreen
```

Expected: the complete journey passes. A failure at the generation request is owned by `DemoTransportTests`; a failure after the POST but before chapters appear is owned by `SessionSummaryScreenTests`; a missing compact marker value is owned by `ReplayTimelineMarkerTests`; and a full-screen handoff failure is owned by the focused expansion UI test. Stop at the first failing boundary, add a failing case to that named suite, and fix only its owning component before rerunning this journey.

- [ ] **Step 3: Regenerate the Xcode project and run focused package tests**

Run:

```bash
xcodegen generate
swift test --package-path GetHogKit --filter SessionSummaryTests
```

Expected: generation succeeds; `SessionSummaryTests` executes a nonzero count and passes.

- [ ] **Step 4: Run all app unit tests**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests
```

Expected: `Executed N tests` with `N > 0`, zero failures, and `TEST SUCCEEDED`.

- [ ] **Step 5: Run focused replay UI coverage**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogUITests/ReplayInteractionTests -only-testing:GetHogUITests/ReplayStageAccessibilityTests -only-testing:GetHogUITests/HitTargetTests/testReplayTransportSkipButtons -only-testing:GetHogUITests/HitTargetTests/testSessionRowSeekButtons -only-testing:GetHogUITests/NestedGestureTapTests/testTimelineSeekButtonFiresOnFirstTap -only-testing:GetHogUITests/NestedGestureTapTests/testSummaryChapterSeekButtonFiresOnFirstTap
```

Expected: every selected test executes, zero failures, and `TEST SUCCEEDED`.

- [ ] **Step 6: Check retained-data privacy and whitespace**

Run:

```bash
git diff --unified=0 dc28bd2 -- GetHog GetHogKit GetHogUITests | rg '^\+.*(@gmail\\.com|@yahoo\\.com|phx_|phc_|https://(us|eu)\\.posthog\\.com/project/)'
git diff --check
git status --short
```

Expected: the privacy command has no output, because the implementation adds no retained real domains, credentials, tenant URLs, or identifiers; whitespace check passes. Existing unrelated worktree changes are reported separately rather than modified.

- [ ] **Step 7: Commit the end-to-end regression test and any test-driven integration correction**

```bash
git add GetHogUITests/ReplayInteractionTests.swift
git diff --cached --check
git commit -m "Verify session replay interactions end to end"
```

If Step 2 required a production correction, include only the exact production file and its new focused test in this commit. Do not stage the pre-existing dashboard, comments, insights, `.codex`, `.github/hooks`, or 2026-08-01 design/plan changes.

## Completion Evidence

Before claiming completion, report:

- commit hashes for Tasks 1-8;
- the exact nonzero executed counts for focused package, app-unit, and replay UI tests;
- whether `TEST SUCCEEDED` appeared for both Xcode test invocations;
- whether `git diff --check` passed;
- any pre-existing or privacy-suite failure excluded from the verified scope;
- the remaining unrelated worktree paths, confirming they were preserved.
