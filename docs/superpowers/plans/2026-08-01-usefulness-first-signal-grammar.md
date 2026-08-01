# Usefulness-First Signal Grammar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give GetHog an unmistakable, useful-first visual identity across Dashboards, Events, Sessions, and Feature Flags through original vector marks, truthful overview compositions, semantic object glyphs, and restrained motion.

**Architecture:** A closed vector vocabulary supplies five product marks, a small set of product-specific object glyphs, a Signal Rule, and an optional quill stitch. Existing components gain backward-compatible opt-in hooks, while each Core Four overview owns a distinct composition of its already-loaded data rather than receiving a generic hero component. Dense lists and details use the same grammar at lower intensity, and motion responds only to existing successful state transitions.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, XCTest/XCUITest, XcodeGen, existing GetHog `Theme`/`DesignKit`/`Components`, deterministic demo transport and screenshot harness.

## Global Constraints

- Work directly on `main`, as previously approved by the user; do not create or switch branches.
- `project.yml` is authoritative; regenerate `GetHog.xcodeproj` with `xcodegen generate` after adding Swift files.
- Use four-space Swift indentation and Swift 6 strict concurrency.
- Preserve every unrelated worktree change. In particular, `DashboardDetailView.swift` currently contains unrelated dashboard graph-state work; stage only Signal Grammar hunks with `git add -p` and inspect `git diff --cached` before committing.
- Use only deterministic synthetic content in retained tests, screenshots, fixtures, examples, and documentation. Never retain live PostHog values, credentials, customer data, or copied API payloads.
- Keep the visible product name `GetHog` everywhere.
- Use `Theme` and the new `Theme.SignalChrome` tokens for chrome. `SeriesPalette` remains exclusive to encoded chart data and must not color card chrome, product marks, glyphs, rules, or summary scenes.
- Keep PostHog trademark distance: no official wordmark, hedgehog silhouette, yellow face, blue square, flame crest, crown, or copied logo geometry.
- Do not add gradients, arbitrary blobs, glass-on-glass layers, decorative fake data, generic motivational copy, or a second card around an existing card.
- Standard controls keep their existing symbols and behavior. Do not replace tab destinations, back buttons, playback controls, toggles, menus, disclosure indicators, retry buttons, destructive symbols, or chart interaction with branded geometry.
- Signal Summary Scenes may use additional space only to synthesize real, correctly scoped data already available under the screen's existing cost contract. They must not duplicate the same summary below.
- Populated compact screens contain no full mascot. Existing Signal Hog vignettes remain limited to their approved empty, all-clear, onboarding, About, and completion states.
- Brand marks and stitches adjacent to descriptive text are accessibility-hidden. Status, rollout, friction, errors, timestamps, freshness, and scope remain explicit text.
- At accessibility sizes, decoration disappears before text or controls compress. Visual order and accessibility order must remain identical.
- New motion lasts 160–240 milliseconds, plays once per successful state change, never loops, never delays data or interaction, and settles immediately with Reduce Motion.
- Do not change networking, authentication, caching, rate-limit behavior, data computation, filtering, search semantics, chart semantics, replay parsing, flag-editing behavior, widget behavior, or error classification.
- Do not use `xcrun simctl` or pass `-derivedDataPath`.
- For every test command, confirm the intended suite ran with a nonzero executed-test count; `TEST SUCCEEDED` or exit code alone is insufficient.

---

## File Map

### New production files

- `GetHog/Sources/Common/BrandProductMarkView.swift` — closed product-mark enum, normalized vector geometry, optical sizing, and Project Stamp.
- `GetHog/Sources/Common/BrandObjectGlyphView.swift` — closed object-glyph enum and product-specific row glyph rendering.
- `GetHog/Sources/Common/SignalGrammarView.swift` — Signal Rule, quill stitch, and low-level summary-scene decoration.
- `GetHog/Sources/Dashboards/DashboardOverviewFacts.swift` — pure, testable facts used by `ProjectOverview`.
- `GetHog/Sources/Events/EventOverviewFacts.swift` — pure feed-scope and frequency facts used by `EventsOverview`.
- `GetHog/Sources/Sessions/SessionOverviewFacts.swift` — pure replay-scope and triage facts used by `SessionsOverview`.
- `GetHog/Sources/Flags/FlagOverviewFacts.swift` — pure flag totals and rollout facts used by `FlagsOverview`.

### New test files

- `GetHog/Tests/BrandProductMarkTests.swift` — closed mark contract, palette floor, and vector rendering.
- `GetHog/Tests/SignalGrammarComponentTests.swift` — branded glyph/rule rendering and legacy component fallback.
- `GetHog/Tests/SignalGrammarDashboardTests.swift` — dashboard overview facts and dashboard glyph mapping.
- `GetHog/Tests/SignalGrammarEventTests.swift` — event summary scope, stable ranking, and event-kind glyph mapping.
- `GetHog/Tests/SignalGrammarSessionTests.swift` — session totals, triage facts, and replay glyph mapping.
- `GetHog/Tests/SignalGrammarFlagTests.swift` — status/rollout facts and flag-kind glyph mapping.
- `GetHogUITests/SignalGrammarAccessibilityTests.swift` — rendered ProjectSwitcher semantics and singular Core Four overview landmarks.

### Modified shared files

- `GetHog/Sources/Common/Theme.swift:9-220` — Signal Grammar chrome palette.
- `GetHog/Sources/Common/Components.swift:415-552` — `SectionLabel` product-mark opt-in and `CardHeader` optional quill stitch.
- `GetHog/Sources/Common/DesignKit.swift:195-365` — branded `RowGlyph`/`DataRow` opt-in without changing existing call sites.
- `GetHog/Sources/Common/BrandMotion.swift:1-70` — pure one-shot confirmation values and view modifier.
- `GetHog/Sources/App/RootView.swift:948-1030` — Project Stamp in the existing `ProjectSwitcher` label.
- `GetHog.xcodeproj/project.pbxproj` — regenerated file membership only.

### Modified Core Four files

- `GetHog/Sources/Dashboards/ProjectOverview.swift:16-155`
- `GetHog/Sources/Dashboards/DashboardsRoot.swift:130-190`
- `GetHog/Sources/Dashboards/DashboardDetailView.swift:540-610`
- `GetHog/Sources/Dashboards/TileStyle.swift:1-75`
- `GetHog/Sources/Events/EventsOverview.swift:17-150`
- `GetHog/Sources/Events/EventsRoot.swift:440-605`
- `GetHog/Sources/Sessions/SessionsOverview.swift:17-180`
- `GetHog/Sources/Sessions/SessionsRoot.swift:272-470`
- `GetHog/Sources/Sessions/SessionTimelineView.swift:240-275`
- `GetHog/Sources/Flags/FlagsOverview.swift:17-185`
- `GetHog/Sources/Flags/FlagsRoot.swift:190-295`
- `GetHog/Sources/Flags/FlagDetailView.swift:325-430`

### Existing verification surfaces used without source changes

- `GetHogUITests/Screenshots/RootScreenshotTests.swift:10-25` — existing Core Four captures are the review surface.
- `GetHogUITests/Screenshots/StateScreenshotTests.swift:195-225` — existing dashboard-detail capture is the populated-card review surface.

---

### Task 1: Establish the product-mark and chrome contract

**Files:**
- Create: `GetHog/Sources/Common/BrandProductMarkView.swift`
- Create: `GetHog/Tests/BrandProductMarkTests.swift`
- Modify: `GetHog/Sources/Common/Theme.swift:9-220`
- Modify: `GetHog/Tests/StatusInkContrastTests.swift:1-180`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Theme.accent`, `Theme.accentWarm`, `Theme.Ink.tertiary`.
- Produces: `BrandProductMark`, `BrandProductMarkView(mark:size:tint:)`, and `Theme.SignalChrome.{teal,coral,clay,ink,all}`.

- [ ] **Step 1: Write the failing closed-contract and render tests**

Create `BrandProductMarkTests.swift`:

```swift
import SwiftUI
import Testing

@testable import GetHog

