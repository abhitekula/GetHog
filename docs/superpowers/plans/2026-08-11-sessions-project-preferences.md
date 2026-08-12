# Sessions Project Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the Sessions active-filter action and persist its stable viewing choices independently for every PostHog host and project.

**Architecture:** A reusable app-local `ProjectPreferenceScope` namespaces a typed `SessionsPreferences` record by resolved PostHog host and project id. `SessionsStore` activates that scope before constructing any request, owns the effective filter, persists only its durable projection, and resets transient investigation state across project boundaries; the shared SwiftUI screen routes all filter mutations through that store.

**Tech Stack:** Swift 6, SwiftUI Observation, Foundation `UserDefaults` and `Codable`, Swift Testing, XCTest/XCUITest, XcodeGen 2.46.0 or newer.

## Global Constraints

- Use Swift 6 strict concurrency and four-space indentation.
- Keep shared feature code in `GetHog/Sources/`; do not move app preferences into `GetHogKit`.
- Use `UserDefaults.standard`, not the App Group; widgets, Watch, intents, and extensions do not consume these preferences.
- Namespace every project-owned value by resolved PostHog host and numeric project id; do not include `authSessionID` in preference identity.
- Persist only internal/test-user exclusion, playable-only, and sort order.
- Keep person and URL searches, signal, date, duration, distinct ids, and inherited saved-filter clauses transient.
- All three Clear paths clear constraints and persisted narrowing toggles while preserving sort order.
- Preserve the 44-by-44-point Clear hit target and the accessibility-size vertical layout.
- `project.yml` is authoritative; regenerate with XcodeGen and never edit `GetHog.xcodeproj` by hand.
- Serialize every `xcodebuild` invocation in this checkout and never pass `-derivedDataPath`.
- Report authoritative nonzero test counts, not only command exit status.
- Use only deterministic fictional test inputs and artifacts.
- Preserve and do not stage the existing changes in `GetHogMac/Support/GetHogMac.entitlements` and `GetHogMac/Support/GetHogMac-Distribution.entitlements`.

---

## File Structure

- Create `GetHog/Sources/Common/ProjectPreferenceScope.swift`: reusable host/project namespace and stable storage-key component for app-local project preferences. `Common/` keeps it available to every shell that compiles shared Sessions code.
- Create `GetHog/Sources/Sessions/SessionsPreferences.swift`: typed, version-tolerant Sessions record and injected `UserDefaults` persistence.
- Create `GetHog/Tests/SessionsPreferencesTests.swift`: isolated-defaults tests for storage defaults, round trips, scoping, and malformed data.
- Modify `GetHog/Sources/Sessions/SessionsRoot.swift`: make `SessionsStore` scope-aware, persist the durable filter projection, route saved filters and Clear actions, add host-aware task identity, and correct baseline alignment.
- Modify `GetHog/Sources/Sessions/SessionFilterSheet.swift`: delegate Clear to `SessionsStore` so the sheet follows the same preserve-sort contract as the other two Clear paths.
- Modify `GetHog/Tests/SessionsFilterScreenTests.swift`: prove request ordering, project/host boundaries, persistence writes, playlist replacement, Clear semantics, and stale-response rejection.
- Create `GetHogUITests/SessionsFilterSummaryTests.swift`: measure the rendered baseline, hit target, and AX5 vertical ordering.

---

### Task 1: Host/project preference storage

**Files:**
- Create: `GetHog/Sources/Common/ProjectPreferenceScope.swift`
- Create: `GetHog/Sources/Sessions/SessionsPreferences.swift`
- Create: `GetHog/Tests/SessionsPreferencesTests.swift`

**Interfaces:**
- Consumes: `PostHogRegion.host`, `SessionRecordingFilter.Source.web`, and `SessionRecordingFilter.Order`.
- Produces: `ProjectPreferenceScope(projectID:region:)`, `ProjectPreferenceScope.storageKeyComponent`, `SessionsPreferences.Value`, `SessionsPreferences.value(for:)`, `SessionsPreferences.set(_:for:)`, and `SessionsPreferences.defaultsKey(for:)`.

- [ ] **Step 1: Write the failing preference tests**

Create `SessionsPreferencesTests.swift` with an isolated suite helper and these five behavioral tests:

