# Layered Signature Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a restrained Signal Hog illustration, emblem, and motion system to meaningful passive states without changing GetHog's navigation, data behavior, controls, or accessibility semantics.

**Architecture:** A closed `BrandIllustration` enum maps six semantic scenes to local asset-catalog images rendered by one accessibility-hidden `BrandIllustrationView`. `EmptyStateView` gains an optional illustration while preserving its existing SF Symbol fallback and all copy/actions. Five deterministic SwiftUI emblems brand passive product-family headings, while isolated decorative motion wraps existing loading and onboarding content without owning product state.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XCTest/XCUITest, UIKit/ImageIO asset validation, Xcode asset catalogs, XcodeGen, built-in image generation, local chroma-key removal.

## Global Constraints

- Work directly on `main`, as explicitly approved by the user; do not create or switch branches.
- `project.yml` is authoritative; regenerate `GetHog.xcodeproj` with `xcodegen generate` after adding files.
- Use four-space Swift indentation and Swift 6 strict concurrency.
- Preserve all unrelated worktree changes and stage only the files named by the current task.
- If a named file already contains unrelated uncommitted hunks, stage only this plan's hunks with `git add -p` and verify `git diff --cached` line by line before committing; never absorb the pre-existing hunks into a polish commit.
- Use only deterministic synthetic content in retained assets, tests, screenshots, fixtures, examples, and documentation.
- Use `Theme` colors for code-rendered surfaces; do not introduce literal SwiftUI colors.
- Keep tab bars, sidebar destinations, row affordances, buttons, menus, charts, status/error semantics, filters, and widgets on their current native symbols and behavior.
- Brand art is local, contains no text, performs no network request, handles no gesture, and is accessibility-hidden beside descriptive text.
- Illustrations are eligible only for successfully loaded, unsearched, unnarrowed, screen-level zero-data or positive all-clear states.
- Never add illustrations to failures, retries, permission gates, filtered/search results, selection prompts, partial/truncated results, section-level notices, or dense data surfaces.
- Every animation must resolve immediately to its final frame when `accessibilityReduceMotion` is enabled and must not gate navigation or interaction.
- Preserve the independent-app and trademark disclosures verbatim.
- Do not use `xcrun simctl` or pass `-derivedDataPath`.
- Report executed test counts as well as `TEST SUCCEEDED`.

---

## File Map

### New production files

- `GetHog/Sources/Common/BrandIllustrationView.swift` — six-scene enum, asset-name contract, shared soft backing shape, and one-shot entrance presentation.
- `GetHog/Sources/Common/BrandEmblemView.swift` — five passive product-family emblems and title-to-emblem mapping.
- `GetHog/Sources/Common/BrandMotion.swift` — testable decorative-motion values plus the three-quill connecting accent.
- `GetHog/Resources/Assets.xcassets/BrandEmptyDashboard.imageset/*` — dashboard vignette at 1x/2x/3x.
- `GetHog/Resources/Assets.xcassets/BrandEmptyInsights.imageset/*` — insight vignette at 1x/2x/3x.
- `GetHog/Resources/Assets.xcassets/BrandEmptySessions.imageset/*` — session vignette at 1x/2x/3x.
- `GetHog/Resources/Assets.xcassets/BrandEmptyExperiment.imageset/*` — experiment-family vignette at 1x/2x/3x.
- `GetHog/Resources/Assets.xcassets/BrandEmptyWorkspace.imageset/*` — saved-work vignette at 1x/2x/3x.
- `GetHog/Resources/Assets.xcassets/BrandAllClear.imageset/*` — positive all-clear vignette at 1x/2x/3x.

### New test files

- `GetHog/Tests/BrandIllustrationTests.swift` — enum mapping, compiled asset presence, source-PNG dimensions/alpha/corners, and rendering contract.
- `GetHog/Tests/BrandEmblemTests.swift` — five family mappings and deterministic rendering.
- `GetHog/Tests/BrandMotionTests.swift` — Reduce Motion and initial/final presentation values.
- `GetHogUITests/BrandedEmptyStateAccessibilityTests.swift` — rendered-tree and accessibility audits for three primary branded empty states.

### Modified shared files

- `GetHog/Sources/Common/DesignKit.swift` — optional branded illustration in `EmptyStateView`.
- `GetHog/Sources/Common/Components.swift` — optional passive `BrandEmblem` in `SectionLabel`.
- `GetHog/Sources/Common/BrandMarkView.swift` — optional one-shot welcome entrance while remaining static elsewhere.
- `GetHog/Sources/App/RootView.swift` — additive connecting accent around the existing `ProgressView`.
- `GetHog/Sources/App/ScreenIndexSections.swift` — product-family emblems in passive compact-width headings.
- `GetHog/Sources/App/DemoTransport.swift` — DEBUG-only injectable empty collections for deterministic visual verification.
- `GetHog/Sources/Onboarding/OnboardingView.swift` — one-shot, non-gating welcome mark settle.
- `GetHogUITests/DemoLaunch.swift` — optional launch environment for demo-only state selection.
- `GetHogUITests/Screenshots/StateScreenshotTests.swift` — primary empty-state and Reduce Motion captures.
- `GetHogUITests/Screenshots/Screenshot.swift` — optional extra launch arguments used only by the Reduce Motion capture.

### Modified feature files