@Suite("Signal Grammar product marks")
@MainActor
struct BrandProductMarkTests {
    @Test("The vocabulary is closed to the Core Four and Project Stamp")
    func closedVocabulary() {
        #expect(BrandProductMark.allCases == [
            .dashboard, .event, .session, .flag, .projectStamp,
        ])
    }

    @Test("Every mark renders at toolbar, section, and summary sizes")
    func rendersAtIntendedSizes() {
        for mark in BrandProductMark.allCases {
            for size in [14.0, 18.0, 32.0, 72.0] {
                let renderer = ImageRenderer(
                    content: BrandProductMarkView(mark: mark, size: size)
                )
                #expect(renderer.uiImage != nil, "\(mark) failed at \(size)pt")
            }
        }
    }
}
```

In `StatusInkContrastTests.swift`, add this test inside the existing suite so it can reuse the local `Pixel` helper:

```swift
@Test("Signal chrome clears the 3:1 non-text floor")
func signalChromeClearsNonTextFloor() {
    for tint in Theme.SignalChrome.all {
        for (surfaceName, surface) in Self.surfaces {
            for style in Self.appearances {
                let ground = Pixel(surface, style)
                let mark = Pixel(tint, style).over(ground)
                #expect(
                    mark.contrast(with: ground) >= 3.0,
                    "signal chrome on \(surfaceName) in \(style)"
                )
            }
        }
    }
}
```

- [ ] **Step 2: Generate the project and verify the red state**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/BrandProductMarkTests \
  -only-testing:GetHogTests/StatusInkContrastTests
```

Expected: compile failure because `BrandProductMark`, `BrandProductMarkView`, and `Theme.SignalChrome` do not exist. Confirm the failure names those missing contracts rather than an invalid test filter.

- [ ] **Step 3: Add the measured Signal Grammar palette**

Add inside `Theme`:

```swift
enum SignalChrome {
    static let teal = Theme.accent
    static let coral = Theme.accentWarm
    static let clay = Color(
        light: Color(hex: 0x865A3B),
        dark: Color(hex: 0xD6A178)
    )
    static let ink = Theme.Ink.tertiary

    static let all = [teal, coral, clay, ink]
}
```

Keep these as chrome tokens. Do not add them to `SeriesPalette` and do not use them to encode chart series.

- [ ] **Step 4: Implement normalized, deterministic product marks**

Create `BrandProductMarkView.swift` with the following structure and exact normalized geometry. The points intentionally share the Signal Hog quill angle and a 0–1 optical box:

```swift
import SwiftUI

enum BrandProductMark: String, CaseIterable, Equatable {
    case dashboard
    case event
    case session
    case flag
    case projectStamp

    fileprivate var lines: [[CGPoint]] {
        switch self {
        case .dashboard:
            [
                [.init(x: 0.12, y: 0.80), .init(x: 0.88, y: 0.80)],
                [.init(x: 0.24, y: 0.70), .init(x: 0.43, y: 0.30)],
                [.init(x: 0.52, y: 0.70), .init(x: 0.72, y: 0.18)],
            ]
        case .event:
            [
                [.init(x: 0.08, y: 0.55), .init(x: 0.28, y: 0.55),
                 .init(x: 0.40, y: 0.22), .init(x: 0.56, y: 0.80),
                 .init(x: 0.70, y: 0.40), .init(x: 0.92, y: 0.40)],
            ]
        case .session:
            [
                [.init(x: 0.50, y: 0.08), .init(x: 0.77, y: 0.18),
                 .init(x: 0.92, y: 0.50), .init(x: 0.77, y: 0.82),
                 .init(x: 0.50, y: 0.92), .init(x: 0.23, y: 0.82),
                 .init(x: 0.08, y: 0.50), .init(x: 0.23, y: 0.18),
                 .init(x: 0.50, y: 0.08)],
            ]
        case .flag:
            [
                [.init(x: 0.25, y: 0.88), .init(x: 0.25, y: 0.16)],
                [.init(x: 0.27, y: 0.20), .init(x: 0.78, y: 0.28),
                 .init(x: 0.61, y: 0.46), .init(x: 0.80, y: 0.62),
                 .init(x: 0.27, y: 0.54)],
            ]
        case .projectStamp:
            []
        }
    }

    fileprivate var dots: [CGPoint] {
        switch self {
        case .session:
            [.init(x: 0.50, y: 0.26), .init(x: 0.68, y: 0.58), .init(x: 0.32, y: 0.58)]
        case .dashboard, .event, .flag, .projectStamp:
            []
        }
    }
}

struct BrandProductMarkView: View {
    let mark: BrandProductMark
    var size: CGFloat = 18
    var tint: Color = Theme.SignalChrome.teal

    var body: some View {
        ZStack {
            if mark == .projectStamp {
                Capsule(style: .continuous)
                    .fill(Theme.SignalChrome.clay.opacity(0.26))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(tint, lineWidth: max(1.5, size * 0.10))
                    }
                    .frame(width: size, height: size * 0.72)
                HStack(spacing: size * 0.22) {
                    Circle().frame(width: size * 0.11, height: size * 0.11)
                    Circle().frame(width: size * 0.11, height: size * 0.11)
                }
                .foregroundStyle(tint)
            } else {
                NormalizedMarkLines(lines: mark.lines)
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: max(1.5, size * 0.10),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                ForEach(Array(mark.dots.enumerated()), id: \.offset) { _, dot in
                    Circle()
                        .fill(tint)
                        .frame(width: size * 0.14, height: size * 0.14)
                        .position(x: dot.x * size, y: dot.y * size)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct NormalizedMarkLines: Shape {
    let lines: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        Path { path in
            for line in lines where line.count > 1 {
                path.move(to: scaled(line[0], in: rect))
                for point in line.dropFirst() {
                    path.addLine(to: scaled(point, in: rect))
                }
            }
        }
    }

    private func scaled(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }
}
```

Optically inspect all five at 14, 18, 32, and 72 points. Correct coordinates rather than adding per-call offsets.

- [ ] **Step 5: Regenerate and run the focused green tests**

Run the Step 2 command again. Expected: both suites pass with a nonzero executed count and every palette value clears 3:1 against card and page surfaces in light and dark appearances.

- [ ] **Step 6: Commit the isolated foundation**

```bash
git add GetHog.xcodeproj/project.pbxproj \
  GetHog/Sources/Common/Theme.swift \
  GetHog/Sources/Common/BrandProductMarkView.swift \
  GetHog/Tests/BrandProductMarkTests.swift \
  GetHog/Tests/StatusInkContrastTests.swift
git diff --cached --check
git commit -m "Add Signal Grammar product marks"
```

---

### Task 2: Add backward-compatible component seams

**Files:**
- Create: `GetHog/Sources/Common/BrandObjectGlyphView.swift`
- Create: `GetHog/Sources/Common/SignalGrammarView.swift`
- Create: `GetHog/Tests/SignalGrammarComponentTests.swift`
- Modify: `GetHog/Sources/Common/Components.swift:415-552`
- Modify: `GetHog/Sources/Common/DesignKit.swift:195-365`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `BrandProductMarkView`, `Theme.SignalChrome`.
- Produces: `BrandObjectGlyph`, `BrandObjectGlyphView`, `BrandQuillStitch`, `SignalRule`, `SectionLabel.productMark`, `DataRow.brandGlyph`, and `CardHeader.showsBrandStitch`.

- [ ] **Step 1: Write failing render and fallback tests**

Create `SignalGrammarComponentTests.swift`:

```swift
import SwiftUI
import Testing

@testable import GetHog

@Suite("Signal Grammar components")
@MainActor
struct SignalGrammarComponentTests {
    @Test("Every object glyph renders", arguments: BrandObjectGlyph.allCases)
    func objectGlyphRenders(_ glyph: BrandObjectGlyph) {
        let renderer = ImageRenderer(
            content: BrandObjectGlyphView(glyph: glyph, size: 24)
        )
        #expect(renderer.uiImage != nil)
    }

    @Test("Legacy and branded rows both render")
    func rowFallbacksRender() {
        let legacy = ImageRenderer(content: DataRow(glyph: "bolt", title: "Legacy"))
        let branded = ImageRenderer(content: DataRow(
            glyph: "bolt",
            brandGlyph: .event,
            title: "Branded"
        ))
        #expect(legacy.uiImage != nil)
        #expect(branded.uiImage != nil)
    }

    @Test("Section labels and card headers remain opt-in")
    func passiveChromeRenders() {
        #expect(ImageRenderer(content: SectionLabel(text: "Plain")).uiImage != nil)
        #expect(ImageRenderer(content: SectionLabel(
            text: "Events",
            productMark: .event
        )).uiImage != nil)
        #expect(ImageRenderer(content: CardHeader(
            title: "Daily active people",
            showsBrandStitch: true
        )).uiImage != nil)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarComponentTests
```

Expected: compile failure for the missing glyph enum and opt-in parameters.

- [ ] **Step 3: Implement the closed object-glyph vocabulary**

Create `BrandObjectGlyphView.swift`:

