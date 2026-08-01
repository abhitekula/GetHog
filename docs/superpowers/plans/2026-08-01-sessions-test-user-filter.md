# Sessions Test-User Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an off-by-default Sessions toggle that asks PostHog to exclude the project's configured internal and test users.

**Architecture:** Extend `SessionRecordingFilter` as the single source of truth, emitting `filter_test_accounts=true` only when enabled. The existing Sessions store will carry that query item through first-page loads, request signatures, stale-response protection, and pagination; the SwiftUI filter sheet binds directly to the model, while saved replay filters translate PostHog's legacy string value into the same Boolean state.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, XCTest/XCUITest, `GetHogKit`, XcodeGen-generated iOS project.

## Global Constraints

- The toggle defaults to off and does not persist independently of the current Sessions filter state.
- When off, an untouched filter emits no query items and preserves the existing unfiltered request.
- When on, the recordings request emits exactly `filter_test_accounts=true`.
- The UI label is “Filter out internal and test users.”
- Test-account membership is evaluated only by PostHog; GetHog does not infer it from recording data.
- All committed tests, fixtures, screenshots, examples, and documentation use deterministic synthetic data.
- Do not edit `GetHog.xcodeproj`; `project.yml` is authoritative, and these existing-file changes do not require regeneration.
- Do not use `xcrun simctl` or pass `-derivedDataPath` to Xcode commands.

---

## File Structure

- `GetHogKit/Sources/GetHogKit/Models/SessionRecordingFilter.swift`: owns the new Boolean, query encoding, active-filter count, and clearing behavior.
- `GetHogKit/Sources/GetHogKit/Models/SessionRecordingPlaylist.swift`: translates saved PostHog replay-filter state into the canonical filter model.
- `GetHog/Sources/Sessions/SessionFilterSheet.swift`: presents the native People-section toggle.
- `GetHog/Sources/Sessions/SessionsRoot.swift`: adds the active-filter summary clause.
- `GetHogKit/Tests/GetHogKitTests/SessionRecordingFilterTests.swift`: verifies the filter and saved-playlist contracts.
- `GetHog/Tests/SessionsFilterScreenTests.swift`: verifies the store request, request signature, and summary behavior.
- `GetHogUITests/Screenshots/StateScreenshotTests.swift`: verifies the toggle exists in the rendered filter sheet.

### Task 1: Canonical Filter and Request Contract

**Files:**
- Modify: `GetHogKit/Sources/GetHogKit/Models/SessionRecordingFilter.swift:219-383`
- Test: `GetHogKit/Tests/GetHogKitTests/SessionRecordingFilterTests.swift:17-271`
- Test: `GetHog/Tests/SessionsFilterScreenTests.swift:105-260`

**Interfaces:**
- Consumes: Existing `SessionRecordingFilter.queryItems`, `activeCount`, `clear()`, and `SessionsStore.requestSignature`.
- Produces: `public var filterTestAccounts: Bool`, default `false`; query item `filter_test_accounts=true` when enabled.

- [ ] **Step 1: Write failing filter-model tests**

Add the default assertion to `emptyFilterIsSilent()` and this test beside the other encoding tests:

```swift
#expect(!filter.filterTestAccounts)

@Test("test users are excluded only when the server-side option is enabled")
func filterTestAccountsEncodes() {
    var filter = SessionRecordingFilter()
    #expect(items(filter)["filter_test_accounts"] == nil)

    filter.filterTestAccounts = true
    #expect(items(filter)["filter_test_accounts"] == "true")
    #expect(filter.activeCount == 1)
    #expect(filter.isNarrowed)

    filter.clear()
    #expect(!filter.filterTestAccounts)
    #expect(items(filter)["filter_test_accounts"] == nil)
}
```

- [ ] **Step 2: Write failing Sessions-store tests**

Extend `filterIsSentToTheServer()` so the filter and wire assertion include:

```swift
store.filter.filterTestAccounts = true
#expect(items["filter_test_accounts"] == "true")
```

Extend `requestSignature()` with a fresh store so the Boolean is isolated from its existing ordering assertions:

```swift
let testAccountsStore = SessionsStore()
let includesTestUsers = testAccountsStore.requestSignature
testAccountsStore.filter.filterTestAccounts = true
#expect(testAccountsStore.requestSignature != includesTestUsers)
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
swift test --package-path GetHogKit --filter SessionRecordingFilterTests
```