- `GetHog/Sources/Dashboards/DashboardsRoot.swift`
- `GetHog/Sources/Insights/InsightsRoot.swift`
- `GetHog/Sources/Sessions/SessionsRoot.swift`
- `GetHog/Sources/Flags/FlagsRoot.swift`
- `GetHog/Sources/Experiments/ExperimentsRoot.swift`
- `GetHog/Sources/Automation/EarlyAccessRoot.swift`
- `GetHog/Sources/Surveys/SurveysRoot.swift`
- `GetHog/Sources/Notebooks/NotebooksRoot.swift`
- `GetHog/Sources/DataManagement/AnnotationsRoot.swift`
- `GetHog/Sources/Templates/DashboardTemplatesRoot.swift`
- `GetHog/Sources/ErrorTracking/ErrorTrackingRoot.swift`
- `GetHog/Sources/Ingestion/IngestionWarningsRoot.swift`
- `GetHog/Sources/Monitor/MonitorRoots.swift`

---

### Task 1: Produce and validate the six illustration assets

**Files:**
- Create: `GetHog/Sources/Common/BrandIllustrationView.swift`
- Create: `GetHog/Tests/BrandIllustrationTests.swift`
- Create: `GetHog/Resources/Assets.xcassets/BrandEmptyDashboard.imageset/Contents.json`
- Create: `GetHog/Resources/Assets.xcassets/BrandEmptyInsights.imageset/Contents.json`
- Create: `GetHog/Resources/Assets.xcassets/BrandEmptySessions.imageset/Contents.json`
- Create: `GetHog/Resources/Assets.xcassets/BrandEmptyExperiment.imageset/Contents.json`
- Create: `GetHog/Resources/Assets.xcassets/BrandEmptyWorkspace.imageset/Contents.json`
- Create: `GetHog/Resources/Assets.xcassets/BrandAllClear.imageset/Contents.json`
- Create: eighteen PNG files under the six image sets, at 160, 320, and 480 pixels

**Interfaces:**
- Consumes: `Theme.accent`, `Theme.accentWarm`, `Theme.pageBackground`; approved icon reference `GetHog/Resources/Assets.xcassets/AppIcon.appiconset/icon-light.png`.
- Produces: `enum BrandIllustration: String, CaseIterable`, `var assetName: String`, and `BrandIllustrationView(illustration:size:)`.

- [ ] **Step 1: Write the failing asset and mapping tests**

Create `BrandIllustrationTests.swift` with this contract:

```swift
import CoreGraphics
import ImageIO
import Testing
import UIKit

@testable import GetHog

@Suite("Brand illustrations")
@MainActor
struct BrandIllustrationTests {
    private static let expected: [(BrandIllustration, String)] = [
        (.dashboard, "BrandEmptyDashboard"),
        (.insights, "BrandEmptyInsights"),
        (.sessions, "BrandEmptySessions"),
        (.experiment, "BrandEmptyExperiment"),
        (.workspace, "BrandEmptyWorkspace"),
        (.allClear, "BrandAllClear"),
    ]

    @Test("Every semantic illustration has one stable asset name")
    func stableAssetNames() {
        #expect(BrandIllustration.allCases.count == Self.expected.count)
        for (illustration, name) in Self.expected {
            #expect(illustration.assetName == name)
        }
    }

    @Test("Every illustration is compiled into the app bundle")
    func compiledAssetsLoad() throws {
        for (_, name) in Self.expected {
            let image = try #require(UIImage(named: name))
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }

    @Test("Every source image set contains clean Retina alpha PNGs")
    func sourcePNGsAreValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Assets.xcassets")
        let variants = [("1x", 160), ("2x", 320), ("3x", 480)]

        for (_, assetName) in Self.expected {
            for (scale, pixels) in variants {
                let slug = assetName
                    .replacingOccurrences(of: "Brand", with: "brand-")
                    .replacingOccurrences(of: "Empty", with: "empty-")
                    .replacingOccurrences(of: "AllClear", with: "all-clear")
                    .flatMap { $0.isUppercase ? ["-", $0.lowercased()] : [$0.lowercased()] }
                    .joined()
                    .replacingOccurrences(of: "--", with: "-")
                let url = root
                    .appendingPathComponent("\(assetName).imageset")
                    .appendingPathComponent("\(slug)-\(scale).png")
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.width == pixels)
                #expect(image.height == pixels)
                #expect(image.alphaInfo != .none)
                #expect(image.alphaInfo != .noneSkipFirst)
                #expect(image.alphaInfo != .noneSkipLast)
                #expect(try cornerAlpha(of: image) == [0, 0, 0, 0])
            }
        }
    }

    private func cornerAlpha(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return [
            pixels[3],
            pixels[(width - 1) * 4 + 3],
            pixels[(height - 1) * bytesPerRow + 3],
            pixels[(height - 1) * bytesPerRow + (width - 1) * 4 + 3],
        ]
    }
}
```

Do not weaken the corner expectation to “less than 255”; transparent corners are the contract.

- [ ] **Step 2: Run the focused test and verify the red state**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/BrandIllustrationTests
```

Expected: FAIL at compile time because `BrandIllustration` does not exist. Record that the intended suite was selected; do not treat “0 tests executed” as a valid red state if the filter itself was wrong.

- [ ] **Step 3: Add the closed illustration enum and shared renderer**

Create `BrandIllustrationView.swift` with these exact public-to-target interfaces:

```swift
import SwiftUI

enum BrandIllustration: String, CaseIterable {
    case dashboard
    case insights
    case sessions
    case experiment
    case workspace
    case allClear