```swift
import Foundation
import GetHogKit
import Testing

@testable import GetHog

@MainActor
@Suite("Sessions preferences")
struct SessionsPreferencesTests {
    private func storage(_ name: String = #function) -> UserDefaults {
        let suite = "SessionsPreferencesTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("an empty store returns the authored defaults and a new store restores a write")
    func defaultsAndRoundTrip() {
        let defaults = storage()
        let scope = ProjectPreferenceScope(projectID: 1_001, region: .usCloud)
        let value = SessionsPreferences.Value(
            filterTestAccounts: true,
            playableOnly: true,
            order: .consoleErrorCount
        )

        #expect(SessionsPreferences(defaults: defaults).value(for: scope) == .init())
        SessionsPreferences(defaults: defaults).set(value, for: scope)
        #expect(SessionsPreferences(defaults: defaults).value(for: scope) == value)
    }

    @Test("two project ids on one host do not share a value")
    func separatesProjects() {
        let preferences = SessionsPreferences(defaults: storage())
        let first = ProjectPreferenceScope(projectID: 8, region: .usCloud)
        let second = ProjectPreferenceScope(projectID: 42, region: .usCloud)

        preferences.set(.init(filterTestAccounts: true), for: first)
        #expect(preferences.value(for: first).filterTestAccounts)
        #expect(!preferences.value(for: second).filterTestAccounts)
    }

    @Test("the same project id on two hosts does not share a value")
    func separatesHosts() {
        let preferences = SessionsPreferences(defaults: storage())
        let us = ProjectPreferenceScope(projectID: 77, region: .usCloud)
        let eu = ProjectPreferenceScope(projectID: 77, region: .euCloud)

        preferences.set(.init(playableOnly: true), for: us)
        #expect(preferences.value(for: us).playableOnly)
        #expect(!preferences.value(for: eu).playableOnly)
        #expect(us.storageKeyComponent != eu.storageKeyComponent)
    }

    @Test("missing fields default independently and an unknown order does not erase booleans")
    func toleratesVersionSkew() throws {
        let defaults = storage()
        let scope = ProjectPreferenceScope(
            projectID: 9,
            region: .selfHosted(URL(string: "https://app.example.com")!)
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "filterTestAccounts": true,
            "order": "removed_in_a_future_build",
        ])
        defaults.set(data, forKey: SessionsPreferences.defaultsKey(for: scope))

        let value = SessionsPreferences(defaults: defaults).value(for: scope)
        #expect(value.filterTestAccounts)
        #expect(!value.playableOnly)
        #expect(value.order == .startTime)
    }

    @Test("an unreadable record safely returns all defaults")
    func corruptRecordDefaults() {
        let defaults = storage()
        let scope = ProjectPreferenceScope(projectID: 77, region: .euCloud)
        defaults.set(Data([0xFF, 0x00]), forKey: SessionsPreferences.defaultsKey(for: scope))

        #expect(SessionsPreferences(defaults: defaults).value(for: scope) == .init())
    }
}
```

- [ ] **Step 2: Regenerate and verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SessionsPreferencesTests
```

Expected: compilation fails because `ProjectPreferenceScope` and
`SessionsPreferences` do not exist. The test target must be discovered; a
zero-test success is not an acceptable RED result.

- [ ] **Step 3: Implement the reusable scope**

Create `ProjectPreferenceScope.swift`:

```swift
import Foundation
import GetHogKit

/// The namespace in which one project's local UI preferences are meaningful.
/// Authentication epochs are write authority, not preference identity.
struct ProjectPreferenceScope: Equatable, Hashable, Sendable {
    let projectID: Int
    let region: PostHogRegion

    var storageKeyComponent: String {
        let host = region.host.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? "invalid-host"
        return "\(host).\(projectID)"
    }
}
```

- [ ] **Step 4: Implement the version-tolerant Sessions record**

Create `SessionsPreferences.swift`:

```swift
import Foundation
import GetHogKit

@MainActor
struct SessionsPreferences {
    struct Value: Equatable, Sendable {
        var filterTestAccounts: Bool
        var playableOnly: Bool
        var order: SessionRecordingFilter.Order

        init(
            filterTestAccounts: Bool = false,
            playableOnly: Bool = false,
            order: SessionRecordingFilter.Order = .startTime
        ) {
            self.filterTestAccounts = filterTestAccounts
            self.playableOnly = playableOnly
            self.order = order
        }

        init(filter: SessionRecordingFilter) {
            self.init(
                filterTestAccounts: filter.filterTestAccounts,
                playableOnly: filter.source == .web,
                order: filter.order
            )
        }

