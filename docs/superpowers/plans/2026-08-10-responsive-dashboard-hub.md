# Responsive Dashboard Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sparse regular-width Dashboard summary column with a compact full-width project-signal band and a two-column pinned-chart preview across iPadOS, macOS, and visionOS.

**Architecture:** Keep the existing shared `DashboardHub` and its single `PageScaffold` scroll owner. Change only `ProjectOverviewContent` so its signal scene stacks a responsive summary band above the existing two-column `MasonryLayout`; expose stable container identifiers for rendered geometry checks. Compact iPhone remains on its existing list-to-detail path because it never mounts this hub.

**Tech Stack:** Swift 6, SwiftUI, XCTest/XCUITest, `ViewThatFits`, `MasonryLayout`, XcodeGen-generated project.

## Global Constraints

- Fresh rendered screenshots and measured geometry are the primary acceptance evidence for this visual work.
- Add focused tests only for stable, load-bearing responsive rules; do not manufacture a failing test for every visual adjustment.
- Keep one scroll owner for the loaded Dashboard hub and preserve selection, search, refresh, loading, error, and empty behavior.
- Keep the existing quiet-craft palette, typography, signal rule, section labels, and chart cards.
- Use semantic fitting and measured minimum chart widths, never device-name branches.
- Two preview columns remain only while both columns satisfy the existing 230pt minimum; otherwise the existing masonry layout may collapse to one.
- Preserve `GetHogMac/UITests/MacLiveAssessmentTests.swift` untouched and untracked.
- Serialize all Xcode builds and UI runs. Report authoritative nonzero counts.

---

### Task 1: Shared summary-band and pinned-preview composition

**Files:**
- Modify: `GetHog/Sources/Dashboards/ProjectOverview.swift:148-319`
- Modify: `GetHogUITests/DashboardConsistencyUITests.swift:7-120`
- Modify: `GetHogVision/UITests/VisionWindowTests.swift:6-60`
- Modify: `GetHogMac/UITests/MacWindowSizeTests.swift:18-75`

**Interfaces:**
- Consumes: `DashboardHub`'s single `PageScaffold`; `ProjectOverviewContent`; `MasonryLayout(columns:spacing:minColumnWidth:)`; existing `gethog.dashboard-hub` identifier.
- Produces: stable rendered anchors `gethog.dashboard-project-summary` and `gethog.dashboard-pinned-preview`; a full-width summary band above the pinned preview.

- [ ] **Step 1: Add stable rendered geometry anchors**

Attach clear background accessibility anchors without combining or hiding the existing text/chart descendants:

```swift
.background {
    Color.clear
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("gethog.dashboard-project-summary")
}
```

Use the same pattern with `gethog.dashboard-pinned-preview` on the preview container. Parse `ProjectOverview.swift` and run `git diff --check` before a simulator run.

- [ ] **Step 2: Strengthen the existing cross-platform geometry contracts**

In the iPad, Vision, and Mac hub tests, resolve both new anchors and the first two deterministic pinned tiles. Assert these literal relationships with a 12pt rendering tolerance:

```swift
XCTAssertGreaterThan(projectSummary.frame.width, hub.frame.width * 0.75)
XCTAssertGreaterThanOrEqual(pinnedPreview.frame.minY, projectSummary.frame.maxY - 12)
XCTAssertGreaterThan(pinnedPreview.frame.width, hub.frame.width * 0.75)
XCTAssertEqual(firstTile.frame.minY, secondTile.frame.minY, accuracy: 12)
XCTAssertGreaterThan(secondTile.frame.minX, firstTile.frame.maxX)
```

Retain the existing exactly-one-hub, exactly-one-collection, and dashboard-card reachability assertions. Add one kept `XCTAttachment` screenshot named with platform and rendered width after the geometry is ready.

- [ ] **Step 3: Capture the current layout as baseline evidence**

Run only one platform at a time. The current implementation is expected to show `projectSummary.frame.width` near the former 360pt rail and to fail the `> 75%` width requirement; screenshot evidence is the primary baseline.

```bash
DESTINATION_NAME='iPad Air 11-inch (M4)' WORKERS=1 scripts/run-ui-tests \
  GetHogUITests/DashboardConsistencyUITests/testRegularDashboardPinnedPreviewUsesTwoColumns
```

```bash
PLATFORM=vision WORKERS=1 scripts/run-ui-tests \
  GetHogVisionUITests/VisionWindowTests/testDashboardLandingUsesOneRegularWidthHub
```

