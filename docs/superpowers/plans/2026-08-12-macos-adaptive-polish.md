# GetHog macOS Adaptive Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every GetHog macOS destination, window mode, replay surface, and widget usable and native from a 560×420 window through full screen, then prove it with deterministic and live CUA evidence.

**Architecture:** Replace the kept-alive `.sidebarAdaptable` tab shell with one native source-list `NavigationSplitView` that mounts only the selected destination. The detail column measures its real width and injects a writable Mac size class into the existing shared roots, reusing their tested compact drill-in and regular split topologies. Systemic Mac presentation rules—row rhythm, desktop hit targets, replay windows, and display-safe frame restoration—live behind small pure policies with unit tests.

**Tech Stack:** Swift 6, SwiftUI, AppKit, WidgetKit, Swift Testing, XCTest/XCUITest, XcodeGen 2.46+, CUA macOS VM.

## Global Constraints

- Preserve the existing warm-cream, deep-teal, SF Symbols, `Theme`, and `SeriesPalette` visual world.
- Use actual content width: compact below 720 pt, regular at or above 720 pt.
- Main windows remain freely resizable down to 560×420 pt; do not hide layout defects behind a large minimum.
- Narrow list/detail selection drills into detail in the same window; a separate window is an explicit secondary action.
- Only the selected Mac destination may own toolbar, title, and `.searchable` modifiers.
- Mac list cards have 6 pt of visual separation; iOS/iPadOS behavior must not regress.
- Expanded replay on macOS is a resizable native window with 640×480 minimum and 1,100×760 default.
- Widgets remain snapshot-only; no widget target may gain network-client entitlement or API access.
- All committed fixtures, tests, docs, and screenshots are deterministic and synthetic; live screenshots stay ignored under `build/`.
- Preserve the pre-existing uncommitted changes in both `GetHogMac` entitlement files unless their owner explicitly resolves them.

---

### Task 1: Adaptive Mac source-list shell

**Files:**
- Modify: `GetHog/Sources/Common/MacAdaptations.swift`
- Modify: `GetHogMac/Sources/MacRootView.swift`
- Modify: `GetHogMac/Tests/MacShellTests.swift`
- Modify: `GetHogMac/UITests/MacWindowSizeTests.swift`
- Modify: `GetHogMac/UITests/MacCommandContractTests.swift`
- Replace: `GetHogMac/UITests/MacSidebarCustomizationTests.swift`

**Interfaces:**
- Produces: `MacWindowLayout.sizeClass(forContentWidth:) -> UserInterfaceSizeClass`
- Produces: writable `EnvironmentValues.horizontalSizeClass`
- Produces: `MacSidebarExpansion` persistence policy and `MacRootView.sidebarSections`
- Preserves: `MacRootView.looseTabs`, `MacRootView.sections`, `OpenTabAction`, `OpenDetails`, `searchPath`

- [ ] **Step 1: Write failing policy tests**

Add tests that require widths 719/720 to resolve compact/regular, default expanded groups to be Analyze + Monitor, every non-Settings tab to appear exactly once, and resetting expansion to restore those defaults.

```swift
@Test("content width, not device, selects compact navigation")
func contentWidthClassifiesNavigation() {
    #expect(MacWindowLayout.sizeClass(forContentWidth: 719) == .compact)
    #expect(MacWindowLayout.sizeClass(forContentWidth: 720) == .regular)
}
```

- [ ] **Step 2: Run the Mac unit suite and verify RED**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -only-testing:GetHogMacTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: compile failure because `MacWindowLayout` and `MacSidebarExpansion` do not exist.

- [ ] **Step 3: Make the size-class environment writable**

Replace the get-only shim with a private `EnvironmentKey` whose default is `.regular`:

```swift
private struct MacHorizontalSizeClassKey: EnvironmentKey {
    static let defaultValue: UserInterfaceSizeClass? = .regular
}

extension EnvironmentValues {
    var horizontalSizeClass: UserInterfaceSizeClass? {
        get { self[MacHorizontalSizeClassKey.self] }
        set { self[MacHorizontalSizeClassKey.self] = newValue }
    }
}
```