        func apply(to filter: inout SessionRecordingFilter) {
            filter.filterTestAccounts = filterTestAccounts
            filter.source = playableOnly ? .web : nil
            filter.order = order
        }
    }

    private struct StoredValue: Codable {
        var filterTestAccounts: Bool?
        var playableOnly: Bool?
        var order: String?
    }

    private static let keyPrefix = "sessions.preferences.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func defaultsKey(for scope: ProjectPreferenceScope) -> String {
        "\(keyPrefix).\(scope.storageKeyComponent)"
    }

    func value(for scope: ProjectPreferenceScope) -> Value {
        guard let data = defaults.data(forKey: Self.defaultsKey(for: scope)),
              let stored = try? JSONDecoder().decode(StoredValue.self, from: data)
        else { return Value() }

        return Value(
            filterTestAccounts: stored.filterTestAccounts ?? false,
            playableOnly: stored.playableOnly ?? false,
            order: stored.order.flatMap(SessionRecordingFilter.Order.init(rawValue:))
                ?? .startTime
        )
    }

    func set(_ value: Value, for scope: ProjectPreferenceScope) {
        let stored = StoredValue(
            filterTestAccounts: value.filterTestAccounts,
            playableOnly: value.playableOnly,
            order: value.order.rawValue
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey(for: scope))
    }
}
```

- [ ] **Step 5: Regenerate with the new sources and verify GREEN**

Run `xcodegen generate` once more so the newly created source files enter every
generated target, then re-run the exact focused `xcodebuild test` command.
Require a Swift Testing result containing five entered tests, zero issues, and
no adjacent build error.

- [ ] **Step 6: Commit the scoped storage slice**

```bash
git add GetHog/Sources/Common/ProjectPreferenceScope.swift \
  GetHog/Sources/Sessions/SessionsPreferences.swift \
  GetHog/Tests/SessionsPreferencesTests.swift
git commit -m "feat: add project-scoped session preferences"
```

Do not stage either entitlement file.

---

### Task 2: Scope-aware SessionsStore lifecycle

**Files:**
- Modify: `GetHog/Sources/Sessions/SessionsRoot.swift`
- Modify: `GetHog/Tests/SessionsFilterScreenTests.swift`

**Interfaces:**
- Consumes: `ProjectPreferenceScope` and `SessionsPreferences` from Task 1.
- Produces: `SessionsStore.init(preferences:)`, `activate(scope:)`,
  `requestSignature(for:)`, `replaceFilter(_:)`, and `clearFilters()`; existing
  `load(client:projectID:)` and `loadMore(client:projectID:)` keep their public
  call shape but compare complete host/project scopes internally.

- [ ] **Step 1: Make the test client region-selectable**

Change the test helper without changing its default behavior:

```swift
private func client(
    _ transport: some HTTPTransport,
    region: PostHogRegion = .usCloud
) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_test", region: region),
        transport: transport
    )
}
```

In `filterIsSentToTheServer`, activate the owner before setting its filter so
the test does not configure an unowned pre-project filter:

```swift
let store = sessionsStore()
store.activate(scope: ProjectPreferenceScope(projectID: 1, region: .usCloud))
store.filter.signal = .rageClick
store.filter.minimumDuration = 60
store.filter.dateWindow = .last7Days
store.filter.filterTestAccounts = true
await store.load(client: client(transport), projectID: 1)
```

- [ ] **Step 2: Write failing store-lifetime tests**

Add these behaviors to `SessionsFilterScreenTests` using a fresh isolated
defaults suite in each test:

```swift
private func sessionPreferences(_ name: String = #function) -> SessionsPreferences {
    let suite = "SessionsFilterScreenTests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return SessionsPreferences(defaults: defaults)
}

private func sessionsStore(_ name: String = #function) -> SessionsStore {
    SessionsStore(preferences: sessionPreferences(name))
}

@Test("stored choices are active before the destination request is constructed")
func restoresBeforeRequest() async {
    let preferences = sessionPreferences()
    let scope = ProjectPreferenceScope(projectID: 77, region: .euCloud)
    preferences.set(
        .init(filterTestAccounts: true, playableOnly: true, order: .clickCount),
        for: scope
    )
    let transport = RecordingsTransport(total: 2)
    let store = SessionsStore(preferences: preferences)

    await store.load(client: client(transport, region: .euCloud), projectID: 77)

    let items = await transport.items(0)
    #expect(items["filter_test_accounts"] == "true")
    #expect(items["having_predicates"]?.contains("snapshot_source") == true)
    #expect(items["order"] == "click_count")
}