    var assetName: String {
        switch self {
        case .dashboard: "BrandEmptyDashboard"
        case .insights: "BrandEmptyInsights"
        case .sessions: "BrandEmptySessions"
        case .experiment: "BrandEmptyExperiment"
        case .workspace: "BrandEmptyWorkspace"
        case .allClear: "BrandAllClear"
        }
    }
}

struct BrandIllustrationView: View {
    let illustration: BrandIllustration
    var size: CGFloat = 152

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: size * 0.32,
                bottomLeadingRadius: size * 0.40,
                bottomTrailingRadius: size * 0.30,
                topTrailingRadius: size * 0.42,
                style: .continuous
            )
            .fill(Theme.accent.opacity(0.12))
            .rotationEffect(.degrees(-3))

            Image(illustration.assetName)
                .resizable()
                .scaledToFit()
                .padding(size * 0.04)
        }
        .frame(width: size, height: size * 0.84)
        .opacity(reduceMotion || appeared ? 1 : 0)
        .offset(y: reduceMotion || appeared ? 0 : 8)
        .scaleEffect(reduceMotion || appeared ? 1 : 0.98)
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
        .onDisappear { appeared = false }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
```

If `UnevenRoundedRectangle` produces an unstable silhouette at 112 points, use one `RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)` rotated by `-3` degrees. Do not add blur, material, or a second backing layer.

- [ ] **Step 4: Generate the six master illustrations with the built-in image generator**

First inspect `icon-light.png` with the image-viewing tool. Use it as a **character and palette reference**, not an edit target. Call the current built-in image generator once per scene, at its highest available quality, using this shared prompt scaffold:

```text
Use case: illustration-story
Asset type: compact iOS empty-state spot illustration
Input image: GetHog app icon; role: character, palette, face geometry, hog snout, and outline reference only
Primary request: create one original full-body Signal Hog vignette for <SCENE>
Subject: the same friendly warm-paper hedgehog, horizontal tan hog snout with two nostrils, coral quills, deep-teal accent, thick near-black editorial outline
Style/medium: polished flat editorial vector illustration, simple human curves, crisp large shapes, minimal interior detail
Composition/framing: one compact centered character action and exactly one prop cluster, fully inside a square canvas with generous edge padding
Scene/backdrop: perfectly flat solid #00FF00 chroma-key background for removal; no floor plane, scenery, gradient, texture, cast shadow, or reflection
Constraints: consistent face and proportions across all six scenes; readable at 112 points; original GetHog geometry; no text; no watermark; no additional characters
Avoid: PostHog wordmark or logo silhouette, yellow face, blue square, flame crest, crown, clothing, foliage, detailed environment, extra limbs, duplicated props
```

Replace `<SCENE>` exactly as follows:

1. `BrandEmptyDashboard`: “arranging three small rounded dashboard cards into a clean ascending stack.”
2. `BrandEmptyInsights`: “holding a small lens toward one simple rising signal line.”
3. `BrandEmptySessions`: “reviewing one compact session-film strip with a single play frame.”
4. `BrandEmptyExperiment`: “planting one small coral experiment flag beside a simple clipboard.”
5. `BrandEmptyWorkspace`: “organizing one notebook, one note card, and one saved tile as a single prop cluster.”
6. `BrandAllClear`: “standing beside one clean shield carrying a tiny check signal.”

Reject any output that violates the prompt. If only one feature is wrong, perform one targeted edit that names only that defect and preserves all other geometry.

- [ ] **Step 5: Remove chroma, inspect, and prepare Retina variants**

For each selected source, copy it into `/private/tmp/gethog-brand-polish/`, then run the installed helper:

```bash
python /Users/abhi/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py \
  --input /private/tmp/gethog-brand-polish/brand-empty-dashboard-source.png \
  --out /private/tmp/gethog-brand-polish/brand-empty-dashboard-alpha.png \
  --auto-key border --soft-matte --transparent-threshold 12 \
  --opaque-threshold 220 --despill
