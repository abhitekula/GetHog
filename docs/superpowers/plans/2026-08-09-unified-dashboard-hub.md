# Unified Dashboard Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the regular-width nested dashboard split on Vision, iPad, and Mac with one adaptive dashboard hub that uses the available center width and preserves compact iPhone behavior.

**Architecture:** `DashboardsRoot` continues to own one `DashboardsStore`, search state, and `OpenDetails` selection. Compact width keeps the existing list-to-detail navigation. Regular width uses one `NavigationStack` whose root is a new `DashboardHub`; the selected dashboard is the stack path, so the hub and its pinned-preview state remain alive behind `DashboardDetailView`. `ProjectOverview` becomes reusable non-scrolling content inside that hub, and dashboard rows become adaptive cards in the same `PageScaffold`.

**Tech Stack:** Swift 6, SwiftUI Observation, Swift Testing, XCTest/XCUITest, GetHogUI theme and layout primitives.

## Global Constraints

- Apply the unified hub only to regular-width Vision, iPad, and Mac; compact iPhone remains list-to-detail.
- Keep `OpenDetails` as selection authority for deep links, restoration, detached windows, and size transitions.
- Keep exactly one dashboard-list load task and do not add insight recomputation.
- Preserve Mac refresh, project switcher, context menus, and open-in-new-window actions.
- Preserve honest unavailable, loading, failed, successfully empty, loaded, and search-empty states.
- Use `Theme` spacing, color, radius, and typography values; do not introduce literal visual constants except adaptive minimum card width justified by rendered evidence.
- Serialize every `xcodebuild` invocation because all schemes share DerivedData.

---

### Task 1: Pin the cross-platform unified-hub contract

**Files:**
- Modify: `GetHogVision/UITests/VisionWindowTests.swift`
- Modify: `GetHogUITests/DashboardConsistencyUITests.swift`
- Modify: `GetHogMac/UITests/MacWindowSizeTests.swift`

**Interfaces:**
- Consumes: existing demo dashboard fixtures and `DemoLaunch`.
- Produces: rendered contract for accessibility identifiers `gethog.dashboard-hub`, `gethog.dashboard-collection`, and `gethog.dashboard-card.<id>`.

- [ ] **Step 1: Write the failing Vision rendered test**

Add a regular-width case to `VisionWindowTests` that launches Dashboards at 1280pt, waits for `gethog.dashboard-hub`, finds `gethog.dashboard-collection` and the first dashboard card, and requires the project signal plus dashboard collection to share the same hub scroll surface. Assert the first card begins no farther left than the hub frame and that the collection uses more than half the hub width.

```swift
func testDashboardLandingUsesOneRegularWidthHub() {
    let app = DemoLaunch.launch(
        tab: "dashboards",
        environment: ["GETHOG_VISION_CONTENT_WIDTH": "1280"]
    )

    let hub = app.scrollViews["gethog.dashboard-hub"].firstMatch
    let collection = app.otherElements["gethog.dashboard-collection"].firstMatch
    let card = app.buttons["gethog.dashboard-card.725101"].firstMatch

    XCTAssertTrue(DemoLaunch.wait(for: hub))
    XCTAssertTrue(DemoLaunch.wait(for: collection))
    XCTAssertTrue(DemoLaunch.wait(for: card))
    XCTAssertTrue(app.staticTexts["Project signal"].exists)
    XCTAssertGreaterThan(collection.frame.width, hub.frame.width * 0.5)
    XCTAssertGreaterThanOrEqual(card.frame.minX, hub.frame.minX)
}
```

- [ ] **Step 2: Run the Vision test to verify RED**

Run:

```bash
PLATFORM=vision WORKERS=1 scripts/run-ui-tests \
  GetHogVisionUITests/VisionWindowTests/testDashboardLandingUsesOneRegularWidthHub
```

Expected: one executed test, one failure because `gethog.dashboard-hub` does not exist in the current nested split.

- [ ] **Step 3: Add equivalent iPad and Mac RED contracts**

On iPad, require regular width and use the same identifiers. On Mac, launch the Dashboards root at default size and require the same single hub before attempting narrow/wide screenshots. Both tests must skip honestly on the wrong destination rather than pass through an early return.

- [ ] **Step 4: Run the iPad and Mac tests to verify RED**

Run, one at a time:

```bash
DESTINATION_NAME='iPad Air 11-inch (M4)' WORKERS=1 scripts/run-ui-tests \
  GetHogUITests/DashboardConsistencyUITests/testRegularDashboardLandingUsesOneHub

xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:GetHogMacUITests/MacWindowSizeTests/testDashboardLandingUsesOneHub
```

Expected: each authoritative result executes exactly one test and fails only on the missing hub contract.

- [ ] **Step 5: Commit the RED contracts**

```bash
git add GetHogVision/UITests/VisionWindowTests.swift \
  GetHogUITests/DashboardConsistencyUITests.swift \
  GetHogMac/UITests/MacWindowSizeTests.swift
git commit -m "test: require a unified dashboard hub"
```

---