Expected: compilation fails because `SessionRecordingFilter` has no `filterTestAccounts` member.

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/SessionsFilterScreenTests
```

Expected: compilation fails for the same missing member; do not accept a zero-test success.

- [ ] **Step 4: Implement the minimal model behavior**

Add the state beside the other narrowing fields:

```swift
/// Whether PostHog should apply the project's internal and test-user filters.
public var filterTestAccounts = false
```

In `queryItems`, after the date item and before structured filter arrays, add:

```swift
if filterTestAccounts {
    items.append(URLQueryItem(name: "filter_test_accounts", value: "true"))
}
```

In `activeCount`, add:

```swift
if filterTestAccounts { count += 1 }
```

Keep `clear()` unchanged because replacing the whole value with `SessionRecordingFilter()` restores the default false state.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the same package and app-test commands from Step 3. Expected: the package suite passes, and the Xcode test output reports a nonzero executed count for `SessionsFilterScreenTests` with `TEST SUCCEEDED`.

- [ ] **Step 6: Commit the canonical contract**

```bash
git add GetHogKit/Sources/GetHogKit/Models/SessionRecordingFilter.swift GetHogKit/Tests/GetHogKitTests/SessionRecordingFilterTests.swift GetHog/Tests/SessionsFilterScreenTests.swift
git commit -m "Add replay test-account filter contract"
```

### Task 2: Saved Replay-Filter Translation

**Files:**
- Modify: `GetHogKit/Sources/GetHogKit/Models/SessionRecordingPlaylist.swift:140-198`
- Test: `GetHogKit/Tests/GetHogKitTests/SessionRecordingFilterTests.swift:346-437`

**Interfaces:**
- Consumes: `SessionRecordingFilter.filterTestAccounts: Bool` from Task 1 and the playlist's `[String: JSONValue]` filter blob.
- Produces: `SessionRecordingPlaylist.recordingFilter` sets the canonical Boolean only for the stored string `"true"`.

- [ ] **Step 1: Write failing saved-filter tests**

Add these tests to `SavedRecordingFilterTests` using inline synthetic playlists so the expected value is independent of existing fixtures:

```swift
@Test("a saved filter preserves the console's test-account exclusion")
func translatesTestAccountExclusion() throws {
    let saved = try SessionRecordingPlaylist.decode(
        #"{"id": 1, "short_id": "test-on", "name": "Synthetic", "type": "filters", "filters": {"filter_test_accounts": "true"}}"#
    )
    let filter = try #require(saved.recordingFilter)
    #expect(filter.filterTestAccounts)
    #expect(filter.queryItems.first { $0.name == "filter_test_accounts" }?.value == "true")
}

@Test("a saved filter that includes test accounts leaves exclusion disabled")
func translatesIncludedTestAccounts() throws {
    let saved = try SessionRecordingPlaylist.decode(
        #"{"id": 2, "short_id": "test-off", "name": "Synthetic", "type": "filters", "filters": {"filter_test_accounts": "false"}}"#
    )
    let filter = try #require(saved.recordingFilter)
    #expect(!filter.filterTestAccounts)
}
```

- [ ] **Step 2: Run the saved-filter suite and verify RED**

Run:

```bash
swift test --package-path GetHogKit --filter SavedRecordingFilterTests
```

Expected: `translatesTestAccountExclusion` fails because the decoded filter remains false.

- [ ] **Step 3: Implement the legacy-string translation**

After constructing `out` in `recordingFilter`, add:

```swift
out.filterTestAccounts = filters["filter_test_accounts"]?.stringValue == "true"
```

Do not coerce arbitrary strings or add fixture-specific behavior.

- [ ] **Step 4: Run the saved-filter suite and verify GREEN**

Run the Step 2 command. Expected: both new tests and the existing saved-filter tests pass.

- [ ] **Step 5: Commit the translation**

```bash
git add GetHogKit/Sources/GetHogKit/Models/SessionRecordingPlaylist.swift GetHogKit/Tests/GetHogKitTests/SessionRecordingFilterTests.swift
git commit -m "Preserve saved replay test-account filters"
```

### Task 3: Sessions Toggle and Visible Filter State

**Files:**
- Modify: `GetHog/Sources/Sessions/SessionFilterSheet.swift:4-226`
- Modify: `GetHog/Sources/Sessions/SessionsRoot.swift:399-435`
- Test: `GetHog/Tests/SessionsFilterScreenTests.swift:260-305`
- Test: `GetHogUITests/Screenshots/StateScreenshotTests.swift:248-269`

**Interfaces:**
- Consumes: `SessionRecordingFilter.filterTestAccounts: Bool` from Task 1.
- Produces: A native toggle labeled “Filter out internal and test users” and summary clause “excluding test users”.

- [ ] **Step 1: Write a failing summary test**

Add this independent case inside `summarySentence()` before the existing multi-filter case:

```swift
var testUsers = SessionRecordingFilter()
testUsers.filterTestAccounts = true
#expect(testUsers.summarySentence == "Showing excluding test users.")
```

- [ ] **Step 2: Write a failing rendered-toggle assertion**

In the `testSessionFilterSheet()` screenshot step, keep the navigation-bar wait and then require the new native switch:

```swift
guard self.waitUntil({ app.navigationBars["Filter sessions"].exists }) else { return false }
return self.waitUntil {
    app.switches["Filter out internal and test users"].exists
}
```

- [ ] **Step 3: Run both focused tests and verify RED**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/SessionsFilterScreenTests
```