@Test("a project switch clears transient investigation state and applies only destination choices")
func projectSwitchResetsTransientState() async {
    let preferences = sessionPreferences()
    let first = ProjectPreferenceScope(projectID: 1, region: .usCloud)
    let second = ProjectPreferenceScope(projectID: 2, region: .usCloud)
    preferences.set(.init(playableOnly: true, order: .duration), for: second)
    let store = SessionsStore(preferences: preferences)

    await store.load(client: client(RecordingsTransport(total: 1)), projectID: first.projectID)
    store.filter.personSearch = "synthetic@example.com"
    store.filter.signal = .exception
    store.filter.minimumDuration = 120
    store.filter.filterTestAccounts = true

    await store.load(client: client(RecordingsTransport(total: 1)), projectID: second.projectID)

    #expect(store.filter.personSearch == nil)
    #expect(store.filter.signal == nil)
    #expect(store.filter.minimumDuration == nil)
    #expect(!store.filter.filterTestAccounts)
    #expect(store.filter.source == .web)
    #expect(store.filter.order == .duration)
}

@Test("the same numeric project on another host has independent state and rejects the old response")
func hostSwitchIsADataBoundary() async {
    let preferences = sessionPreferences()
    let eu = ProjectPreferenceScope(projectID: 77, region: .euCloud)
    preferences.set(.init(filterTestAccounts: true), for: eu)
    let store = SessionsStore(preferences: preferences)
    let heldUS = RecordingsTransport(total: 9, gated: true)
    let slow = Task {
        await store.load(client: client(heldUS, region: .usCloud), projectID: 77)
    }
    while await heldUS.urls().isEmpty { await Task.yield() }

    await store.load(
        client: client(RecordingsTransport(total: 3), region: .euCloud),
        projectID: 77
    )
    await heldUS.release()
    await slow.value

    #expect(store.recordings.count == 3)
    #expect(store.filter.filterTestAccounts)
}

@Test("durable edits and a saved-filter replacement update only the active scope")
func writesDurableProjection() async {
    let preferences = sessionPreferences()
    let scope = ProjectPreferenceScope(projectID: 8, region: .usCloud)
    let store = SessionsStore(preferences: preferences)
    await store.load(client: client(RecordingsTransport(total: 1)), projectID: 8)

    store.filter.personSearch = "memory-only@example.com"
    #expect(preferences.value(for: scope) == .init())

    store.filter.filterTestAccounts = true
    #expect(preferences.value(for: scope).filterTestAccounts)
    store.filter.source = .web
    #expect(preferences.value(for: scope).playableOnly)
    store.filter.order = .clickCount
    #expect(preferences.value(for: scope).order == .clickCount)

    var saved = SessionRecordingFilter()
    saved.filterTestAccounts = true
    saved.source = .web
    saved.order = .activityScore
    saved.signal = .rageClick
    store.replaceFilter(saved)

    #expect(preferences.value(for: scope) == .init(
        filterTestAccounts: true,
        playableOnly: true,
        order: .activityScore
    ))
    #expect(store.filter.signal == .rageClick)
}

@Test("clearing removes every constraint and stored narrowing but preserves sort")
func clearPreservesSort() async {
    let preferences = sessionPreferences()
    let scope = ProjectPreferenceScope(projectID: 77, region: .usCloud)
    let store = SessionsStore(preferences: preferences)
    await store.load(client: client(RecordingsTransport(total: 1)), projectID: 77)
    var filter = SessionRecordingFilter()
    filter.filterTestAccounts = true
    filter.source = .web
    filter.order = .consoleErrorCount
    filter.urlSearch = "example.com/dashboard"
    filter.inheritedProperties = [
        .init(key: "plan", type: "person", value: .string("synthetic"), op: "exact"),
    ]
    store.replaceFilter(filter)

    store.clearFilters()

    #expect(!store.filter.isNarrowed)
    #expect(store.filter.order == .consoleErrorCount)
    #expect(preferences.value(for: scope) == .init(order: .consoleErrorCount))
}
```

Replace every pre-existing `SessionsStore()` construction in this suite with
`sessionsStore()`. Once `load` activates a scope, using the default initializer
would make those tests read and write the test host's real standard defaults;
every test must instead own an isolated suite. Where a new test needs to inspect
the same preferences object, keep its explicit
`SessionsStore(preferences: preferences)` construction.

- [ ] **Step 3: Verify RED**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SessionsFilterScreenTests
```