```swift
import SwiftUI

enum BrandObjectGlyph: String, CaseIterable, Equatable {
    case dashboard
    case generatedDashboard
    case event
    case screenEvent
    case exceptionEvent
    case featureFlagEvent
    case session
    case mobileSession
    case errorSession
    case flag
    case multivariateFlag
    case archivedFlag

    var product: BrandProductMark {
        switch self {
        case .dashboard, .generatedDashboard: .dashboard
        case .event, .screenEvent, .exceptionEvent, .featureFlagEvent: .event
        case .session, .mobileSession, .errorSession: .session
        case .flag, .multivariateFlag, .archivedFlag: .flag
        }
    }
}

struct BrandObjectGlyphView: View {
    let glyph: BrandObjectGlyph
    var size: CGFloat = 22
    var tint: Color = Theme.SignalChrome.teal

    var body: some View {
        ZStack(alignment: .topTrailing) {
            BrandProductMarkView(mark: glyph.product, size: size, tint: tint)
            modifier
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var modifier: some View {
        switch glyph {
        case .dashboard, .event, .session, .flag:
            EmptyView()
        case .generatedDashboard:
            QuillCuts(size: size * 0.34, tint: Theme.SignalChrome.coral)
        case .screenEvent:
            RoundedRectangle(cornerRadius: size * 0.06)
                .stroke(Theme.SignalChrome.clay, lineWidth: max(1, size * 0.07))
                .frame(width: size * 0.34, height: size * 0.27)
        case .exceptionEvent, .errorSession:
            Circle()
                .fill(Theme.Status.critical)
                .frame(width: size * 0.24, height: size * 0.24)
        case .featureFlagEvent, .multivariateFlag:
            Circle()
                .fill(Theme.SignalChrome.coral)
                .frame(width: size * 0.22, height: size * 0.22)
        case .mobileSession:
            Capsule()
                .stroke(Theme.SignalChrome.clay, lineWidth: max(1, size * 0.07))
                .frame(width: size * 0.20, height: size * 0.34)
        case .archivedFlag:
            Rectangle()
                .fill(Theme.SignalChrome.ink)
                .frame(width: size * 0.30, height: max(1.5, size * 0.08))
        }
    }
}
```

- [ ] **Step 4: Implement the Signal Rule and quill stitch**

Create `SignalGrammarView.swift` with deterministic geometry:

```swift
import SwiftUI

struct QuillCuts: View {
    var size: CGFloat = 14
    var tint: Color = Theme.SignalChrome.coral

    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(tint)
                    .frame(width: max(1.5, size * 0.13), height: size * 0.64)
                    .rotationEffect(.degrees(-18))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct BrandQuillStitch: View {
    var size: CGFloat = 14

    var body: some View {
        QuillCuts(size: size)
    }
}

struct SignalRule: View {
    var mark: BrandProductMark

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            BrandProductMarkView(mark: mark, size: 16)
            Rectangle()
                .fill(Theme.hairline)
                .frame(maxWidth: .infinity)
                .frame(height: 1)
            BrandQuillStitch(size: 12)
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 5: Add opt-in properties without changing legacy callers**

Make these precise component changes:

```swift
// Components.swift
struct SectionLabel: View {
    let text: String
    var systemImage: String?
    var brandEmblem: BrandEmblem? = nil
    var productMark: BrandProductMark? = nil

    // Render order: brandEmblem, productMark, systemImage, then no glyph.
}

struct CardHeader: View {
    let title: String
    var systemImage: String?
    var subtitle: String?
    var showsBrandStitch = false

    // After Spacer(minLength: 0):
    // if showsBrandStitch && !typeSize.isAccessibilitySize {
    //     BrandQuillStitch(size: 14)
    // }
}

// DesignKit.swift
struct RowGlyph: View {
    let systemName: String
    var brandGlyph: BrandObjectGlyph? = nil
    var tint: Color = Theme.accent
    var size: CGFloat = 32

    // Render BrandObjectGlyphView when brandGlyph is non-nil;
    // otherwise render the existing Image(systemName:) unchanged.
}

struct DataRow: View {
    let glyph: String
    var brandGlyph: BrandObjectGlyph? = nil
    var tint: Color = Theme.accent
    // Keep every other stored property and default unchanged.
}
```

Pass `brandGlyph` through both stacked and horizontal `RowGlyph` call sites. The existing `glyph: String` remains a required fallback so all untouched call sites compile and `SymbolNameTests` keep scanning literal SF Symbols.

- [ ] **Step 6: Run component and symbol regression tests**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarComponentTests \
  -only-testing:GetHogTests/BrandEmblemTests \
  -only-testing:GetHogTests/SymbolNameTests \
  -only-testing:GetHogTests/AccessibilitySizeFitTests
```

Expected: all selected suites pass with nonzero executed counts. Existing unbranded component call sites render through their original SF Symbol path, and the previously shipped Search family emblems remain aligned with the same teal/coral rounded-stroke vocabulary.

- [ ] **Step 7: Commit the component seams**

```bash
git add GetHog.xcodeproj/project.pbxproj \
  GetHog/Sources/Common/BrandObjectGlyphView.swift \
  GetHog/Sources/Common/SignalGrammarView.swift \
  GetHog/Sources/Common/Components.swift \
  GetHog/Sources/Common/DesignKit.swift \
  GetHog/Tests/SignalGrammarComponentTests.swift
git diff --cached --check
git commit -m "Add Signal Grammar component seams"
```

---

### Task 3: Replace the generic project symbol with the Project Stamp

**Files:**
- Modify: `GetHog/Sources/App/RootView.swift:948-1030`
- Create: `GetHogUITests/SignalGrammarAccessibilityTests.swift`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `BrandProductMarkView(mark: .projectStamp)` and existing `ProjectSwitcher.spokenLabel`/`projectList`.
- Produces: no new product API; visible menu artwork changes while the menu's semantics remain identical.

- [ ] **Step 1: Write the failing rendered-semantics UI test**

Create `SignalGrammarAccessibilityTests.swift`:

```swift
import XCTest

final class SignalGrammarAccessibilityTests: XCTestCase {
    func testProjectStampPreservesProjectSwitcherSemantics() {
        let app = DemoLaunch.launch(tab: "dashboards")
        DemoLaunch.settle(app)

        let switcher = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current project:")
        ).firstMatch

        XCTAssertTrue(switcher.exists)
        XCTAssertTrue(switcher.isHittable)
        switcher.tap()
        XCTAssertTrue(app.buttons["Starling Metrics Lab"].waitForExistence(timeout: 3))
    }
}
```

- [ ] **Step 2: Run the focused UI test before the visual change**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogUITests/SignalGrammarAccessibilityTests/testProjectStampPreservesProjectSwitcherSemantics
```

Expected: one test executes and passes against the legacy artwork. This is a characterization test; its job is to lock behavior before the visible mark changes.

- [ ] **Step 3: Change only the menu-label artwork**

In `ProjectSwitcher`, replace:

```swift
Image(systemName: "building.2")
```

with:

```swift
BrandProductMarkView(mark: .projectStamp, size: 18)
```

Do not change the menu content, toolbar placement, `spokenLabel`, accessibility hint, organization loading state, project selection, or project subtitle.

- [ ] **Step 4: Re-run the UI test and project-switching unit coverage**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogUITests/SignalGrammarAccessibilityTests/testProjectStampPreservesProjectSwitcherSemantics \
  -only-testing:GetHogTests/AppModelTests
```

Expected: both selected suites execute nonzero tests and pass.

- [ ] **Step 5: Commit the Project Stamp**

```bash
xcodegen generate
git add GetHog.xcodeproj/project.pbxproj \
  GetHog/Sources/App/RootView.swift \
  GetHogUITests/SignalGrammarAccessibilityTests.swift
git diff --cached --check
git commit -m "Brand the GetHog project switcher"
```

---

### Task 4: Build the Dashboard summary scene and working treatment

**Files:**
- Create: `GetHog/Sources/Dashboards/DashboardOverviewFacts.swift`
- Create: `GetHog/Tests/SignalGrammarDashboardTests.swift`
- Modify: `GetHog/Sources/Dashboards/ProjectOverview.swift:16-155`
- Modify: `GetHog/Sources/Dashboards/DashboardsRoot.swift:130-190`
- Modify: `GetHog/Sources/Dashboards/DashboardDetailView.swift:540-610`
- Modify: `GetHog/Sources/Dashboards/TileStyle.swift:1-75`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `BrandProductMark.dashboard`, dashboard object glyphs, `SignalRule`, existing dashboard cache/request behavior, `MetricTile`, `MasonryLayout`, and `TileCard`.
- Produces: `DashboardOverviewFacts`, `DashboardBrandAppearance.glyph(for:)`, and the first finished Core Four composition.