Mac is attempted only if a deterministic test method can enter without the LocalAuthentication/foreground-window blocker:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' \
  -only-testing:GetHogMacUITests/MacWindowSizeTests/testDashboardLandingUsesOneHub
```

- [ ] **Step 4: Implement the responsive vertical composition**

Replace the side-by-side `summaryScene` branch with one `VStack`: `SignalRule`, `projectSummary`, then `pinnedPreview` when a pinned dashboard exists. Inside `projectSummary`, keep `SectionLabel` first and use `ViewThatFits(in: .horizontal)` to prefer a title-and-stats row, with the current vertical title-then-stats form as fallback:

```swift
VStack(alignment: .leading, spacing: Theme.Space.m) {
    SectionLabel(text: "Project signal", productMark: .dashboard)
    ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xxl) {
            projectTitle
            Spacer(minLength: Theme.Space.xl)
            projectMetrics
        }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            projectTitle
            projectMetrics
        }
    }
}
```

Extract `projectTitle` and `projectMetrics` as private views so both fits use one source of truth. Keep the existing stat labels and values exactly. Do not add a card background, custom geometry reader, device check, or third preview column.

- [ ] **Step 5: Verify the corrected screenshots and geometry**

Rerun the iPad and Vision commands from Step 3 and require authoritative 1/1 for each. Export and inspect the kept screenshots: the summary must read as a compact band; the first two pinned charts must sit side by side immediately underneath; no leading empty column, clipped title, or chart overlap is acceptable.

If Mac automation enters, require its focused method 1/1 and inspect its kept screenshot. If it enters zero methods or foreground ownership fails, report Mac rendered evidence as blocked rather than substituting source inspection.

- [ ] **Step 6: Run the affected regression classes**

```bash
DESTINATION_NAME='iPad Air 11-inch (M4)' WORKERS=1 scripts/run-ui-tests \
  GetHogUITests/DashboardConsistencyUITests
```

```bash
PLATFORM=vision WORKERS=1 scripts/run-ui-tests \
  GetHogVisionUITests/VisionWindowTests
```

Require nonzero xcresult totals and zero unexpected failures. Confirm compact iPhone still mounts no `gethog.dashboard-hub` in its existing topology tests.

- [ ] **Step 7: Commit the focused slice**

```bash
git add GetHog/Sources/Dashboards/ProjectOverview.swift \
  GetHogUITests/DashboardConsistencyUITests.swift \
  GetHogVision/UITests/VisionWindowTests.swift \
  GetHogMac/UITests/MacWindowSizeTests.swift
git commit -m "fix: use wide dashboard canvas"
```

### Task 2: General all-platform layout inventory

**Files:**
- Create: `build/impeccable/layout-sweep-2026-08-10/inventory.md`
- Read: `build/impeccable/recritique-a-20260809/`
- Read: all platform root and adaptation files under `GetHog/Sources`, `GetHogMac/Sources`, `GetHogVision/Sources`, `GetHogTV/Sources`, and `GetHogWatch/Sources`

**Interfaces:**
- Consumes: the deterministic screenshot corpus and the defect classes in `docs/superpowers/specs/2026-08-09-responsive-wide-layout-composition-design.md`.
- Produces: a complete page-by-page disposition and one or more focused follow-up plans; it does not change product code.

- [ ] **Step 1: Inventory every deterministic page**

Record each page/platform, screenshot path, primary task, width class, and disposition: `healthy`, `objective layout defect`, `qualitative choice`, or `evidence unavailable`. Evaluate hierarchy, responsive reflow, readable measure, clipping, control crowding, loading/error attachment, TV focus order, repeated decorative containers, and useful adjacent questions on large canvases.

- [ ] **Step 2: Validate every proposed defect against source**

For each objective defect, name the exact layout mechanism and file/line anchor. Reject findings that are only aesthetic preference or intentional master-detail context. Group accepted defects into non-overlapping implementation slices.

- [ ] **Step 3: Write focused follow-up plans**

Create one implementation plan per independent subsystem under `docs/superpowers/plans/`. Each plan must include exact files, screenshot/geometry acceptance, any load-bearing tests, serialized platform commands, and a focused commit boundary. Do not implement those plans inside this inventory task.

- [ ] **Step 4: Commit only durable plans, not generated evidence**

Keep the screenshot inventory under ignored `build/`. Commit each reviewed follow-up plan separately with a `docs:` commit message.