Expected: the suite fails to compile on the missing initializer and methods;
after signatures exist but before lifecycle logic, host/project isolation and
preserve-sort expectations remain red.

- [ ] **Step 4: Add durable projection ownership to SessionsStore**

Replace the plain filter and numeric loaded-project state with this shape:

```swift
var filter = SessionRecordingFilter() {
    didSet { persistDurableProjectionIfNeeded() }
}

@ObservationIgnored private let preferences: SessionsPreferences
@ObservationIgnored private var durableValue = SessionsPreferences.Value()
private var activeScope: ProjectPreferenceScope?
private var loadedScope: ProjectPreferenceScope?

init(preferences: SessionsPreferences = SessionsPreferences()) {
    self.preferences = preferences
}

func activate(scope: ProjectPreferenceScope) {
    guard activeScope != scope else { return }
    let value = preferences.value(for: scope)
    activeScope = scope
    durableValue = value
    var destinationFilter = SessionRecordingFilter()
    value.apply(to: &destinationFilter)
    filter = destinationFilter
}

func replaceFilter(_ replacement: SessionRecordingFilter) {
    filter = replacement
}

func clearFilters() {
    var cleared = SessionRecordingFilter()
    cleared.order = filter.order
    filter = cleared
}

private func persistDurableProjectionIfNeeded() {
    guard let activeScope else { return }
    let value = SessionsPreferences.Value(filter: filter)
    guard value != durableValue else { return }
    durableValue = value
    preferences.set(value, for: activeScope)
}
```

`durableValue` is the write gate: changing search, signal, date, duration, or
inherited clauses produces the same projection and performs no defaults write.
Assigning the complete replacement once in `clearFilters()` prevents an
intermediate write of the default sort order.

- [ ] **Step 5: Make signatures and loads scope-aware**

Centralize signature construction and make the inactive-scope form read the
destination preference without mutating the current screen:

```swift
private static func signature(for filter: SessionRecordingFilter) -> String {
    filter.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
}

var requestSignature: String { Self.signature(for: filter) }

func requestSignature(for scope: ProjectPreferenceScope) -> String {
    if activeScope == scope { return requestSignature }
    var destinationFilter = SessionRecordingFilter()
    preferences.value(for: scope).apply(to: &destinationFilter)
    return Self.signature(for: destinationFilter)
}
```

At the first line of both load methods, derive and activate the complete scope:

```swift
let scope = ProjectPreferenceScope(projectID: projectID, region: client.region)
activate(scope: scope)
```

In `load`, replace `loadedProjectID` comparisons and assignments with
`loadedScope`; compute `let scopeChanged = loadedScope != scope`, assign
`loadedScope = scope`, and use `loadedScope == scope` in every defer and stale
response guard. Keep the existing generation increment, synchronous row clear,
error behavior, offsets, and request body unchanged.

In `loadMore`, require the complete owner before starting:

```swift
guard loadedScope == scope,
      activeScope == scope,
      hasMore,
      !isLoading,
      !isLoadingMore
else { return }
```

Use `loadedScope == scope` in both page-response guards and the deferred loading
flag reset.

- [ ] **Step 6: Verify GREEN and regress existing Sessions behavior**

Re-run the focused `SessionsFilterScreenTests` command. Require a nonzero Swift
Testing count and zero issues, including all pre-existing paging, failure,
summary, and request-signature tests.

- [ ] **Step 7: Commit the lifecycle slice**

```bash
git add GetHog/Sources/Sessions/SessionsRoot.swift \
  GetHog/Tests/SessionsFilterScreenTests.swift
git commit -m "feat: restore session filters by project"
```

Do not stage either entitlement file.

---

### Task 3: UI wiring and rendered alignment

**Files:**
- Create: `GetHogUITests/SessionsFilterSummaryTests.swift`
- Modify: `GetHog/Sources/Sessions/SessionsRoot.swift`
- Modify: `GetHog/Sources/Sessions/SessionFilterSheet.swift`

**Interfaces:**
- Consumes: Task 2's `requestSignature(for:)`, `replaceFilter(_:)`, and
  `clearFilters()`.