- [ ] **Step 1: Write failing fact and glyph tests**

Create `SignalGrammarDashboardTests.swift`:

```swift
import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Dashboard Signal Grammar")
struct SignalGrammarDashboardTests {
    @Test("Overview facts separate computed and generated dashboards")
    func overviewFacts() throws {
        let data = Data(#"""
        {"results":[
          {"id":1,"name":"Product health","pinned":true,"last_refresh":"2026-07-31T12:00:00Z","creation_mode":"default"},
          {"id":2,"name":"Activation","pinned":false,"last_refresh":"2026-07-30T12:00:00Z","creation_mode":"default"},
          {"id":3,"name":"Generated Dashboard: flag","pinned":false,"creation_mode":"template"}
        ]}
        """#.utf8)
        let page = try JSONDecoder().decode(Page<DashboardSummary>.self, from: data)
        let facts = DashboardOverviewFacts(dashboards: page.results)

        #expect(facts.dashboardCount == 3)
        #expect(facts.computedCount == 2)
        #expect(facts.generatedCount == 1)
        #expect(facts.pinned?.title == "Product health")
        #expect(facts.recentlyComputed.map(\.title) == ["Product health", "Activation"])
    }

    @Test("Dashboard provenance maps to stable branded glyphs")
    func provenanceGlyphs() {
        #expect(DashboardBrandAppearance.glyph(for: .default) == .dashboard)
        #expect(DashboardBrandAppearance.glyph(for: .template) == .generatedDashboard)
        #expect(DashboardBrandAppearance.glyph(for: .duplicate) == .dashboard)
        #expect(DashboardBrandAppearance.glyph(for: .unknown) == .dashboard)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarDashboardTests
```

Expected: compile failure for `DashboardOverviewFacts` and `DashboardBrandAppearance`.

- [ ] **Step 3: Implement the pure dashboard facts**

Create `DashboardOverviewFacts.swift`:

```swift
import GetHogKit

struct DashboardOverviewFacts {
    let dashboardCount: Int
    let computedCount: Int
    let generatedCount: Int
    let pinned: DashboardSummary?
    let recentlyComputed: [DashboardSummary]

    init(dashboards: [DashboardSummary]) {
        dashboardCount = dashboards.count
        generatedCount = dashboards.filter { $0.creationMode == .template }.count
        pinned = dashboards.first(where: \.pinned)
        recentlyComputed = dashboards
            .compactMap { summary in summary.lastRefresh.map { (summary, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
        computedCount = recentlyComputed.count
    }
}

enum DashboardBrandAppearance {
    static func glyph(for mode: DashboardCreationMode) -> BrandObjectGlyph {
        mode == .template ? .generatedDashboard : .dashboard
    }
}
```

- [ ] **Step 4: Recompose `ProjectOverview` into an earned summary scene**

Replace the separate `header` and `pinnedSection` ordering with one `summaryScene`, followed by `recentSection`. The scene must:

- show `SectionLabel(text: "Project signal", productMark: .dashboard)` and the real selected-project name;
- show the existing Dashboards, Computed, and conditional Generated metrics from `DashboardOverviewFacts`;
- incorporate the pinned preview on the trailing side at regular width, capped at four real tiles exactly as today;
- stack the same content at compact or accessibility width using `ViewThatFits(in: .horizontal)` and `VStack`;
- keep `loadPinned()` and `refresh: false` unchanged;
- remove the old standalone pinned section so the preview is not duplicated;
- use an open composition with one leading teal rule, because the pinned preview already contains real `TileCard`s and wrapping those in another card would create forbidden nested surfaces.

Use this structure:

```swift
private var facts: DashboardOverviewFacts {
    DashboardOverviewFacts(dashboards: dashboards)
}

private var summaryScene: some View {
    VStack(alignment: .leading, spacing: Theme.Space.l) {
        SignalRule(mark: .dashboard)
        if facts.pinned != nil {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.xxl) {
                    projectSummary.frame(maxWidth: 300, alignment: .leading)
                    pinnedPreview.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    projectSummary
                    pinnedPreview
                }
            }
        } else {
            projectSummary
        }
    }
    .padding(.leading, Theme.Space.m)
    .overlay(alignment: .leading) {
        Rectangle()
            .fill(Theme.SignalChrome.teal)
            .frame(width: 3)
            .accessibilityHidden(true)
    }
    .accessibilityIdentifier("gethog.signal-summary.dashboard")
}
```

Define the two content regions explicitly:

```swift
private var projectSummary: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
        SectionLabel(text: "Project signal", productMark: .dashboard)
        Text(model.selectedProject?.name ?? "PostHog")
            .font(.largeTitle.weight(.semibold))
        StatStrip {
            MetricTile(label: "Dashboards", value: "\(facts.dashboardCount)", compact: true)
            MetricTile(label: "Computed", value: "\(facts.computedCount)", compact: true)
            if facts.generatedCount > 0 {
                MetricTile(label: "Generated", value: "\(facts.generatedCount)", compact: true)
            }
        }
        .padding(.horizontal, -Theme.Space.l)
    }
}

@ViewBuilder
private var pinnedPreview: some View {
    if let pinned = facts.pinned {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Pinned", productMark: .dashboard)
            if let pinnedDetail {
                MasonryLayout(columns: 2, spacing: Theme.Space.l) {
                    ForEach(Array(orderedTiles(pinnedDetail).prefix(4))) { tile in
                        TileCard(tile: tile, model: tile.renderModel)
                            .allowsHitTesting(false)
                    }
                }
            } else if isLoadingPinned {
                HStack(spacing: Theme.Space.m) {
                    ProgressView()
                    Text("Loading \(pinned.title)…")
                }
            }
        }
    }
}
```

When no dashboard is pinned, omit `pinnedPreview`; do not replace it with decorative copy.

- [ ] **Step 5: Apply the lower-intensity Dashboard grammar**

- In `DashboardsRoot`, pass `productMark: .dashboard` to the existing Pinned/All Dashboards section labels and pass `brandGlyph: DashboardBrandAppearance.glyph(for: dashboard.creationMode)` to dashboard `DataRow`s.
- In `DashboardDetailView`, pass `showsBrandStitch: true` to tile `CardHeader` only. Do not alter `chartContent`, hit testing, chart descriptors, freshness, loading, failure, empty, or drill-down behavior.
- In `TileStyle`, replace chrome use of `SeriesPalette` with `Theme.SignalChrome` roles. Use: time series and big number → teal; bar value and retention → clay; funnel and paths → coral; lifecycle and stickiness → ink; unsupported → `Theme.Ink.tertiary`. Do not change any series color inside `InsightChartView`.

Because `DashboardDetailView.swift` already has unrelated modifications, apply this one-label change with `apply_patch` and later stage only that hunk with `git add -p`.

- [ ] **Step 6: Run Dashboard unit and rendered-behavior tests**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarDashboardTests \
  -only-testing:GetHogTests/MasonryLayoutTests \
  -only-testing:GetHogTests/InsightDrillDownTests \
  -only-testing:GetHogUITests/DashboardTileAccessibilityTests
```

Expected: every selected suite executes nonzero tests and passes. The Dashboard tile remains one accessible button, chart data remains reachable, and the new stitch creates no accessibility stop.

- [ ] **Step 7: Capture and inspect Dashboard overview/detail states**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHogScreenshots \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testDashboards \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testDashboardDetail
xcodebuild test -project GetHog.xcodeproj -scheme GetHogScreenshots \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testDashboards \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testDashboardDetail
```

Inspect the generated light/dark/AX5 images with the image-viewing tool. Confirm the summary scene is useful on iPad, the phone list remains data-first, the pinned preview is not duplicated, long titles survive, and chart marks retain their real series colors.

- [ ] **Step 8: Commit only Dashboard Signal Grammar hunks**

```bash
git add GetHog.xcodeproj/project.pbxproj \
  GetHog/Sources/Dashboards/DashboardOverviewFacts.swift \
  GetHog/Sources/Dashboards/ProjectOverview.swift \
  GetHog/Sources/Dashboards/DashboardsRoot.swift \
  GetHog/Sources/Dashboards/TileStyle.swift \
  GetHog/Tests/SignalGrammarDashboardTests.swift
git add -p GetHog/Sources/Dashboards/DashboardDetailView.swift
git diff --cached --check
git diff --cached -- GetHog/Sources/Dashboards/DashboardDetailView.swift
git commit -m "Apply Signal Grammar to dashboards"
```