Expected: the summary assertion fails because the clause is absent.

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHogScreenshots -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogScreenshots/StateScreenshotTests/testSessionFilterSheet
```

Expected: the screenshot step fails because the switch does not exist; confirm the test actually executed.

- [ ] **Step 4: Add the native People-section toggle**

Insert `peopleSection` before `signalSection` in the form and add:

```swift
// MARK: - People

private var peopleSection: some View {
    Section {
        Toggle("Filter out internal and test users", isOn: $filter.filterTestAccounts)
    } header: {
        Text("People").foregroundStyle(Theme.Ink.secondary)
    } footer: {
        Text("Uses the internal and test-user filters configured for this project in PostHog.")
            .foregroundStyle(Theme.Ink.secondary)
    }
}
```

Update the sheet's ordering documentation so People is listed first and explains that PostHog owns the configured definitions.

- [ ] **Step 5: Add the summary clause**

At the beginning of `summarySentence`'s ordered parts, matching the sheet order, add:

```swift
if filterTestAccounts { parts.append("excluding test users") }
```

The existing three-clause cap remains unchanged.

- [ ] **Step 6: Run both focused tests and verify GREEN**

Run the two commands from Step 3. Expected: `SessionsFilterScreenTests` reports a nonzero executed count with `TEST SUCCEEDED`; the screenshot test executes once, finds the switch, and reports `TEST SUCCEEDED`.

- [ ] **Step 7: Commit the Sessions UI**

```bash
git add GetHog/Sources/Sessions/SessionFilterSheet.swift GetHog/Sources/Sessions/SessionsRoot.swift GetHog/Tests/SessionsFilterScreenTests.swift GetHogUITests/Screenshots/StateScreenshotTests.swift
git commit -m "Add Sessions test-user toggle"
```

### Task 4: Full Verification

**Files:**
- Verify only; no planned source changes.

**Interfaces:**
- Consumes: All code and tests from Tasks 1-3.
- Produces: Fresh evidence that package behavior, app behavior, rendering, and repository hygiene remain valid.

- [ ] **Step 1: Run the full package suite**

```bash
swift test --package-path GetHogKit
```

Expected: all `GetHogKit` tests pass with zero failures.

- [ ] **Step 2: Run all app unit tests**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests
```

Expected: a nonzero `Executed N tests` count, zero failures, and `TEST SUCCEEDED`.

- [ ] **Step 3: Re-run the rendered filter-sheet test**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHogScreenshots -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogScreenshots/StateScreenshotTests/testSessionFilterSheet
```

Expected: one executed test, zero failures, and `TEST SUCCEEDED`.

- [ ] **Step 4: Check repository hygiene**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only the planned implementation-plan file remains if it has not yet been committed.

- [ ] **Step 5: Commit the implementation plan if still uncommitted**

```bash
git add docs/superpowers/plans/2026-08-01-sessions-test-user-filter.md
git commit -m "Document Sessions test-user implementation"
```