- [ ] **Step 4: Implement pure width and expansion policies**

Use a 720 pt content breakpoint and a stable set of expanded section IDs. Parse persisted comma-separated IDs against `AppTab.sections` so stale names are discarded rather than resurrected.

- [ ] **Step 5: Replace `TabView(.sidebarAdaptable)` with one native split shell**

Build one `NavigationSplitView` whose sidebar is `List(selection:)`, uses `.listStyle(.sidebar)`, has a loose Search row, and has collapsible `Section(isExpanded:)` groups. Mount only `selectedTab`. Put a `GeometryReader` in the detail column, inject the size class, and choose whether the selected root owns its navigation container with `tab.ownsNavigationContainer(compact:)`.

- [ ] **Step 6: Update UI tests for the new contract**

Require exact 640×480 and 800×600 achieved frames, a single content pane after selecting an Event/Person/Session, a hittable Back control after drill-in, a correctly titled sidebar menu item in both states, and search text disappearing when switching destinations. Replace drag-reorder persistence with section-collapse persistence.

- [ ] **Step 7: Run focused units and UI tests; verify GREEN**

Run the unit command from Step 2, then:

```bash
PLATFORM=mac WORKERS=1 scripts/run-ui-tests \
  GetHogMacUITests/MacWindowSizeTests \
  GetHogMacUITests/MacCommandContractTests \
  GetHogMacUITests/MacSidebarCustomizationTests
```

Expected: nonzero test count, zero failures.

- [ ] **Step 8: Commit the adaptive shell**

```bash
git add GetHog/Sources/Common/MacAdaptations.swift \
  GetHogMac/Sources/MacRootView.swift GetHogMac/Tests/MacShellTests.swift \
  GetHogMac/UITests/MacWindowSizeTests.swift \
  GetHogMac/UITests/MacCommandContractTests.swift \
  GetHogMac/UITests/MacSidebarCustomizationTests.swift
git commit -m "fix: adapt the Mac shell to window width"
```

---

### Task 2: Desktop list rhythm, control density, and wide galleries

**Files:**
- Modify: `GetHog/Sources/Common/PlatformAffordances.swift`
- Modify: all shared list-card background call sites returned by `rg -l 'padding\(\.vertical, 1\)' GetHog/Sources`
- Modify: `GetHog/Sources/Templates/DashboardTemplatesRoot.swift`
- Add: `GetHogMac/Tests/MacPresentationMetricsTests.swift`
- Add: `GetHogMac/UITests/MacListRhythmTests.swift`

**Interfaces:**
- Produces: `PlatformPresentationMetrics.minimumInteractiveLength`
- Produces: `PlatformPresentationMetrics.listCardVerticalInset`
- Produces: `DashboardTemplatesRoot.minimumCardWidth`

- [ ] **Step 1: Write failing metric tests**

```swift
@Test("Mac controls and list cards use desktop metrics")
func desktopMetrics() {
    #expect(PlatformPresentationMetrics.minimumInteractiveLength == 28)
    #expect(PlatformPresentationMetrics.listCardVerticalInset == 3)
    #expect(DashboardTemplatesRoot.minimumCardWidth == 340)
}
```

- [ ] **Step 2: Write a failing Events geometry test**

At 800×600 and 1,280×820, read the first two Event row frames and require at least 4 pt between their visible card backgrounds. Add equivalent representative checks for People, Sessions, Notebooks, Max, and Renders so a global fix cannot leave the long tail behind.

- [ ] **Step 3: Run the focused tests and verify RED**

Expected: missing metric type and zero-gap geometry.

- [ ] **Step 4: Implement platform metrics and migrate row backgrounds**