---

### Task 5: Give Events a temporal Signal Grammar composition

**Files:**
- Create: `GetHog/Sources/Events/EventOverviewFacts.swift`
- Create: `GetHog/Tests/SignalGrammarEventTests.swift`
- Modify: `GetHog/Sources/Events/EventsOverview.swift:17-150`
- Modify: `GetHog/Sources/Events/EventsRoot.swift:440-605`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `.event`, event object glyphs, existing feed rows and `loadedAt`.
- Produces: `EventOverviewFacts`, `EventAppearance.brandGlyph(for:)`, branded time buckets, and the Events summary scene.

- [ ] **Step 1: Write failing scope, ranking, and glyph tests**

Create `SignalGrammarEventTests.swift`:

```swift
import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Event Signal Grammar")
struct SignalGrammarEventTests {
    private func event(_ name: String, person: String, time: String) -> EventRow {
        EventRow(row: QueryRow(
            columns: ["event", "distinct_id", "timestamp"],
            values: [.string(name), .string(person), .string(time)]
        ))!
    }

    @Test("Summary facts are scoped to the loaded feed and rank ties stably")
    func summaryFacts() {
        let events = [
            event("project_created", person: "person-a", time: "2026-08-01T12:03:00Z"),
            event("$screen", person: "person-b", time: "2026-08-01T12:02:00Z"),
            event("project_created", person: "person-a", time: "2026-08-01T12:01:00Z"),
        ]
        let facts = EventOverviewFacts(events: events)

        #expect(facts.eventCount == 3)
        #expect(facts.kindCount == 2)
        #expect(facts.peopleCount == 2)
        #expect(facts.reach == "2m")
        #expect(facts.ranked.map(\.name) == ["project_created", "$screen"])
    }

    @Test("Stable event kinds map to original object glyphs")
    func glyphKinds() {
        #expect(EventAppearance.brandGlyph(for: "$screen") == .screenEvent)
        #expect(EventAppearance.brandGlyph(for: "$exception") == .exceptionEvent)
        #expect(EventAppearance.brandGlyph(for: "$feature_flag_called") == .featureFlagEvent)
        #expect(EventAppearance.brandGlyph(for: "project_created") == .event)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarEventTests
```

Expected: compile failure for `EventOverviewFacts` and `brandGlyph(for:)`.

- [ ] **Step 3: Extract the existing feed facts without changing their meaning**

Create `EventOverviewFacts.swift` with the logic currently private to `EventsOverview`:

```swift
import GetHogKit

struct EventOverviewFacts {
    let eventCount: Int
    let kindCount: Int
    let peopleCount: Int
    let reach: String?
    let ranked: [(name: String, count: Int)]
    let custom: [(name: String, count: Int)]

    init(events: [EventRow]) {
        eventCount = events.count
        let counts = events.reduce(into: [String: Int]()) {
            $0[$1.event, default: 0] += 1
        }
        kindCount = counts.count
        peopleCount = Set(events.compactMap(\.distinctID)).count
        ranked = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
        custom = ranked.filter { EventAppearance.isCustom($0.name) }

        let stamps = events.compactMap(\.timestamp)
        if let oldest = stamps.min(), let newest = stamps.max(), newest > oldest {
            let seconds = Int(newest.timeIntervalSince(oldest))
            if seconds < 3_600 { reach = "\(max(1, seconds / 60))m" }
            else if seconds < 86_400 { reach = "\(seconds / 3_600)h" }
            else { reach = "\(seconds / 86_400)d" }
        } else {
            reach = nil
        }
    }
}
```

Update `EventsOverview` to consume this value rather than keeping duplicate private reductions.

- [ ] **Step 4: Build a distinct Events summary scene**

Recompose the current Event feed header and `StatStrip` into a single asymmetric `Card(accent: Theme.SignalChrome.coral)`:

- leading: `SectionLabel(text: "Event signal", productMark: .event)`, project name, and the exact scope note “The N most recent events, not the project's history.”;
- trailing or lower compact region: Events, Kinds, People, and optional Reaching Back metrics;
- one `SignalRule(mark: .event)` between identity/scope and metrics at compact width;
- no mascot, invented trend, or top-event callout;
- retain the Most Frequent and Instrumented By You sections below, because the scene does not duplicate their rankings.
- attach `.accessibilityIdentifier("gethog.signal-summary.events")` to the outer scene.

Use `ViewThatFits(in: .horizontal)` so the regular-width composition is asymmetric and the compact fallback is one logical top-to-bottom accessibility order.

Implement that topology with these private regions:

```swift
private var facts: EventOverviewFacts { EventOverviewFacts(events: events) }

private var summaryScene: some View {
    Card(accent: Theme.SignalChrome.coral) {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.xxl) {
                eventIdentity
                eventMetrics.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                eventIdentity
                SignalRule(mark: .event)
                eventMetrics
            }
        }
    }
    .accessibilityIdentifier("gethog.signal-summary.events")
}

private var eventIdentity: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
        SectionLabel(text: "Event signal", productMark: .event)
        Text(model.selectedProject?.name ?? "PostHog")
            .font(.largeTitle.weight(.semibold))
        Text("The \(facts.eventCount) most recent events, not the project's history.")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Ink.secondary)
    }
}

private var eventMetrics: some View {
    StatStrip {
        MetricTile(label: "Events", value: "\(facts.eventCount)", compact: true)
        MetricTile(label: "Kinds", value: "\(facts.kindCount)", compact: true)
        MetricTile(label: "People", value: "\(facts.peopleCount)", compact: true)
        if let reach = facts.reach {
            MetricTile(label: "Reaching back", value: reach, compact: true)
        }
    }
    .padding(.horizontal, -Theme.Space.l)
}
```

- [ ] **Step 5: Brand real time buckets and event kinds**

Add to `EventAppearance`:

```swift
static func brandGlyph(for name: String) -> BrandObjectGlyph {
    switch name {
    case "$pageview", "$screen": .screenEvent
    case "$exception": .exceptionEvent
    case "$feature_flag_called": .featureFlagEvent
    default: .event
    }
}
```

Pass `brandGlyph: EventAppearance.brandGlyph(for:)` to overview/feed `DataRow`s. Replace only the passive time-bucket `SectionLabel` clock artwork with `productMark: .event`; keep bucket title, order, timestamps, search tokens, filters, live-tail control, loading, pagination, and payload disclosure unchanged.

- [ ] **Step 6: Run the Events regression set**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarEventTests \
  -only-testing:GetHogTests/QueryTruncationTests \
  -only-testing:GetHogUITests/AccessibilityAuditTests/testEvents
```

Expected: every selected suite executes nonzero tests and passes; event ordering, exact timestamps, and live-tail semantics are unchanged.

- [ ] **Step 7: Capture and inspect Events on phone and iPad**

Run the existing `RootScreenshotTests/testEvents` through the `GetHogScreenshots` scheme on iPhone 17 and iPad Pro 11-inch (M5). Inspect light, dark, and AX5 output. Confirm the iPad summary earns its space, the phone feed remains immediate, event names remain stronger than glyphs, and scope copy stays adjacent to its figures.

- [ ] **Step 8: Commit the Events treatment**

```bash
git add GetHog.xcodeproj/project.pbxproj \
  GetHog/Sources/Events/EventOverviewFacts.swift \
  GetHog/Sources/Events/EventsOverview.swift \
  GetHog/Sources/Events/EventsRoot.swift \
  GetHog/Tests/SignalGrammarEventTests.swift