```

Inspect each alpha master on both light and dark checkerboards. If a green fringe remains, rerun once with `--edge-contract 1`; do not erode clean ink edges further. Resize each square master with `sips -z` to 480, 320, and 160 pixels and place the outputs in its image set as `<slug>-3x.png`, `<slug>-2x.png`, and `<slug>-1x.png`.

Each `Contents.json` uses this shape, with the matching slug:

```json
{
  "images" : [
    { "filename" : "brand-empty-dashboard-1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "brand-empty-dashboard-2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "brand-empty-dashboard-3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

- [ ] **Step 6: Run the focused tests and verify the green state**

Run the same filtered `xcodebuild test` command. Expected: the suite executes at least 3 tests and passes. Also inspect a contact sheet of all six assets at 160 and 112 points before accepting them.

- [ ] **Step 7: Commit the asset contract**

```bash
git add GetHog/Sources/Common/BrandIllustrationView.swift \
  GetHog/Resources/Assets.xcassets/BrandEmptyDashboard.imageset \
  GetHog/Resources/Assets.xcassets/BrandEmptyInsights.imageset \
  GetHog/Resources/Assets.xcassets/BrandEmptySessions.imageset \
  GetHog/Resources/Assets.xcassets/BrandEmptyExperiment.imageset \
  GetHog/Resources/Assets.xcassets/BrandEmptyWorkspace.imageset \
  GetHog/Resources/Assets.xcassets/BrandAllClear.imageset \
  GetHog/Tests/BrandIllustrationTests.swift
git commit -m "Add Signal Hog illustration system"
```

---

### Task 2: Add a deterministic DEBUG-only empty-collection seam

**Files:**
- Modify: `GetHog/Sources/App/DemoTransport.swift:10-60, 599-620`
- Modify: `GetHog/Tests/DemoTransportTests.swift`
- Modify: `GetHogUITests/DemoLaunch.swift:32-56`

**Interfaces:**
- Consumes: existing `DemoTransport.emptyPage`, `PostHogAPI` list endpoints, and demo-only launch environment.
- Produces: `DemoTransport.EmptyCollection`, `DemoTransport.init(emptyCollection:)`, and environment key `GETHOG_DEMO_EMPTY_COLLECTION`.

- [ ] **Step 1: Write failing transport tests for representative branded collections**

Add one argument-driven Swift Testing test:

```swift
@Test(
    "the visual-verification seam empties its requested collection",
    arguments: [
        (DemoTransport.EmptyCollection.dashboards, PostHogAPI.dashboards(projectID: Self.projectID)),
        (.insights, PostHogAPI.insights(projectID: Self.projectID)),
        (.sessions, PostHogAPI.sessionRecordings(projectID: Self.projectID)),
        (.experiments, PostHogAPI.experiments(projectID: Self.projectID)),
        (.errorTracking, PostHogAPI.errorTrackingIssues(projectID: Self.projectID)),
    ]
)
func forcedEmptyCollection(
    collection: DemoTransport.EmptyCollection,
    endpoint: Endpoint
) async throws {
    var components = URLComponents(string: "https://app.example.com" + endpoint.path)!
    if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
    var request = URLRequest(url: components.url!)
    request.httpMethod = endpoint.method
    request.httpBody = endpoint.body
    let (data, response) = try await DemoTransport(emptyCollection: collection).send(request)
    #expect(response.statusCode == 200)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((object["results"] as? [Any])?.isEmpty == true)
}
```

- [ ] **Step 2: Run the focused test and verify it fails to compile**

Run `xcodebuild test` filtered to `GetHogTests/DemoTransportTests/forcedEmptyCollection`. Expected: FAIL because `EmptyCollection` and the initializer do not exist.

- [ ] **Step 3: Implement the injected collection and environment bridge**

Inside `#if DEBUG` `DemoTransport`:

```swift
enum EmptyCollection: String, CaseIterable {
    case dashboards
    case insights
    case sessions
    case experiments
    case errorTracking

    func matches(path: String, body: String) -> Bool {
        switch self {
        case .dashboards: path.hasSuffix("/dashboards/")
        case .insights: path.hasSuffix("/insights/")
        case .sessions: path.hasSuffix("/session_recordings/")
        case .experiments: path.hasSuffix("/experiments/")
        case .errorTracking:
            path.hasSuffix("/query/") && body.contains("ErrorTrackingQuery")
        }
    }
}

static let emptyCollectionEnvironment = "GETHOG_DEMO_EMPTY_COLLECTION"

private let emptyCollection: EmptyCollection?

init(emptyCollection: EmptyCollection? = nil) {
    self.emptyCollection = emptyCollection ?? ProcessInfo.processInfo.environment[
        Self.emptyCollectionEnvironment
    ].flatMap(EmptyCollection.init(rawValue:))
}
```

In `send`, after write routing and before normal fixture routing, return `Reply(Self.emptyPage)` only when `emptyCollection.matches(path: path, body: body)` is true. The path suffixes guard list routes against suppressing detail routes; the error-tracking case additionally requires the exact query kind already encoded in its POST body.

Extend `DemoLaunch.launch` with `environment: [String: String] = [:]`, and copy its values into `app.launchEnvironment` before `app.launch()`. Existing callers remain source-compatible.

- [ ] **Step 4: Run the focused and existing demo transport suites**

Run the new focused test, then all `GetHogTests/DemoTransportTests`. Expected: both pass with nonzero executed counts. Confirm the existing authored-fixture and unrouted-path tests remain green.

- [ ] **Step 5: Commit the demo-only seam**

```bash
git add GetHog/Sources/App/DemoTransport.swift GetHog/Tests/DemoTransportTests.swift \
  GetHogUITests/DemoLaunch.swift
git commit -m "Add demo-only branded empty-state fixtures"
```

---

### Task 3: Integrate the shared presentation and three primary empty states

**Files:**
- Modify: `GetHog/Sources/Common/DesignKit.swift:511-560`
- Modify: `GetHog/Sources/Dashboards/DashboardsRoot.swift:65-130`
- Modify: `GetHog/Sources/Insights/InsightsRoot.swift:190-220`
- Modify: `GetHog/Sources/Sessions/SessionsRoot.swift:205-265`
- Modify: `GetHog/Tests/BrandIllustrationTests.swift`

**Interfaces:**
- Consumes: `BrandIllustration`, `BrandIllustrationView` from Task 1.
- Produces: `EmptyStateView(..., illustration: BrandIllustration? = nil, ...)`; primary zero-data states opt in to `.dashboard`, `.insights`, and `.sessions`.

- [ ] **Step 1: Add a failing rendering contract**

Add `import SwiftUI` to `BrandIllustrationTests`, then append:

```swift
@Test("The shared empty state renders with branded art and with its symbol fallback")
func emptyStateSupportsBothDecorations() throws {
    let branded = ImageRenderer(content:
        EmptyStateView(
            title: "No dashboards",
            systemImage: "square.grid.2x2",
            illustration: .dashboard,
            message: "Synthetic empty state."
        )
        .frame(width: 393, height: 600)
    )
    let fallback = ImageRenderer(content:
        EmptyStateView(title: "No matches", systemImage: "magnifyingglass")
            .frame(width: 393, height: 600)
    )
    #expect(branded.uiImage != nil)
    #expect(fallback.uiImage != nil)
}
```

- [ ] **Step 2: Run the focused suite and verify the red state**

Expected: compile failure because `EmptyStateView` has no `illustration` argument.

- [ ] **Step 3: Add the optional illustration without changing existing call sites**

Add `var illustration: BrandIllustration?` after `systemImage` with a default of `nil`. Read `dynamicTypeSize` and use 112 points for accessibility sizes, 152 otherwise. In the `Label` icon builder:

```swift
if let illustration {
    BrandIllustrationView(
        illustration: illustration,
        size: dynamicTypeSize.isAccessibilitySize ? 112 : 152
    )
} else {
    Image(systemName: systemImage)
}
```

Do not modify the title, description, actions, `glassProminent`, `Theme.inkOnAccent`, or `.appGround()` code.

- [ ] **Step 4: Opt in only the three primary genuine zero-data branches**

- Dashboards: add `.dashboard` to the detail-column `EmptyStateView`; replace only the list branch's unfiltered `ContentUnavailableView("No dashboards", ...)` with the same shared `EmptyStateView` plus `.dashboard`.
- Insights: add `.insights` only to the `else` branch titled `No saved insights`; the `No matching insights` branch remains on `magnifyingglass`.
- Sessions: add `.sessions` only to the unnarrowed branch titled `No sessions`; failures and `No matching sessions` remain symbol-based.

Do not change any copy.

- [ ] **Step 5: Run focused tests and build**

Run the `BrandIllustrationTests` filter and `xcodebuild build` for iPhone 17. Expected: at least 4 tests pass and build succeeds.

- [ ] **Step 6: Commit the primary integrations**

```bash
git add GetHog/Sources/Common/DesignKit.swift \
  GetHog/Sources/Dashboards/DashboardsRoot.swift \
  GetHog/Sources/Insights/InsightsRoot.swift \
  GetHog/Sources/Sessions/SessionsRoot.swift \
  GetHog/Tests/BrandIllustrationTests.swift
git commit -m "Brand primary empty states"
```

---

### Task 4: Integrate reusable experiment, workspace, and all-clear scenes

**Files:**
- Modify: `GetHog/Sources/Flags/FlagsRoot.swift:135-185`
- Modify: `GetHog/Sources/Experiments/ExperimentsRoot.swift:94-120`
- Modify: `GetHog/Sources/Automation/EarlyAccessRoot.swift:64-84`
- Modify: `GetHog/Sources/Surveys/SurveysRoot.swift:104-126`
- Modify: `GetHog/Sources/Notebooks/NotebooksRoot.swift:73-95`
- Modify: `GetHog/Sources/DataManagement/AnnotationsRoot.swift:162-190`
- Modify: `GetHog/Sources/Templates/DashboardTemplatesRoot.swift:143-165`
- Modify: `GetHog/Sources/ErrorTracking/ErrorTrackingRoot.swift:223-325`
- Modify: `GetHog/Sources/Ingestion/IngestionWarningsRoot.swift:438-475`
- Modify: `GetHog/Sources/Monitor/MonitorRoots.swift:260-282`

**Interfaces:**
- Consumes: optional illustration support from Task 3.
- Produces: explicit opt-ins for the three reusable semantic scenes; no new shared API.

- [ ] **Step 1: Record the eligible call-site matrix before editing**

Use this matrix as the exact allow-list:

```text
.experiment  Flags: "No feature flags" (list and detail)
.experiment  Experiments: "No experiments"
.experiment  Early Access: "No early access features"
.experiment  Surveys: "No surveys"
.workspace   Notebooks collection: "No notebooks"
.workspace   Annotations collection: "No annotations"
.workspace   Templates unsearched branch: "No templates available"
.allClear    Errors: "No errors in this period" (list and detail)
.allClear    Ingestion unnarrowed branch: "Ingestion looks clean"
.allClear    Health: "Nothing wrong"
```

Everything not listed is forbidden in this task, including the empty notebook document, Signals, Inbox, search results, category filters, error filters, partial Logs results, and all failure branches.

- [ ] **Step 2: Add the twelve opt-ins with no other code or copy changes**

At each allow-listed `EmptyStateView`, add only `illustration: .experiment`, `.workspace`, or `.allClear` immediately after `systemImage:`. Re-read the surrounding conditional before each edit to confirm it still matches the matrix; concurrent user changes may have moved lines.

- [ ] **Step 3: Run build and focused illustration tests**

Run `xcodebuild build` and the full `BrandIllustrationTests` suite. Expected: build succeeds and at least 4 tests pass. Use `git diff --check` and inspect the diff to confirm no failure/filter/search branch acquired an illustration.

- [ ] **Step 4: Commit the semantic integrations**

```bash
git add GetHog/Sources/Flags/FlagsRoot.swift \
  GetHog/Sources/Experiments/ExperimentsRoot.swift \
  GetHog/Sources/Automation/EarlyAccessRoot.swift \
  GetHog/Sources/Surveys/SurveysRoot.swift \
  GetHog/Sources/Notebooks/NotebooksRoot.swift \
  GetHog/Sources/DataManagement/AnnotationsRoot.swift \
  GetHog/Sources/Templates/DashboardTemplatesRoot.swift \
  GetHog/Sources/ErrorTracking/ErrorTrackingRoot.swift \
  GetHog/Sources/Ingestion/IngestionWarningsRoot.swift \
  GetHog/Sources/Monitor/MonitorRoots.swift
git commit -m "Extend Signal Hog empty-state stories"
```

---

### Task 5: Add five passive product-family emblems

**Files:**
- Create: `GetHog/Sources/Common/BrandEmblemView.swift`
- Create: `GetHog/Tests/BrandEmblemTests.swift`
- Modify: `GetHog/Sources/Common/Components.swift:415-450`
- Modify: `GetHog/Sources/App/ScreenIndexSections.swift:35-55`

**Interfaces:**
- Consumes: `AppTabSection.title`, `Theme.accent`, `Theme.accentWarm`, `SectionLabel`.
- Produces: `BrandEmblem`, `BrandEmblem.init?(sectionTitle:)`, `BrandEmblemView(emblem:size:)`, and optional `SectionLabel.brandEmblem`.

- [ ] **Step 1: Write failing mapping and rendering tests**

```swift
import SwiftUI
import Testing

@testable import GetHog

@Suite("Brand product-family emblems")
@MainActor
struct BrandEmblemTests {
    @Test("Every product-family section has one emblem")
    func everyFamilyMaps() {
        let expected: [(String, BrandEmblem)] = [
            ("Analyze", .analyze),
            ("Monitor", .monitor),
            ("Data", .data),
            ("Experiment", .experiment),
            ("Workspace", .workspace),
        ]
        #expect(AppTab.sections.count == expected.count)
        for (title, emblem) in expected {
            #expect(BrandEmblem(sectionTitle: title) == emblem)
        }
    }

    @Test("Every emblem renders at compact header size", arguments: BrandEmblem.allCases)
    func renders(_ emblem: BrandEmblem) {
        let renderer = ImageRenderer(content: BrandEmblemView(emblem: emblem, size: 16))
        #expect(renderer.uiImage != nil)
    }
}
```

- [ ] **Step 2: Run the focused suite and verify it fails to compile**

Expected: `BrandEmblem` not found.

- [ ] **Step 3: Implement the five deterministic vector emblems**

Define `enum BrandEmblem: String, CaseIterable, Equatable` with the five cases and an exact title switch. Render with SwiftUI primitives at normalized proportions:

- Analyze: three rounded vertical capsules at 42%, 68%, and 94% height, rising left to right.
- Monitor: one 82%-diameter stroked circle containing a `Path` pulse from 12%/55% through 38%/55%, 48%/28%, 60%/76%, and 88%/45%.
- Data: three 30%-square rounded rectangles at top-left, top-right, and bottom-center joined by two 2-point rounded lines.
- Experiment: one vertical stem from 50%/82% to 50%/48%, branching to 20%/20% and 80%/20%, with 18%-diameter endpoint circles.
- Workspace: three 68% × 74% rounded rectangles offset diagonally by 0%, 10%, and 20%, with only the front fill opaque.

Use `.stroke(style: StrokeStyle(lineWidth: max(1.5, size * 0.11), lineCap: .round, lineJoin: .round))` for custom paths. Use `Theme.accent` for Analyze, Data, and Workspace; use `Theme.accentWarm` for Monitor and Experiment. Do not use SF Symbols inside an emblem.

- [ ] **Step 4: Extend `SectionLabel` additively and opt in the family headings**

Add `var brandEmblem: BrandEmblem?` with default `nil`. Render `BrandEmblemView` first when present; otherwise keep the existing `systemImage` branch unchanged. In `ScreenIndexSections`, pass `BrandEmblem(sectionTitle: section.title)` for each product-family header. Keep `App screens` on `macwindow`; do not change any row or `AppTab.systemImage`.

- [ ] **Step 5: Run tests and build**

Run the focused emblem suite, `SymbolNameTests`, and an iPhone 17 build. Expected: five argument cases plus the mapping test pass, existing symbol checks pass, and build succeeds.

- [ ] **Step 6: Commit the emblem tier**

```bash
git add GetHog/Sources/Common/BrandEmblemView.swift \
  GetHog/Sources/Common/Components.swift \
  GetHog/Sources/App/ScreenIndexSections.swift \
  GetHog/Tests/BrandEmblemTests.swift
git commit -m "Add Signal Hog product-family emblems"
```

---

### Task 6: Add decorative connecting and welcome motion

**Files:**
- Create: `GetHog/Sources/Common/BrandMotion.swift`
- Create: `GetHog/Tests/BrandMotionTests.swift`
- Modify: `GetHog/Sources/App/RootView.swift:491-500`
- Modify: `GetHog/Sources/Onboarding/OnboardingView.swift:69-82`
- Modify: `GetHog/Sources/Common/BrandMarkView.swift`

**Interfaces:**
- Consumes: `accessibilityReduceMotion`, existing `ProgressView("Connecting…")`, existing `BrandMarkView`.
- Produces: `BrandMotionValues.illustration(appeared:reduceMotion:)`, `BrandConnectingAccent`, and `BrandMarkView(size:animatesEntrance:)`.

- [ ] **Step 1: Write failing Reduce Motion tests**

```swift
import Testing

@testable import GetHog

@Suite("Brand motion")
struct BrandMotionTests {
    @Test("Reduce Motion always resolves illustration art to its final frame")
    func reducedMotionIsFinal() {
        let values = BrandMotionValues.illustration(appeared: false, reduceMotion: true)
        #expect(values.opacity == 1)
        #expect(values.yOffset == 0)
        #expect(values.scale == 1)
    }

    @Test("Standard motion has distinct initial and final frames")
    func standardMotionTransitions() {
        #expect(
            BrandMotionValues.illustration(appeared: false, reduceMotion: false)
                == .init(opacity: 0, yOffset: 8, scale: 0.98)
        )
        #expect(
            BrandMotionValues.illustration(appeared: true, reduceMotion: false)
                == .init(opacity: 1, yOffset: 0, scale: 1)
        )
    }
}
```

- [ ] **Step 2: Run the focused suite and verify it fails to compile**

Expected: `BrandMotionValues` not found.

- [ ] **Step 3: Centralize the existing illustration entrance values**

Create an `Equatable` `BrandMotionValues` with `opacity: Double`, `yOffset: CGFloat`, and `scale: CGFloat`, plus the tested static function. Update `BrandIllustrationView` to consume that function so the Reduce Motion contract is not duplicated between test and view.

- [ ] **Step 4: Add the three-quill connecting accent**

`BrandConnectingAccent` is a 56 × 30 accessibility-hidden, hit-testing-disabled `HStack` of three rounded capsules rotated `-14`, `0`, and `10` degrees, with heights 18, 24, and 30 points. Use `Theme.accentWarm`, tan derived from `Theme.Ink.tertiary`, and `Theme.accent`. When Reduce Motion is off, toggle a private `raised` state on appearance and apply `easeInOut(duration: 0.6).repeatForever(autoreverses: true)` with 0.12-second per-quill delays, producing the approved 1.2-second rise-and-return loop. With Reduce Motion on, render all offsets at zero and start no animation.

In `RootView`'s `.loading` branch, wrap the unchanged progress control:

```swift
VStack(spacing: Theme.Space.m) {
    BrandConnectingAccent()
    ProgressView("Connecting…")
        .controlSize(.large)
}
.appGround()
```

- [ ] **Step 5: Add the non-gating welcome mark settle**

Extend `BrandMarkView` with `var animatesEntrance = false`, read Reduce Motion, and apply a one-shot spring from scale `0.96` to `1.0` only when the flag is true. In onboarding, call `BrandMarkView(size: 104, animatesEntrance: true)`. Keep About on its existing static call. Do not add a success screen, timer, overlay, haptic, or delay to `connect()`.

- [ ] **Step 6: Run motion, illustration, onboarding, and build verification**

Run `BrandMotionTests`, `BrandIllustrationTests`, `OnboardingAccessibilityTests/testWelcomeStepSpeaksNoSymbolNames`, and an iPhone 17 build. Expected: all focused tests execute and pass; the onboarding test still sees no decorative symbol labels.

- [ ] **Step 7: Commit motion**

```bash
git add GetHog/Sources/Common/BrandMotion.swift \
  GetHog/Sources/Common/BrandIllustrationView.swift \
  GetHog/Sources/Common/BrandMarkView.swift \
  GetHog/Sources/App/RootView.swift \
  GetHog/Sources/Onboarding/OnboardingView.swift \
  GetHog/Tests/BrandMotionTests.swift
git commit -m "Add restrained Signal Hog motion"
```

---

### Task 7: Add rendered accessibility and screenshot coverage

**Files:**
- Create: `GetHogUITests/BrandedEmptyStateAccessibilityTests.swift`
- Modify: `GetHogUITests/Screenshots/StateScreenshotTests.swift`
- Modify: `GetHogUITests/Screenshots/Screenshot.swift:185-230`

**Interfaces:**
- Consumes: demo environment seam from Task 2 and production integrations from Tasks 3–6.
- Produces: three primary empty-state accessibility cases, representative screenshots for all six illustration families and the emblem tier, plus one Reduce Motion screenshot path.

- [ ] **Step 1: Write rendered accessibility tests for the three primary states**

Create an XCTestCase with three tests that call one helper:

```swift
private func auditEmptyState(tab: String, title: String) throws {
    let app = DemoLaunch.launch(
        tab: tab,
        environment: ["GETHOG_DEMO_EMPTY_COLLECTION": tab]
    )
    XCTAssertTrue(DemoLaunch.wait(for: app.staticTexts[title]))
    DemoLaunch.settle(app)
    XCTAssertEqual(
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "BrandEmpty"))
            .count,
        0,
        "Decorative illustration asset names must not enter the accessibility tree."
    )
    try app.performAccessibilityAudit()
}
```

Expose the three cases as `testBrandedEmptyDashboards`, `testBrandedEmptyInsights`, and `testBrandedEmptySessions`, calling the helper with `(dashboards, "No dashboards")`, `(insights, "No saved insights")`, and `(sessions, "No sessions")`. Because the art is hidden, title existence and the audit are the rendered behavioral contract; do not add an accessibility identifier that would make decorative art focusable just to test it.

- [ ] **Step 2: Run the three tests and confirm they exercise nonzero cases**

These tests may already pass if production integration is correct; the red/green work happened in Tasks 1–3. Their purpose is rendered regression coverage, not a second artificial red state. Confirm all three execute and pass.

- [ ] **Step 3: Add state screenshot cases**

In `StateScreenshotTests`, add a `captureBrandState(tab:title:name:emptyCollection:extraArguments:)` helper that calls the existing `capture(launching:steps:)`, launches the requested tab with the optional `GETHOG_DEMO_EMPTY_COLLECTION`, and waits for the exact title. Add these exact test methods and output names:

```text
testBrandedEmptyDashboards  -> brand-empty-dashboards, dashboards, "No dashboards"
testBrandedEmptyInsights    -> brand-empty-insights, insights, "No saved insights"
testBrandedEmptySessions    -> brand-empty-sessions, sessions, "No sessions"
testBrandedEmptyExperiments -> brand-empty-experiments, experiments, "No experiments"
testBrandedAllClearErrors   -> brand-all-clear-errors, errorTracking, "No errors in this period"
testBrandedWorkspace        -> brand-empty-workspace, annotations, "No annotations"
testBrandFamilyEmblems      -> brand-family-emblems, search, navigation title "Search"
```

Pass `emptyCollection` for Dashboards, Insights, Sessions, Experiments, and Error Tracking. Annotations is already an authored synthetic empty collection, and Search needs no override. These cases automatically produce light, dark, and AX5 images on iPhone through the existing configuration matrix.

- [ ] **Step 4: Add a Reduce Motion capture without widening the global matrix**

Extend `Screenshot.launch` with `extraArguments: [String] = []` and append them before launch. Add one dedicated state test that launches the empty dashboard with:

```swift
extraArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"]
```

Capture it as `brand-empty-dashboards-reduce-motion`. Keep this out of `Screenshot.Configuration`; a fourth global configuration would multiply every unrelated screenshot.

- [ ] **Step 5: Run targeted UI and screenshot tests, then inspect every output**

Run:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogUITests/BrandedEmptyStateAccessibilityTests \
  -only-testing:GetHogUITests/OnboardingAccessibilityTests/testWelcomeStepSpeaksNoSymbolNames

xcodebuild test -project GetHog.xcodeproj -scheme GetHogScreenshots \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandedEmptyDashboards \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandedEmptyInsights \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandedEmptySessions \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandedEmptyExperiments \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandedAllClearErrors \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandedWorkspace \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandFamilyEmblems \
  -only-testing:GetHogScreenshots/StateScreenshotTests/testBrandedEmptyDashboardReduceMotion \
  -only-testing:GetHogScreenshots/RootScreenshotTests/testOnboarding
```

Inspect the resulting PNGs under `build/Screenshots/iPhone 17/`. Confirm:

- all copy and actions remain visible;
- the mascot is secondary to the title;
- no image clips at AX5;
- backing shapes separate cleanly in light and dark;
- the Reduce Motion frame is fully visible and static;
- onboarding keeps the same layout and accessibility text;
- all six illustration families and all five emblems look related;
- no filtered, failure, or navigation surface gained brand art.

- [ ] **Step 6: Commit rendered verification coverage**

```bash
git add GetHogUITests/BrandedEmptyStateAccessibilityTests.swift \
  GetHogUITests/Screenshots/StateScreenshotTests.swift \
  GetHogUITests/Screenshots/Screenshot.swift
git commit -m "Verify branded empty states"
```

---

### Task 8: Regenerate and run the complete verification matrix

**Files:**
- Regenerate: `GetHog.xcodeproj`
- Verify only: all files changed by Tasks 1–7

**Interfaces:**
- Consumes: complete Layered Signature implementation.
- Produces: fresh build/test/accessibility/visual evidence and a focused final commit state.

- [ ] **Step 1: Inspect repository state before final verification**

Run `git status --short`, `git diff --check`, and `git log -8 --oneline`. Confirm unrelated pre-existing changes remain unstaged and every polish commit contains only its named files.

- [ ] **Step 2: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: generation succeeds. Inspect `git status`; because source/resource folders are directory-backed, the generated project may be unchanged. If it changes, inspect and commit only legitimate file-reference updates.

- [ ] **Step 3: Build the app**

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the complete app unit suite**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests
```

Expected: `** TEST SUCCEEDED **` with a nonzero executed count. If the runner is killed or reports zero, rerun the failing suite and then the complete unit suite; do not report a partial retry as the full result.

- [ ] **Step 5: Run the complete UI accessibility target**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogUITests
```

Expected: `** TEST SUCCEEDED **` with a nonzero executed count, including the three new branded-empty-state cases.

- [ ] **Step 6: Perform the final visual review**

Open the targeted light, dark, AX5, Reduce Motion, Search/emblem, Errors/all-clear, Annotations/workspace, Experiments, and onboarding images. Compare with the pre-change screenshots where available. Record any harness limitation separately from app failures; never call an unrendered screen green.

- [ ] **Step 7: Verify final diff hygiene**

Run:

```bash
git diff --check
git status --short
git log -8 --oneline
```

Expected: no unstaged polish files, no staged unrelated files, and all unrelated user changes still present. Report the final prompts, final asset paths, commits, executed test counts, screenshot paths, and any unresolved limitation.

---

## Completion Criteria

- Six consistent Signal Hog illustrations exist in the asset catalog at 1x/2x/3x with clean transparency.
- Exactly the approved genuine zero-data and all-clear branches opt into art.
- Filtered, failed, locked, selection, partial, and compact states remain unchanged.
- Five product-family headings use original passive vector emblems; tabs, rows, and controls retain SF Symbols.
- Connecting and welcome motion are decorative, non-gating, and static under Reduce Motion.
- All art is hidden from accessibility while adjacent titles/messages/actions remain intact.
- XcodeGen, build, full app unit tests, full UI tests, and targeted screenshot runs complete with reported nonzero counts.
- Final retained artifacts contain only deterministic synthetic content.