- Produces: host-aware `.task(id:)`, one Clear contract across all three paths,
  and first-baseline alignment at non-accessibility sizes.

- [ ] **Step 1: Write failing rendered contracts**

Create `SessionsFilterSummaryTests.swift`:

```swift
import XCTest

@MainActor
final class SessionsFilterSummaryTests: XCTestCase {
    private func showExcludedUsersSummary(in app: XCUIApplication) -> (
        sentence: XCUIElement,
        clear: XCUIElement
    ) {
        let filter = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Filter sessions")
        ).firstMatch
        XCTAssertTrue(DemoLaunch.wait(for: filter), "Sessions did not expose its filter action.")
        filter.tap()

        let toggle = app.switches["Filter out internal and test users"]
        XCTAssertTrue(DemoLaunch.wait(for: toggle), "The test-user toggle did not render.")
        let sheetClear = app.navigationBars["Filter sessions"].buttons["Clear"]
        if sheetClear.exists { sheetClear.tap() }
        if (toggle.value as? String) != "1" { toggle.tap() }
        app.buttons["Done"].tap()

        let sentence = app.staticTexts["Showing excluding test users."]
        let clear = app.buttons["Clear all session filters"]
        XCTAssertTrue(DemoLaunch.wait(for: sentence), "The active-filter sentence did not render.")
        XCTAssertTrue(DemoLaunch.wait(for: clear), "The active-filter Clear action did not render.")
        return (sentence, clear)
    }

    func testSummaryClearAlignsWithSentenceAndKeepsItsHitTarget() {
        let app = DemoLaunch.launch(tab: "sessions")
        defer { app.terminate() }
        let summary = showExcludedUsersSummary(in: app)

        XCTAssertEqual(
            summary.clear.frame.midY,
            summary.sentence.frame.midY,
            accuracy: 2,
            "Clear is not vertically aligned with the visible summary sentence."
        )
        summary.clear.assertMeetsMinimumHitTarget("Sessions active-filter Clear action")
        summary.clear.tap()
    }

    func testSummaryStacksClearAfterSentenceAtAX5() {
        let app = DemoLaunch.launch(
            tab: "sessions",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        defer { app.terminate() }
        let summary = showExcludedUsersSummary(in: app)

        XCTAssertGreaterThanOrEqual(
            summary.clear.frame.minY,
            summary.sentence.frame.maxY,
            "At AX5, Clear must follow the complete sentence instead of floating beside it."
        )
        summary.clear.assertMeetsMinimumHitTarget("AX5 Sessions active-filter Clear action")
        summary.clear.tap()
    }

    func testExcludedUsersChoiceSurvivesRelaunch() {
        let app = DemoLaunch.launch(tab: "sessions")
        defer { app.terminate() }
        _ = showExcludedUsersSummary(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(DemoLaunch.wait(for: app.navigationBars["Sessions"]))

        let restored = app.staticTexts["Showing excluding test users."]
        XCTAssertTrue(
            DemoLaunch.wait(for: restored),
            "The active project's test-user exclusion did not survive relaunch."
        )
        let clear = app.buttons["Clear all session filters"]
        XCTAssertTrue(DemoLaunch.wait(for: clear))
        clear.tap()
    }
}
```

Each test clears the durable toggle before termination, so simulator reuse does
not leak its state into a later test.

- [ ] **Step 2: Regenerate and verify RED**

Run:

```bash
xcodegen generate
WORKERS=1 scripts/run-ui-tests \
  GetHogUITests/SessionsFilterSummaryTests
```

Expected: three tests are entered; the default-size test fails because the
top-aligned 44-point frame puts Clear's midpoint below the sentence. The AX5
test may already pass and still serves as the regression guard for the retained
vertical branch. The relaunch case is the end-to-end lifetime contract.

- [ ] **Step 3: Give the sheet the shared Clear action**

Change the sheet interface and toolbar action:

```swift
struct SessionFilterSheet: View {
    @Binding var filter: SessionRecordingFilter
    var onClear: () -> Void
    // existing environment and state
}
```

```swift
if filter.isNarrowed {
    Button("Clear", role: .destructive, action: onClear)
}
```

The sheet continues binding every control directly to the one store-owned
filter; only the multi-field Clear mutation needs a semantic callback.

- [ ] **Step 4: Route root mutations through SessionsStore**

Add the current preference scope and task identity to `SessionsRoot`:

```swift
private var preferenceScope: ProjectPreferenceScope? {
    guard let client = model.client, let projectID = model.projectID else { return nil }
    return ProjectPreferenceScope(projectID: projectID, region: client.region)
}

private var loadTaskID: String {
    guard let scope = preferenceScope else { return "sessions.none" }
    return "\(scope.storageKeyComponent)|\(store.requestSignature(for: scope))"
}
```

Use `.task(id: loadTaskID)` in place of the numeric-project signature. Keep the
existing search debounce and `load()` body.

Route every whole-filter mutation through the store:

```swift
SessionFilterSheet(filter: $store.filter, onClear: store.clearFilters)
```

```swift
PlaylistsView { store.replaceFilter($0) }
```

```swift
action: store.clearFilters
```

Use the last form for both the filtered-empty action and
`ActiveFilterSummary` callback. No direct `store.filter.clear()` call may remain
in `GetHog/Sources/Sessions/`.

- [ ] **Step 5: Correct the normal-size alignment**

Change only the non-accessibility branch of `ActiveFilterSummary`:

```swift
HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
    sentence
    Spacer(minLength: Theme.Space.s)
    clearButton
}
```

Keep the AX5 `VStack`, wrapping sentence, font, color, accessibility labels,
padding, summary cap, and `.minimumHitTarget()` unchanged.

- [ ] **Step 6: Verify rendered GREEN with authoritative counts**

Re-run the exact wrapper command. Require the xcresult summary to report three
passed tests, zero failures, and zero unexpected skips. Inspect the assertion
output to record the actual midpoint delta and Clear frame size.

- [ ] **Step 7: Re-run focused unit coverage**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SessionsPreferencesTests \
  -only-testing:GetHogTests/SessionsFilterScreenTests
```

Require both Swift Testing suites to enter a nonzero number of tests and pass.

- [ ] **Step 8: Commit the UI slice**

```bash
git add GetHog/Sources/Sessions/SessionsRoot.swift \
  GetHog/Sources/Sessions/SessionFilterSheet.swift \
  GetHogUITests/SessionsFilterSummaryTests.swift
git commit -m "fix: align and retain session filters"
```

Do not stage either entitlement file.

---

### Task 4: Full verification and handoff

**Files:**
- Verify: all files changed in Tasks 1–3
- Preserve: `GetHogMac/Support/GetHogMac.entitlements`
- Preserve: `GetHogMac/Support/GetHogMac-Distribution.entitlements`

**Interfaces:**
- Consumes: the complete scoped-preference and UI implementation.
- Produces: fresh nonzero test evidence and shared-platform compile evidence.

- [ ] **Step 1: Regenerate from the authoritative project model**

Run:

```bash
xcodegen generate
git diff --check
```

Expected: XcodeGen's guarded watch embed check passes, and the diff check emits
no whitespace errors. Do not hand-edit generated project files.

- [ ] **Step 2: Run the complete iOS unit target**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests
```

Require a nonzero authoritative Swift Testing count and zero issues.

- [ ] **Step 3: Run the focused rendered UI suite**

```bash
WORKERS=1 scripts/run-ui-tests \
  GetHogUITests/SessionsFilterSummaryTests
```

Require the wrapper's xcresult summary to report exactly three entered tests and
zero failures.

- [ ] **Step 4: Compile every shell that shares Sessions**

Run these serially:

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS'
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project GetHog.xcodeproj -scheme GetHogVision \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
xcodebuild build -project GetHog.xcodeproj -scheme GetHogTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)'
```

Require `BUILD SUCCEEDED` from all four commands. Watch does not compile the
Sessions surface and needs no build for this change.

- [ ] **Step 5: Audit the final diff and worktree ownership**

Run:

```bash
git status --short
git diff --stat HEAD~3..HEAD
git log -3 --oneline
```

Confirm that committed implementation artifacts are synthetic, no defaults or
fixtures contain customer data, no unrelated source is present, and the only
remaining worktree modifications are the two pre-existing entitlement files.

- [ ] **Step 6: Report completion evidence**

Report:

- the persisted fields and exact host/project scope;
- that transient investigation state resets at project boundaries;
- the actual focused and full unit test counts;
- the three-test xcresult UI count and measured Clear frame/alignment result;
- Mac Debug/Release, Vision, and TV compile results;
- the three implementation commit hashes;
- the untouched entitlement modifications;
- saved event filter, SQL history, and headline metric scoping as separate audit
  follow-ups, not completed work.