git diff --cached --check
git commit -m "Apply Signal Grammar to events"
```

---

### Task 6: Give Sessions a replay-specific Signal Grammar composition

**Files:**
- Create: `GetHog/Sources/Sessions/SessionOverviewFacts.swift`
- Create: `GetHog/Tests/SignalGrammarSessionTests.swift`
- Modify: `GetHog/Sources/Sessions/SessionsOverview.swift:17-180`
- Modify: `GetHog/Sources/Sessions/SessionsRoot.swift:272-470`
- Modify: `GetHog/Sources/Sessions/SessionTimelineView.swift:240-275`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `.session`, replay object glyphs, existing session filters and timeline data.
- Produces: `SessionOverviewFacts`, `SessionBrandAppearance.glyph(hasErrors:isReplayable:)`, and the Sessions summary scene.

- [ ] **Step 1: Write failing totals, triage, and glyph tests**

Create `SignalGrammarSessionTests.swift`:

```swift
import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Session Signal Grammar")
struct SignalGrammarSessionTests {
    @Test("Overview facts preserve loaded-page scope")
    func overviewFacts() throws {
        let data = Data(#"""
        [
          {"id":"a","recording_duration":120,"console_error_count":2,"snapshot_source":"web","start_url":"https://example.com/signup"},
          {"id":"b","recording_duration":300,"console_error_count":0,"snapshot_source":"mobile","start_url":"https://example.com/home"}
        ]
        """#.utf8)
        let recordings = try JSONDecoder().decode([SessionRecording].self, from: data)
        let facts = SessionOverviewFacts(recordings: recordings)

        #expect(facts.recordingCount == 2)
        #expect(facts.withErrors.count == 1)
        #expect(facts.notPlayableCount == 1)
        #expect(facts.totalDurationText == "7m")
        #expect(facts.entryPaths.map(\.path) == ["/home", "/signup"])
    }

    @Test("Replay conditions map to stable branded glyphs")
    func glyphKinds() {
        #expect(SessionBrandAppearance.glyph(hasErrors: true, isReplayable: true) == .errorSession)
        #expect(SessionBrandAppearance.glyph(hasErrors: false, isReplayable: false) == .mobileSession)
        #expect(SessionBrandAppearance.glyph(hasErrors: false, isReplayable: true) == .session)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarSessionTests
```

Expected: compile failure for the missing fact and appearance types.

- [ ] **Step 3: Extract the existing session facts**

Create `SessionOverviewFacts.swift`:

```swift
import GetHogKit

struct SessionOverviewFacts {
    let recordingCount: Int
    let withErrors: [SessionRecording]
    let notPlayableCount: Int
    let totalDurationText: String
    let entryPaths: [(path: String, count: Int)]

    init(recordings: [SessionRecording]) {
        recordingCount = recordings.count
        withErrors = Array(
            recordings.filter(\.hasErrors)
                .sorted { $0.consoleErrorCount > $1.consoleErrorCount }
                .prefix(5)
        )
        notPlayableCount = recordings.filter { !$0.isReplayable }.count
        let total = Int(recordings.reduce(0) { $0 + ($1.recordingDuration ?? 0) })
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        totalDurationText = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"

        var counts: [String: Int] = [:]
        for recording in recordings where recording.startURL != nil {
            counts[recording.pathComponent, default: 0] += 1
        }
        entryPaths = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { (path: $0.key, count: $0.value) }
    }
}

enum SessionBrandAppearance {
    static func glyph(hasErrors: Bool, isReplayable: Bool) -> BrandObjectGlyph {
        if hasErrors { return .errorSession }
        if !isReplayable { return .mobileSession }
        return .session
    }
}
```

Replace the private duplicate reductions in `SessionsOverview` with this facts value.

- [ ] **Step 4: Build the Sessions summary scene**

Recompose the current header/StatStrip into a `Card(accent: Theme.SignalChrome.clay)`:

- `SectionLabel(text: "Replay signal", productMark: .session)` and real project name;
- Recordings, With Errors, Total Time, and conditional Not Playable metrics;
- the exact loaded-page scope sentence adjacent to those figures;
- a real, compact reel path derived only from the four figures: chapter points represent counts and are explicitly decorative, not event positions;
- regular-width horizontal and compact/accessibility linear variants through `ViewThatFits`.
- attach `.accessibilityIdentifier("gethog.signal-summary.sessions")` to the outer scene.

Keep Worth Watching and Where Sessions Start below; the summary scene shows totals, not duplicated recording rows or entry paths.

Use these explicit summary regions:

```swift
private var facts: SessionOverviewFacts { SessionOverviewFacts(recordings: recordings) }

private var summaryScene: some View {
    Card(accent: Theme.SignalChrome.clay) {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.xxl) {
                replayIdentity
                replayMetrics.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                replayIdentity
                SignalRule(mark: .session)
                replayMetrics
            }
        }
    }
    .accessibilityIdentifier("gethog.signal-summary.sessions")
}

private var replayIdentity: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
        SectionLabel(text: "Replay signal", productMark: .session)
        Text(model.selectedProject?.name ?? "PostHog")
            .font(.largeTitle.weight(.semibold))
        Text("Across the \(facts.recordingCount) recordings loaded, not the whole project.")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Ink.secondary)
    }
}

private var replayMetrics: some View {
    StatStrip {
        MetricTile(label: "Recordings", value: "\(facts.recordingCount)", compact: true)
        MetricTile(label: "With errors", value: "\(facts.withErrors.count)", compact: true)
        MetricTile(label: "Total time", value: facts.totalDurationText, compact: true)
        if facts.notPlayableCount > 0 {
            MetricTile(label: "Not playable", value: "\(facts.notPlayableCount)", compact: true)
        }
    }
    .padding(.horizontal, -Theme.Space.l)
}
```

- [ ] **Step 5: Apply replay glyphs without replacing controls**

- In `SessionRowView`, pass `brandGlyph: SessionBrandAppearance.glyph(hasErrors:isReplayable:)` while retaining the current fallback SF Symbol, tint, person, path, stats, and accessibility label.
- In `SessionsOverview`, use the same glyph mapping in triage rows and `.session` for entry-path rows.
- In `SessionTimelineView`, replace only the passive Timeline section-label symbol with `productMark: .session` and add `SignalRule(mark: .session)` only if an existing divider occupies the same location. Do not fabricate chapter positions or alter playback data.
- Do not brand the play button, replay stage, filter control, mobile-not-playable notice, or error semantics.

- [ ] **Step 6: Run Sessions regression tests**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarSessionTests \
  -only-testing:GetHogTests/SessionsFilterScreenTests \
  -only-testing:GetHogTests/RenderPlaybackTests \
  -only-testing:GetHogUITests/ReplayStageAccessibilityTests
```

Expected: nonzero selected test counts and all passing; filters, replay availability, and player accessibility remain unchanged.

- [ ] **Step 7: Capture and inspect Sessions on phone and iPad**

Run `RootScreenshotTests/testSessions` through `GetHogScreenshots` on iPhone 17 and iPad Pro 11-inch (M5). Inspect light, dark, and AX5. Verify playback remains the first affordance, friction remains written as text, the reel motif does not imply fake timeline data, and Not Playable remains prominent where present.

- [ ] **Step 8: Commit the Sessions treatment**

```bash
git add GetHog.xcodeproj/project.pbxproj \
  GetHog/Sources/Sessions/SessionOverviewFacts.swift \
  GetHog/Sources/Sessions/SessionsOverview.swift \
  GetHog/Sources/Sessions/SessionsRoot.swift \
  GetHog/Sources/Sessions/SessionTimelineView.swift \
  GetHog/Tests/SignalGrammarSessionTests.swift
git diff --cached --check
git commit -m "Apply Signal Grammar to sessions"
```

---

### Task 7: Give Feature Flags a decision-specific Signal Grammar composition

**Files:**
- Create: `GetHog/Sources/Flags/FlagOverviewFacts.swift`
- Create: `GetHog/Tests/SignalGrammarFlagTests.swift`
- Modify: `GetHog/Sources/Flags/FlagsOverview.swift:17-185`
- Modify: `GetHog/Sources/Flags/FlagsRoot.swift:190-295`
- Modify: `GetHog/Sources/Flags/FlagDetailView.swift:325-430`
- Regenerate: `GetHog.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `.flag`, flag object glyphs, `FlagsStore.group(for:)`, and existing rollout calculations.
- Produces: `FlagOverviewFacts`, `FlagBrandAppearance.glyph(isMultivariate:isArchived:)`, and the Flags summary scene.

- [ ] **Step 1: Write failing truth, rollout, and glyph tests**

Create `SignalGrammarFlagTests.swift`:

```swift
import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Flag Signal Grammar")
@MainActor
struct SignalGrammarFlagTests {
    @Test("Overview facts use true project totals and effective state")
    func overviewFacts() throws {
        let data = Data(#"""
        {"results":[
          {"id":1,"key":"checkout-v2","active":true,"filters":{"groups":[{"rollout_percentage":60}]}},
          {"id":2,"key":"onboarding-copy","active":true,"filters":{"groups":[{"rollout_percentage":100}],"multivariate":{"variants":[{"key":"a","rollout_percentage":50},{"key":"b","rollout_percentage":50}]}}},
          {"id":3,"key":"old-flag","active":false,"archived":true}
        ]}
        """#.utf8)
        let page = try JSONDecoder().decode(Page<FeatureFlag>.self, from: data)
        let store = FlagsStore()
        store.flags = page.results
        let facts = FlagOverviewFacts(store: store)

        #expect(facts.flagCount == 3)
        #expect(facts.enabledCount == 2)
        #expect(facts.multivariateCount == 1)
        #expect(facts.partialRollouts.map(\.key) == ["checkout-v2"])
        #expect(facts.statusCounts[.archived] == 1)
    }

    @Test("Flag kinds map to stable branded glyphs")
    func glyphKinds() {
        #expect(FlagBrandAppearance.glyph(isMultivariate: false, isArchived: false) == .flag)
        #expect(FlagBrandAppearance.glyph(isMultivariate: true, isArchived: false) == .multivariateFlag)
        #expect(FlagBrandAppearance.glyph(isMultivariate: false, isArchived: true) == .archivedFlag)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarFlagTests
```

Expected: compile failure for `FlagOverviewFacts` and `FlagBrandAppearance`.

- [ ] **Step 3: Extract flag facts through the authoritative store**

Create `FlagOverviewFacts.swift`:

First change the declaration line from `enum FlagStatusGroup: String, CaseIterable, Identifiable` to `enum FlagStatusGroup: String, CaseIterable, Identifiable, Hashable`. The enum has no associated values, so synthesis changes no runtime behavior and makes it a valid dictionary key.

```swift
import GetHogKit

@MainActor
struct FlagOverviewFacts {
    let flagCount: Int
    let enabledCount: Int
    let multivariateCount: Int
    let statusCounts: [FlagStatusGroup: Int]
    let partialRollouts: [FeatureFlag]

    init(store: FlagsStore) {
        flagCount = store.flags.count
        enabledCount = store.flags.filter { store.group(for: $0) == .enabled }.count
        multivariateCount = store.flags.filter { $0.isMultivariate && !$0.archived }.count
        statusCounts = Dictionary(uniqueKeysWithValues: FlagStatusGroup.allCases.map { group in
            (group, store.flags.filter { store.group(for: $0) == group }.count)
        })
        partialRollouts = Array(
            store.flags
                .filter { store.group(for: $0) == .enabled }
                .filter { ($0.rolloutPercentage ?? 100) < 100 }
                .sorted { ($0.rolloutPercentage ?? 0) < ($1.rolloutPercentage ?? 0) }
                .prefix(6)
        )
    }
}

enum FlagBrandAppearance {
    static func glyph(isMultivariate: Bool, isArchived: Bool) -> BrandObjectGlyph {
        if isArchived { return .archivedFlag }
        return isMultivariate ? .multivariateFlag : .flag
    }
}
```

- [ ] **Step 4: Build the Flags summary scene and remove duplication**

Recompose the current header, `StatStrip`, and By Status card into one `Card(accent: Theme.SignalChrome.ink)`:

- `SectionLabel(text: "Rollout signal", productMark: .flag)` and project name;
- Flags, Enabled, and conditional Multivariate metrics;
- the current Enabled/Disabled/Archived status pills and counts in the same scene;
- one branching rule whose branch lengths do not encode values; numeric counts and words remain the authoritative state;
- compact/accessibility fallback with project, metrics, then status counts in identical visual/accessibility order.
- attach `.accessibilityIdentifier("gethog.signal-summary.flags")` to the outer scene.

Remove the old standalone `statusSection` after integrating its content. Keep Mid-Rollout and Multivariate below because they provide item-level decision support rather than duplicate totals.

Use this exact content split so the former By Status data appears once:

```swift
private var facts: FlagOverviewFacts { FlagOverviewFacts(store: store) }

private var summaryScene: some View {
    Card(accent: Theme.SignalChrome.ink) {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.xxl) {
                flagIdentity
                flagStateSummary.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                flagIdentity
                SignalRule(mark: .flag)
                flagStateSummary
            }
        }
    }
    .accessibilityIdentifier("gethog.signal-summary.flags")
}

private var flagIdentity: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
        SectionLabel(text: "Rollout signal", productMark: .flag)
        Text(model.selectedProject?.name ?? "PostHog")
            .font(.largeTitle.weight(.semibold))
        StatStrip {
            MetricTile(label: "Flags", value: "\(facts.flagCount)", compact: true)
            MetricTile(label: "Enabled", value: "\(facts.enabledCount)", compact: true)
            if facts.multivariateCount > 0 {
                MetricTile(label: "Multivariate", value: "\(facts.multivariateCount)", compact: true)
            }
        }
        .padding(.horizontal, -Theme.Space.l)
    }
}

private var flagStateSummary: some View {
    ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            ForEach(FlagStatusGroup.allCases) { statusCell($0) }
        }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(FlagStatusGroup.allCases) { statusCell($0) }
        }
    }
}

private func statusCell(_ group: FlagStatusGroup) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
        StatusPill(text: group.title, tint: group.tint)
        Text("\(facts.statusCounts[group, default: 0])")
            .font(Theme.Typography.metricSmall)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
        "\(facts.statusCounts[group, default: 0]) \(group.title.lowercased())"
    )
}
```

- [ ] **Step 5: Apply the lower-intensity Flags grammar**

- In `FlagsRoot`, use `productMark: .flag` in existing status section headers and `brandGlyph: FlagBrandAppearance.glyph(isMultivariate:isArchived:)` in `FlagRowView`.
- In `FlagsOverview.flagRow`, use the same glyph mapping.
- In `FlagDetailView`, use `productMark: .flag` for Rollout and Variants section labels only. Keep Live State, switches, confirmation flows, release conditions, exact percentages, targeting, and destructive actions unchanged.
- Do not animate a flag switch or use branded geometry as the enabled-state indicator.

- [ ] **Step 6: Run Flags behavior and accessibility regressions**

Before running, add this second method to `SignalGrammarAccessibilityTests.swift`:

```swift
func testCoreFourOverviewScenesAreSingularOnIPad() throws {
    let device = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
    try XCTSkipUnless(device.lowercased().contains("ipad"))

    let cases = [
        (tab: "dashboards", identifier: "gethog.signal-summary.dashboard"),
        (tab: "events", identifier: "gethog.signal-summary.events"),
        (tab: "sessions", identifier: "gethog.signal-summary.sessions"),
        (tab: "flags", identifier: "gethog.signal-summary.flags"),
    ]

    for item in cases {
        let app = DemoLaunch.launch(tab: item.tab)
        DemoLaunch.settle(app)
        let scenes = app.descendants(matching: .any).matching(identifier: item.identifier)
        XCTAssertEqual(scenes.count, 1, "\(item.tab) must expose one summary scene")
        app.terminate()
    }
}
```

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/SignalGrammarFlagTests \
  -only-testing:GetHogTests/LifecycleWriteScreenTests \
  -only-testing:GetHogTests/AlertWorkflowTests \
  -only-testing:GetHogUITests/LifecycleWriteControlTests
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -only-testing:GetHogUITests/SignalGrammarAccessibilityTests/testCoreFourOverviewScenesAreSingularOnIPad
```

Expected: nonzero selected counts and all passing; flag state and write behavior remain unchanged and status is still spoken as text.

- [ ] **Step 7: Capture and inspect Flags on phone and iPad**

Run `RootScreenshotTests/testFlags` through `GetHogScreenshots` on iPhone 17 and iPad Pro 11-inch (M5). Inspect light, dark, and AX5. Confirm the summary scene replaces rather than repeats status totals, percentages remain readable, and the phone list stays useful before expressive detail.

- [ ] **Step 8: Commit the Flags treatment**

```bash
git add GetHog.xcodeproj/project.pbxproj \
  GetHog/Sources/Flags/FlagOverviewFacts.swift \
  GetHog/Sources/Flags/FlagsOverview.swift \
  GetHog/Sources/Flags/FlagsRoot.swift \
  GetHog/Sources/Flags/FlagDetailView.swift \
  GetHog/Tests/SignalGrammarFlagTests.swift \
  GetHogUITests/SignalGrammarAccessibilityTests.swift
git diff --cached --check
git commit -m "Apply Signal Grammar to feature flags"
```

---

### Task 8: Add restrained successful-state motion

**Files:**
- Modify: `GetHog/Sources/Common/BrandMotion.swift:1-70`
- Modify: `GetHog/Tests/BrandMotionTests.swift:1-60`
- Modify: `GetHog/Sources/Dashboards/ProjectOverview.swift`
- Modify: `GetHog/Sources/Events/EventsOverview.swift`
- Modify: `GetHog/Sources/Sessions/SessionsOverview.swift`
- Modify: `GetHog/Sources/Flags/FlagsOverview.swift`

**Interfaces:**
- Consumes: existing `loadedAt`/project/data-count state and `BrandQuillStitch`.
- Produces: `BrandMotionValues.confirmation(reduceMotion:active:)` and `.signalConfirmation(trigger:)`.

- [ ] **Step 1: Write failing bounded-motion tests**

Add to `BrandMotionTests.swift`:

```swift
@Test("Reduced motion never exposes a confirmation transition")
func reducedConfirmationSettles() {
    #expect(BrandMotionValues.confirmation(reduceMotion: true, active: true) == .settled)
    #expect(BrandMotionValues.confirmation(reduceMotion: true, active: false) == .settled)
}

@Test("Standard confirmation changes only opacity, offset, and scale")
func standardConfirmationIsBounded() {
    let active = BrandMotionValues.confirmation(reduceMotion: false, active: true)
    #expect(active.opacity == 1)
    #expect(active.y == -2)
    #expect(active.scale == 1.04)
    #expect(BrandMotionValues.confirmation(reduceMotion: false, active: false) == .settled)
}
```

Add `Equatable` static value support:

```swift
extension BrandMotionValues {
    static let settled = BrandMotionValues(opacity: 0, y: 0, scale: 1)
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/BrandMotionTests
```

Expected: compile failure because `confirmation` and `settled` do not exist.

- [ ] **Step 3: Implement a one-shot, Reduce Motion-safe confirmation modifier**

Add the pure value function:

```swift
static func confirmation(reduceMotion: Bool, active: Bool) -> BrandMotionValues {
    guard !reduceMotion, active else { return .settled }
    return BrandMotionValues(opacity: 1, y: -2, scale: 1.04)
}
```

Add a generic modifier that observes an existing equatable trigger, briefly reveals one trailing quill stitch, and removes it without changing layout:

```swift
private struct SignalConfirmationModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false
    @State private var resetTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        let values = BrandMotionValues.confirmation(
            reduceMotion: reduceMotion,
            active: active
        )
        content.overlay(alignment: .topTrailing) {
            BrandQuillStitch(size: 14)
                .opacity(values.opacity)
                .offset(y: values.y)
                .scaleEffect(values.scale)
                .allowsHitTesting(false)
        }
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            resetTask?.cancel()
            withAnimation(.easeOut(duration: 0.18)) { active = true }
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { active = false }
            }
        }
        .onDisappear { resetTask?.cancel() }
    }
}

extension View {
    func signalConfirmation<Trigger: Equatable>(trigger: Trigger) -> some View {
        modifier(SignalConfirmationModifier(trigger: trigger))
    }
}
```

Apply it to the summary scene only:

- Dashboard trigger: `DashboardSummaryTrigger(projectID:dashboardCount:pinnedID:)`.
- Events trigger: `loadedAt`.
- Sessions trigger: `loadedAt`.
- Flags trigger: `store.loadedAt`.

Declare and apply the Dashboard trigger exactly as follows:

```swift
private struct DashboardSummaryTrigger: Equatable {
    let projectID: Int?
    let dashboardCount: Int
    let pinnedID: Int?
}

private var summaryTrigger: DashboardSummaryTrigger {
    DashboardSummaryTrigger(
        projectID: model.projectID,
        dashboardCount: facts.dashboardCount,
        pinnedID: facts.pinned?.id
    )
}

// On the outer summary scene:
.signalConfirmation(trigger: summaryTrigger)
```

On the other three outer summary scenes, add `.signalConfirmation(trigger: loadedAt)` for Events and Sessions, and `.signalConfirmation(trigger: store.loadedAt)` for Flags. Do not create a new timer or loading state in any feature view.

Do not attach it to rows, charts, playback, flag switches, filters, or scrolling.

- [ ] **Step 4: Run motion and Reduce Motion coverage**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/BrandMotionTests \
  -only-testing:GetHogUITests/BrandedEmptyStateAccessibilityTests
```

Expected: both suites execute nonzero tests and pass. Existing illustration/connecting behavior remains unchanged, and new confirmation values settle immediately under Reduce Motion.

- [ ] **Step 5: Commit the motion signature**

```bash
git add GetHog/Sources/Common/BrandMotion.swift \
  GetHog/Tests/BrandMotionTests.swift \
  GetHog/Sources/Dashboards/ProjectOverview.swift \
  GetHog/Sources/Events/EventsOverview.swift \
  GetHog/Sources/Sessions/SessionsOverview.swift \
  GetHog/Sources/Flags/FlagsOverview.swift
git diff --cached --check
git commit -m "Add restrained Signal Grammar motion"
```

---

### Task 9: Run the comprehensive craft, accessibility, and behavior gate

**Files:**
- Modify only if verification finds a defect: files already named in Tasks 1–8.
- Do not add a generic cleanup layer or unrelated refactor.

**Interfaces:**
- Consumes: the complete Signal Grammar implementation.
- Produces: verified Core Four behavior, screenshots, nonzero test counts, and a clean focused commit history.

- [ ] **Step 1: Regenerate and verify the project definition is authoritative**

```bash
xcodegen generate
git diff --check
git status --short
```

Expected: generated membership matches `project.yml`; unrelated pre-existing work remains unstaged and recognizable.

- [ ] **Step 2: Run the layout detector across all touched UI**

```bash
node /Users/abhi/.agents/skills/impeccable/scripts/detect.mjs --json --scope layout \
  GetHog/Sources/Common \
  GetHog/Sources/Dashboards \
  GetHog/Sources/Events \
  GetHog/Sources/Sessions \
  GetHog/Sources/Flags
```

Expected: no unexplained layout findings. Evaluate any finding against the approved earned-footprint contract rather than mechanically suppressing it.

- [ ] **Step 3: Run package tests**

```bash
swift test --package-path GetHogKit
```

Expected: all package tests pass with a reported nonzero test count. Do not call the package suite green if `FixturePrivacyTests` reports retained credentials or live values.

- [ ] **Step 4: Build the app for the configured simulator**

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: `BUILD SUCCEEDED` with no Swift 6 concurrency error.

- [ ] **Step 5: Run the full app unit target**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests
```

Expected: `TEST SUCCEEDED` and a nonzero executed GetHogTests count. Record the count.

- [ ] **Step 6: Run the full rendered accessibility target**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogUITests
```

Expected: `TEST SUCCEEDED` and a nonzero executed GetHogUITests count. Record the count.

- [ ] **Step 7: Capture the bounded Core Four matrix**

Run the four root screenshot tests plus Dashboard detail on both destinations:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHogScreenshots \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testDashboards \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testEvents \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testSessions \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testFlags \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testDashboardDetail
xcodebuild test -project GetHog.xcodeproj -scheme GetHogScreenshots \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testDashboards \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testEvents \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testSessions \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testFlags \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testDashboardDetail
```

Expected: light/dark captures on both devices and AX5 on iPhone, with nonzero executed counts.

- [ ] **Step 8: Perform one batched visual review**

Use the image-viewing tool to inspect the entire bounded matrix in one pass. Record every defect before editing. Check:

- squint-test reading order: summary or primary working data first, support second;
- added overview space earns itself through unique synthesis;
- no duplicated metrics or status summaries;
- Core Four screens feel related but not templated;
- custom glyphs remain quieter than names, values, and controls;
- chart series, event times, replay controls, and rollout values remain visually authoritative;
- light/dark contrast, AX5 wrapping, iPad split-view balance, long synthetic identifiers, and touch targets;
- no full mascot on populated compact screens;
- no gradients, pill soup, arbitrary blobs, or decorative fake data.

Apply one consolidated patch for all findings. Do not start an open-ended polish loop.

- [ ] **Step 9: Confirm the consolidated fixes once**

Re-run only the affected focused unit/UI suites and screenshot cases, then rerun `git diff --check`. If the confirmation reveals a functional regression, fix it and rerun the single affected test; do not broaden the design after the approved two-pass craft cycle.

- [ ] **Step 10: Commit verification-only corrections if any exist**

```bash
git add -p
git diff --cached --check
git commit -m "Polish Signal Grammar integration"
```

Skip this commit when verification required no source correction. Never stage unrelated dashboard graph-state files or local `.codex`/`.github/hooks` additions.

---

## Final Handoff Checklist

- [ ] Report commits created by Tasks 1–9.
- [ ] Report GetHogKit, GetHogTests, and GetHogUITests executed counts separately.
- [ ] Report the exact screenshot destinations and cases reviewed.
- [ ] State whether the Impeccable layout detector produced findings and how each was resolved.
- [ ] State that no product behavior, data semantics, navigation, networking, caching, or widget behavior changed.
- [ ] State that retained artifacts remain deterministic and synthetic.
- [ ] List any pre-existing unrelated worktree changes that remain uncommitted.