### Task 2: Build the adaptive hub without changing selection ownership

**Files:**
- Create: `GetHog/Sources/Dashboards/DashboardHub.swift`
- Modify: `GetHog/Sources/Dashboards/ProjectOverview.swift`
- Modify: `GetHog/Sources/Dashboards/DashboardsRoot.swift`
- Modify: `project.yml` only if the generated target uses an explicit file list; otherwise leave it unchanged.

**Interfaces:**
- Consumes: `[DashboardSummary]`, `Date?`, `Binding<String>`, `Binding<Int?>`, and a row builder supplied by `DashboardsRoot`.
- Produces:
  - `DashboardHub<RowContent: View>`
  - `ProjectOverviewContent`
  - `DashboardsRoot.regularPath: Binding<[Int]>`

- [ ] **Step 1: Add a pure navigation-path unit test**

In `GetHog/Tests/SignalGrammarDashboardTests.swift`, pin the optional selection/path conversion used by the regular stack.

```swift
@Test("Regular dashboard path preserves the OpenDetails selection")
func regularDashboardPath() {
    #expect(DashboardNavigationPath.path(for: nil).isEmpty)
    #expect(DashboardNavigationPath.path(for: 725_101) == [725_101])
    #expect(DashboardNavigationPath.selection(from: []) == nil)
    #expect(DashboardNavigationPath.selection(from: [725_101]) == 725_101)
}
```

- [ ] **Step 2: Run the unit test to verify RED**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:GetHogTests/SignalGrammarDashboardTests
```

Expected: compile RED because `DashboardNavigationPath` is absent.

- [ ] **Step 3: Add the minimal navigation policy**

Add this internal value boundary near `DashboardsRoot`:

```swift
enum DashboardNavigationPath {
    static func path(for selection: Int?) -> [Int] {
        selection.map { [$0] } ?? []
    }

    static func selection(from path: [Int]) -> Int? {
        path.last
    }
}
```

Expose a binding that maps the existing `selectedID` to `[Int]` without introducing a second selection source.

- [ ] **Step 4: Extract non-scrolling project overview content**

Refactor `ProjectOverview` so its async pinned-preview state stays owned by a view that can remain on the root of a `NavigationStack`:

```swift
struct ProjectOverviewContent: View {
    let dashboards: [DashboardSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            summaryScene
            if !facts.recentlyComputed.isEmpty {
                recentSection
            }
        }
        .task(id: facts.pinned?.id) { await loadPinned() }
    }
}
```

Remove the nested `PageScaffold` from this component; `DashboardHub` becomes the single scroll owner.

- [ ] **Step 5: Create `DashboardHub` as the single regular-width surface**

Implement one `PageScaffold` with the project overview followed by dashboard sections. Use `LazyVGrid` with adaptive items and the row builder so the existing platform-specific row content/context menus remain in `DashboardsRoot`.

```swift
struct DashboardHub<RowContent: View>: View {
    let dashboards: [DashboardSummary]
    let pinned: [DashboardSummary]
    let others: [DashboardSummary]
    let loadedAt: Date?
    @Binding var search: String
    @ViewBuilder let row: (DashboardSummary) -> RowContent

    private let columns = [
        GridItem(.adaptive(minimum: 280), spacing: Theme.Space.m, alignment: .top)
    ]

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            ProjectOverviewContent(dashboards: dashboards)
            dashboardCollection
        }
        .accessibilityIdentifier("gethog.dashboard-hub")
    }
}
```

The collection must retain Pinned/All dashboards labels, `FreshnessLabel`, and the local no-results state. Give the collection and each row stable identifiers from Task 1.

- [ ] **Step 6: Replace only the regular-width nested split**

In `DashboardsRoot`, keep compact code unchanged. Replace `regularSplit` with:

```swift
private var regularHub: some View {
    NavigationStack(path: regularPath) {
        regularLanding
            .navigationDestination(for: Int.self) { id in
                dashboardDetail(id: id)
            }
    }
}
```

`regularLanding` switches on `DashboardsStore.ContentState` and renders exactly one unavailable/loading/failure/empty/hub state. Apply title, project switcher, search, refresh task, and refresh command once to the landing root. Do not mount a second load task in the destination.

Use the existing row builder inside hub cards, changing only the activation boundary from split selection to the same `selectedID`/path value. Retain the Mac context menu and web/copy actions.

- [ ] **Step 7: Parse and run the focused unit test GREEN**

Run:

```bash
xcrun swiftc -frontend -parse \
  GetHog/Sources/Dashboards/DashboardHub.swift \
  GetHog/Sources/Dashboards/ProjectOverview.swift \
  GetHog/Sources/Dashboards/DashboardsRoot.swift \
  GetHog/Tests/SignalGrammarDashboardTests.swift

xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:GetHogTests/SignalGrammarDashboardTests
```

Expected: nonzero test count and all Signal Grammar Dashboard tests pass.

- [ ] **Step 8: Run the three rendered GREEN contracts**

Repeat the three exact commands from Task 1. Each result must execute one test and pass. Read screenshots/recordings rather than relying on identifiers alone.

- [ ] **Step 9: Commit the unified hub implementation**

```bash
git add GetHog/Sources/Dashboards/DashboardHub.swift \
  GetHog/Sources/Dashboards/ProjectOverview.swift \
  GetHog/Sources/Dashboards/DashboardsRoot.swift \
  GetHog/Tests/SignalGrammarDashboardTests.swift
git commit -m "feat: unify the regular dashboard landing"
```

---

### Task 3: Prove state, request, and responsive preservation

**Files:**
- Modify: `GetHog/Tests/DashboardConsistencyTests.swift`
- Modify: `GetHogUITests/DashboardConsistencyUITests.swift`
- Modify: `GetHogVision/UITests/VisionWindowTests.swift`
- Modify: `GetHogMac/UITests/MacWindowSizeTests.swift`

**Interfaces:**
- Consumes: `DashboardNavigationPath`, existing held transports, and hub identifiers.
- Produces: regression coverage for selection/return, request counts, state distinctions, and width transitions.

- [ ] **Step 1: Add held-request and remount behavior tests**

Extend `DashboardConsistencyTests` to assert that mounting the regular hub, selecting a dashboard, and returning retains one dashboard-list request and one cached pinned-detail request. Reuse `HeldCancelableDashboardTransport`; release before awaiting shared-flight waiters.

- [ ] **Step 2: Run focused behavior tests RED/GREEN**

Run the full `DashboardConsistencyTests` suite and report its exact Swift Testing count. Any change to request count must be explained by the authored contract rather than accepted by updating an expectation.

- [ ] **Step 3: Add rendered return and state coverage**

On iPad, tap the synthetic first dashboard card, require its first tile, activate `All dashboards`, and require the prior search text plus same hub to return. Preserve current loading, empty-dashboard, and failed-recompute cases.

On Vision and Mac, assert loaded, successful-empty, and failure each occupy one full hub surface rather than appearing in duplicated columns.

- [ ] **Step 4: Add responsive crossing coverage**

Use the existing Max-iPhone compact↔regular harness for a selected dashboard and the existing Vision narrow-width seam. Require that a wide hub becomes compact list-to-detail without losing `selectedID`, then returns to one hub/detail stack when regular again. On Mac, capture default/narrow/wide hub screenshots and require the dashboard collection remains usable rather than becoming a fixed narrow rail.

- [ ] **Step 5: Run the focused platform matrix**

Run serially:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -parallel-testing-enabled NO \
  -only-testing:GetHogTests/DashboardConsistencyTests \
  -only-testing:GetHogUITests/DashboardConsistencyUITests

PLATFORM=vision WORKERS=1 scripts/run-ui-tests GetHogVisionUITests/VisionWindowTests

xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:GetHogMacUITests/MacWindowSizeTests
```

Expected: every authoritative result is readable, has a nonzero executed count, and has zero failures.

- [ ] **Step 6: Perform live visual acceptance**

Using the ignored live PAT and the repository-authorized child-process environment launch:

- Vision default and 640pt: project facts, pinned charts, and dashboard collection share one surface; no large empty middle column; late route controls remain usable.
- iPad regular and compact multitasking: regular shows one hub; compact retains list-to-detail; selection survives the crossing.
- Mac default/narrow/wide: one hub uses the content width; context menu, refresh, and open-in-new-window remain present.

Keep all live screenshots under ignored `build/impeccable/` and never copy live data into tests or committed docs.

- [ ] **Step 7: Commit the preservation coverage**

```bash
git add GetHog/Tests/DashboardConsistencyTests.swift \
  GetHogUITests/DashboardConsistencyUITests.swift \
  GetHogVision/UITests/VisionWindowTests.swift \
  GetHogMac/UITests/MacWindowSizeTests.swift
git commit -m "test: preserve dashboard hub state across platforms"
```

---

### Task 4: Integrate with the broader Impeccable fix loop

**Files:**
- Modify only files identified by the independent platform critique after evidence reconciliation.
- Do not change dashboard hub files unless a repeated rendered critique finds a concrete remaining defect.

**Interfaces:**
- Consumes: the completed hub and the authoritative all-platform route matrix.
- Produces: repeated Assessment A/B evidence and the final polish acceptance.

- [ ] **Step 1: Re-run isolated Vision, iPad, and Mac Assessment A**

Use current live PAT launches and review all dashboard root/detail states at the target widths. Compare against the exact screenshot acceptance from the design rather than against the pre-change screenshot.

- [ ] **Step 2: Reconcile only current supported findings**

Discard stale findings whose source seam or reproduction no longer exists. For every retained finding, add a focused RED before production edits.

- [ ] **Step 3: Run the final dashboard matrix**

Run the dashboard unit/UI slices plus a compile check for GetHog, GetHogMac, and GetHogVision. Report nonzero executed test counts.

- [ ] **Step 4: Commit the goal iteration**

Stage only the unified hub, confirmed critique fixes, and their tests. Verify `git diff --check`, inspect the staged diff, and create one focused goal-iteration commit. Do not push unless explicitly authorized.