On macOS use 28 pt pointer targets and 3 pt vertical card-background inset; elsewhere keep 44 pt and 1 pt. Replace hard-coded row-card `.padding(.vertical, 1)` values with the shared metric only where the padding belongs to a clipped list-row background. Do not change chip, timeline, or scrubber padding with a different semantic role.

- [ ] **Step 5: Increase Mac template card measure**

Use 340 pt adaptive minimum on macOS and retain 260 pt on other platforms. Full screen must produce readable cards, not six narrow columns.

- [ ] **Step 6: Run units and list rhythm UI tests; verify GREEN**

Run Mac units and `MacListRhythmTests`; require nonzero count and zero failures.

- [ ] **Step 7: Commit the presentation metrics**

Commit only the shared metric, audited row call sites, template grid, and tests.

---

### Task 3: Native expanded replay window

**Files:**
- Modify: `GetHog/Sources/Common/MacAdaptations.swift`
- Modify: `GetHog/Sources/Player/ReplayPlayerView.swift`
- Modify: `GetHog/Sources/Player/ExpandedReplayView.swift`
- Add: `GetHogMac/Tests/MacReplayWindowTests.swift`
- Modify: `GetHogMac/UITests/MacReplayTransportTests.swift`

**Interfaces:**
- Produces: `MacReplayWindowMetrics.defaultSize == 1100×760`
- Produces: `MacReplayWindowMetrics.minimumSize == 640×480`
- Produces: `MacReplayWindowController` owning one resizable `NSWindow`
- Extends: `ExpandedReplayView.closeAction: (() -> Void)?`

- [ ] **Step 1: Write failing window-policy and close-once tests**

Pin the sizes and the handoff's idempotent close behavior. Add an XCUITest that clicks “Expand replay,” requires a second window at least 640×480, verifies a replay stage and transport inside it, invokes full screen, exits full screen, closes with Command-W, and confirms the inline stage returns.

- [ ] **Step 2: Run focused tests and verify RED**

Expected: one 470×147 sheet and no second native window.

- [ ] **Step 3: Implement the AppKit replay window**

Host `ExpandedReplayView` in `NSHostingController`, set titled/closable/miniaturizable/resizable/full-size-content-view style masks, minimum/default sizes, and a window title containing the synthetic recording person. Reuse the existing `ReplayLoader`; do not create a client or fetch path in the window controller.

- [ ] **Step 4: Make every close path hand off once**

Add `.onDisappear { finishOnce() }`. The toolbar Close button runs `finishOnce()` then `closeAction` on macOS or `dismiss()` elsewhere. The red button and Command-W therefore reach the same handoff through disappearance.

- [ ] **Step 5: Remove the macOS full-screen-cover sheet shim**

Keep the call only in non-macOS compilation branches so a future shared call cannot silently become a tiny sheet.

- [ ] **Step 6: Run replay units/UI tests and verify GREEN**

Run `GetHogMacTests`, `MacReplayTransportTests`, and existing replay coordination/interaction tests in `GetHogTests`.

- [ ] **Step 7: Commit the replay window**

Commit the window controller, view changes, shim removal, and tests together.

---

### Task 4: Display-safe window restoration and native commands

**Files:**
- Modify: `GetHogMac/Sources/MacMenuBarExtra.swift`
- Modify: `GetHogMac/Sources/GetHogMacApp.swift`
- Modify: `GetHogMac/Tests/MacMenuBarTests.swift`
- Add: `GetHogMac/UITests/MacWindowRestorationTests.swift`

**Interfaces:**
- Produces: `MacWindowPlacement.clampedFrame(_:to:) -> CGRect`
- Produces: `MacWindowPlacement.shouldClamp(styleMask:) -> Bool`

- [ ] **Step 1: Write failing rectangle-policy tests**

Cover right/left/top/bottom overflow, window larger than screen, already-valid frame identity, and full-screen exclusion.

- [ ] **Step 2: Run Mac units and verify RED**

- [ ] **Step 3: Implement clamping in `MacAppDelegate`**

Observe window-becomes-main and display-parameter changes. Select the window's screen, then the greatest-intersection screen, then the nearest screen. Clamp ordinary main-capable windows to `visibleFrame`; never mutate native full-screen, menu-extra, or panel windows.

- [ ] **Step 4: Set explicit scene sizing**

Main default 1,200×780 with content minimum 560×420; tear-offs keep 1,000×700. Preserve user resizing and native zoom/full-screen.

- [ ] **Step 5: Add UI coverage for native commands**

Exercise New Window, Close, Minimize, Zoom, Enter/Exit Full Screen, Move & Resize Left/Right, Return to Previous Size, Settings, About, sidebar toggle, and dashboard/recording tear-offs. Verify window counts and achieved bounds rather than menu existence alone.

- [ ] **Step 6: Run units/UI tests and verify GREEN**

- [ ] **Step 7: Commit window policy**

---

### Task 5: Settings, product contract, and stale verification docs

**Files:**
- Modify: `GetHogMac/Sources/MacSettingsScene.swift`
- Modify: `GetHogMac/Tests/MacShellTests.swift`
- Modify: `PRODUCT.md`
- Modify: `docs/superpowers/2026-08-06-macos-verification-checklist.md`

**Interfaces:**
- Replaces: reset of `TabViewCustomization` with reset of persisted source-list expansion
- Documents: macOS as a first-class adaptive Apple platform

- [ ] **Step 1: Write failing Settings reset test**

Require the Display pane to expose “Reset Sidebar Sections” and restore Analyze + Monitor expansion.

- [ ] **Step 2: Run Mac units and verify RED**

- [ ] **Step 3: Replace stale Settings control and copy**

Keep the four native panes. Do not add card containers. Ensure form rows use desktop control sizes and useful width without stretching explanatory prose.

- [ ] **Step 4: Correct durable documentation**

Update `PRODUCT.md` to name Mac among the adaptive native clients. Replace the stale “minimum 1152 pt / sidebar never collapses” checklist with the 560×420 adaptive contract and current commands.

- [ ] **Step 5: Run units and verify GREEN, then commit**

---

### Task 6: Widget distribution and live behavior

**Files:**
- Inspect without overwriting owner changes: `GetHogMac/Support/GetHogMac.entitlements`
- Inspect without overwriting owner changes: `GetHogMac/Support/GetHogMac-Distribution.entitlements`
- Modify when non-overlapping: `GetHogMacWidgets/Support/GetHogMacWidgets-Distribution.entitlements`
- Modify: `GetHogMac/Tests/MacWidgetLogicTests.swift`
- Add: `GetHogMac/UITests/MacWidgetContractTests.swift`
- Modify: `DEVELOPMENT.md`

**Interfaces:**
- Preserves: 3 Metric + 3 Health + 2 Flag family variants
- Preserves: `WidgetCache` snapshot-only data flow
- Produces: a distribution entitlement parity verifier that reports key names only

- [ ] **Step 1: Add failing entitlement-parity tests**

Parse app and extension Distribution entitlements without logging values. Require one matching application group, require the app's network-client key, and forbid that key in the extension.

- [ ] **Step 2: Run Mac units and record RED or owner-conflict status**

If the failure is solely in either pre-existing modified app entitlement file, do not overwrite it. Continue all non-overlapping widget work and retain the exact signed-data acceptance gap for final resolution.

- [ ] **Step 3: Add widget UI contracts**

Pin gallery discoverability, all eight supported family previews, installed-widget honest unshared copy, native resize options, configuration UI, and app foreground/deep-link behavior.

- [ ] **Step 4: Run unit and live widget tests**

Use the disposable CUA VM. For the ad-hoc Debug build, require honest unshared copy. If a valid signed Distribution build is available, write a snapshot in the app, reload WidgetKit timelines, and require the installed widget to display the same synthetic metric and freshness.

- [ ] **Step 5: Commit only non-conflicting widget changes**

---

### Task 7: Exhaustive deterministic Mac surface and edge-case verification

**Files:**
- Modify: `GetHogMac/UITests/MacSurfaceSweepTests.swift`
- Add/modify focused UI tests under `GetHogMac/UITests/`
- Modify: `GetHog/Sources/App/DemoTransport.swift` only for deterministic missing edge-state seams
- Modify: matching `GetHog/Tests/DemoTransportTests.swift`

**Interfaces:**
- Produces: authoritative 34-destination matrix at five window modes
- Produces: deterministic launch seams for empty, loading, failed, no-match, long text, and stale states where absent

- [ ] **Step 1: Inventory every destination and required state**

Derive the list from `AppTab.sections`, not a copied list. For every destination record loaded anchor, empty/error/no-match availability, navigation affordance, toolbar/search ownership, and representative long-content risk.

- [ ] **Step 2: Add missing deterministic seams test-first**

For any absent state, add a named `GETHOG_DEMO_*` launch environment, first pin its transport response in `DemoTransportTests`, then consume it from a focused UI test. Never use live customer data for edge cases.

- [ ] **Step 3: Run the complete Mac UI target**

```bash
PLATFORM=mac WORKERS=1 scripts/run-ui-tests
```

Expected: nonzero authoritative xcresult count and zero failures.

- [ ] **Step 4: Run shared regression suites serially**

```bash
swift test --package-path GetHogKit
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests
```

Report actual nonzero executed counts.

- [ ] **Step 5: Commit deterministic audit coverage**

---

### Task 8: Build, privacy, CUA, live PAT, and final completion audit

**Files:**
- Generate ignored artifacts under: `build/impeccable/mac-cua-final/`
- Update: `docs/superpowers/specs/2026-08-12-macos-adaptive-polish-design.md` only if implementation truth changed

**Interfaces:**
- Consumes every prior task's production and test contracts
- Produces final visual matrix, native-feature evidence, and requirement-by-requirement verdict

- [ ] **Step 1: Regenerate and inspect project metadata when needed**

Run `xcodegen generate` after any `project.yml` or target-source changes and inspect the guarded watch embed phase rather than weakening it.

- [ ] **Step 2: Run fresh Debug and Release builds**

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS'
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -configuration Release CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Run privacy/public-tree gates**

```bash
swift test --package-path GetHogKit --filter FixturePrivacyTests
scripts/verify-public-tree
```

- [ ] **Step 4: Run bounded deterministic CUA visual pass**

At 640×480, 800×600, 1,000×700, 1,280×820, and native full screen, capture all 34 destinations. Exercise light/dark, increased contrast, Reduce Motion, keyboard-only navigation, sidebar collapse/restore, search switching, narrow drill-in/Back, native menu/window commands, Settings panes, replay window, and tear-offs. Make one consolidated defect batch, fix it, and use at most one confirmation pass.

- [ ] **Step 5: Run live PAT read-only pass**

Stream the PAT from `.env.local` into the disposable VM launch environment without printing or persisting it. Visit all 34 destinations, replay, Settings, menu bar, and widget deep links. Save screenshots only to ignored `build/` and redact any user-identifying image from handoff.

- [ ] **Step 6: Verify widgets**

Render all eight gallery variants, install each family at least once, resize through every supported family, open configuration, verify fresh/stale/empty/unshared copy, and click through to the app. Record signed shared-data verification separately from ad-hoc Debug behavior.

- [ ] **Step 7: Perform the completion audit**

Read the design spec line by line. For every requirement identify direct source, test, build, screenshot, or live-runtime evidence. Treat missing or indirect evidence as incomplete and continue working.

- [ ] **Step 8: Commit final corrections and report**

Commit only reviewed source/tests/docs. Do not stage live screenshots, credentials, or the owner's entitlement changes. Report exact test counts, build configurations, visual matrix, widget results, and any hardware/signing-only acceptance gap.
