# Signal Hog App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate, select, install, and verify an original Signal Hog app icon across GetHog's system and in-app brand surfaces.

**Architecture:** A selected 1024-pixel light master anchors the family. Strict image-to-image edits create geometry-matched dark and tinted appearances, an asset catalog exposes the same artwork in-app, and one `BrandMarkView` keeps sizing, clipping, and accessibility behavior consistent across onboarding and About.

**Tech Stack:** Built-in high-quality image generation, Xcode asset catalogs, SwiftUI, Swift 6, Swift Testing, XCTest/XCUITest, XcodeGen, `xcodebuild`, and `sips` for deterministic resizing and metadata checks.

## Global Constraints

- Work directly on `main`; do not create a branch or worktree.
- `project.yml` is authoritative and `GetHog.xcodeproj` is generated.
- Use Swift 6 strict concurrency and four-space indentation.
- All retained artwork and test artifacts must be synthetic; never include credentials, customer data, or copied API payloads.
- Do not include PostHog logos, wordmarks, official silhouette, yellow face, blue square, flame-like crest, crown, or copied logo geometry.
- App icon sources are 1024 × 1024 opaque RGB PNGs with light, dark, and tinted appearances.
- Do not use `xcrun simctl` or pass `-derivedDataPath`.
- Report nonzero executed test counts, not only command exit status.

---

## File Map

- Create `GetHog/Resources/Assets.xcassets/BrandMark.imageset/Contents.json`: light/dark in-app appearance mapping.
- Create `GetHog/Resources/Assets.xcassets/BrandMark.imageset/brand-mark-light-{1x,2x,3x}.png`: light in-app artwork at 128, 256, and 384 pixels.
- Create `GetHog/Resources/Assets.xcassets/BrandMark.imageset/brand-mark-dark-{1x,2x,3x}.png`: dark in-app artwork at 128, 256, and 384 pixels.
- Replace `GetHog/Resources/Assets.xcassets/AppIcon.appiconset/icon-{light,dark,tinted}.png`: installed app-icon appearances.
- Create `GetHog/Sources/Common/BrandMarkView.swift`: reusable rendering, clipping, and accessibility behavior.
- Modify `GetHog/Sources/Onboarding/OnboardingView.swift`: replace the generic welcome glyph.
- Modify `GetHog/Sources/Settings/AboutView.swift`: replace the generic About glyph.
- Create `GetHog/Tests/BrandMarkAssetTests.swift`: verify that the compiled asset catalog exposes the mark.
- Regenerate `GetHog.xcodeproj`: include the new Swift source and test files.

---

### Task 1: Generate and Select the Light Master

**Files:**
- Preview only: `.superpowers/brainstorm/8229-1785599874/candidates/signal-hog-{centered,sweeping,minimal}.png`

**Interfaces:**
- Consumes: the two user-supplied logo references and the approved design spec.
- Produces: one user-selected opaque square light master with candidate name recorded in the task conversation.

- [ ] **Step 1: Generate the centered candidate**

Use the built-in image generator with both supplied images as references and this prompt:

```text
Use case: logo-brand
Asset type: iOS app icon candidate, light appearance
Primary request: Create an original Signal Hog mascot icon for GetHog, a native analytics app. This candidate is a centered, nearly symmetrical face-first hedgehog portrait whose coral quill crest carries a subtle rising trend from lower left to upper right.
Input images: Image 1 is a broad mood reference for an approachable hedgehog analyst; Image 2 is a broad reference for friendly mascot simplicity. Do not reproduce either image's character, scene, clothing, silhouette, or logo geometry.
Scene/backdrop: edge-to-edge deep teal #0B6E75 square field, no pre-rounded corners.
Subject: one friendly original hedgehog head and shoulders, warm-paper #F2EFE9 face, tan #C78E67 snout, coral #D76032 quills, near-black #252023 ink.
Style/medium: premium editorial vector illustration, bold geometry, clean human curves, thick consistent outline, restrained flat depth, crisp production finish.
Composition/framing: centered close portrait, generous safe padding, huge readable facial shapes, strong silhouette at 29 points.
Constraints: no text, no watermark, no props, no chart easel, no clothing, no foliage, no yellow face, no blue square, no crown, no flame crest, no official PostHog logo or wordmark, no transparency.
Avoid: photorealism, 3D toy rendering, sketch texture, thin lines, clutter, gradients that muddy small sizes, copied brand elements.
```

- [ ] **Step 2: Generate the sweeping candidate**

Use the same tool and fixed palette/constraints, changing only composition to:

```text
Subject and composition change only: turn the original hedgehog face slightly three-quarter toward the right. Use one broad sweeping quill rhythm to imply an upward trend without drawing a literal chart. Preserve the same large facial shapes, thick outline, teal field, warm-paper face, coral quills, tan snout, near-black ink, safe padding, and all originality constraints.
```

- [ ] **Step 3: Generate the minimal candidate**

Use the same tool and fixed palette/constraints, changing only simplification to:

```text
Subject and composition change only: reduce the mascot to the fewest shapes that still read as a friendly hedgehog and an upward signal. Use a centered badge-like portrait, one quill mass, two eyes, one snout, and no decorative interior detail. Preserve the palette, thick outline, safe padding, and all originality constraints.
```

- [ ] **Step 4: Inspect and prepare the comparison**

Inspect every result at original resolution. Copy acceptable candidates into the preview-only paths above, then create one companion screen showing each candidate at 256, 60, 40, and 29 points. Reject any candidate with text, watermarking, copied geometry, inconsistent anatomy, muddy edges, or facial features that vanish at 29 points.

- [ ] **Step 5: Obtain the final candidate selection**

Present the companion URL and pause. Continue only after the user selects one generated candidate or requests a targeted revision.

---

### Task 2: Install the Appearance Family with a Failing Asset Test

**Files:**
- Create: `GetHog/Tests/BrandMarkAssetTests.swift`
- Create: `GetHog/Resources/Assets.xcassets/BrandMark.imageset/Contents.json`
- Create: `GetHog/Resources/Assets.xcassets/BrandMark.imageset/*.png`
- Replace: `GetHog/Resources/Assets.xcassets/AppIcon.appiconset/icon-light.png`
- Replace: `GetHog/Resources/Assets.xcassets/AppIcon.appiconset/icon-dark.png`
- Replace: `GetHog/Resources/Assets.xcassets/AppIcon.appiconset/icon-tinted.png`

**Interfaces:**
- Consumes: the selected light master from Task 1.
- Produces: the compiled `BrandMark` asset and three valid `AppIcon` appearances.

- [ ] **Step 1: Write the failing asset test**

```swift
import Testing
import UIKit

@Suite("Brand mark asset")
@MainActor
struct BrandMarkAssetTests {
    @Test("The app bundle exposes the in-app brand mark")
    func brandMarkLoads() throws {
        let image = try #require(UIImage(named: "BrandMark"))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
```

- [ ] **Step 2: Regenerate the project and verify the new test fails**

Run:

```bash
xcodegen generate
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests/BrandMarkAssetTests
```

Expected: one test executes and fails because `UIImage(named: "BrandMark")` is `nil`.

- [ ] **Step 3: Create dark and tinted appearances**

Use the selected light master as the edit target in two built-in image-generation edits. The dark edit must keep every contour and feature position unchanged while replacing the field with `#091B1D`, using `#3EC5CE` where teal becomes foreground, and keeping coral warmth. The tinted edit must keep geometry unchanged and convert the art to a high-contrast neutral monochrome image with no transparency. Inspect both against the light master and reject contour drift.

- [ ] **Step 4: Normalize the app-icon files**

Resize/crop each selected appearance to exactly 1024 × 1024 and save it over the matching existing `icon-light.png`, `icon-dark.png`, and `icon-tinted.png`. Use `sips` only for deterministic resizing/color conversion, not creative retouching.

- [ ] **Step 5: Build the in-app image set**

Derive opaque 128, 256, and 384 pixel light/dark PNGs from the corresponding 1024-pixel masters. Add this exact `Contents.json`:

```json
{
  "images" : [
    { "filename" : "brand-mark-light-1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "brand-mark-light-2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "brand-mark-light-3x.png", "idiom" : "universal", "scale" : "3x" },
    { "appearances" : [{ "appearance" : "luminosity", "value" : "dark" }], "filename" : "brand-mark-dark-1x.png", "idiom" : "universal", "scale" : "1x" },
    { "appearances" : [{ "appearance" : "luminosity", "value" : "dark" }], "filename" : "brand-mark-dark-2x.png", "idiom" : "universal", "scale" : "2x" },
    { "appearances" : [{ "appearance" : "luminosity", "value" : "dark" }], "filename" : "brand-mark-dark-3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

- [ ] **Step 6: Verify the asset test passes**

Run the filtered `xcodebuild test` command from Step 2 again. Expected: one test executes and passes.

---

### Task 3: Replace the In-App Brand Glyphs

**Files:**
- Create: `GetHog/Sources/Common/BrandMarkView.swift`
- Modify: `GetHog/Sources/Onboarding/OnboardingView.swift:73-92`
- Modify: `GetHog/Sources/Settings/AboutView.swift:27-33`

**Interfaces:**
- Consumes: asset-catalog image named `BrandMark`.
- Produces: `BrandMarkView.init(size: CGFloat)` for brand-only placements.

- [ ] **Step 1: Add the shared brand view**

```swift
import SwiftUI

struct BrandMarkView: View {
    let size: CGFloat

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Replace the onboarding glyph**

Replace the generic symbol, tint, frame, and translucent background with:

```swift
BrandMarkView(size: 104)
```

Rewrite the adjacent comment to state that the original GetHog mark is hidden from accessibility because the `GetHog` title directly below already names the app.

- [ ] **Step 3: Replace the About glyph**

Replace the generic symbol and tint with:

```swift
BrandMarkView(size: 64)
```

Rewrite the adjacent comment to state that this is GetHog's original mark and not a PostHog logo. Preserve the independence and trademark copy.

- [ ] **Step 4: Regenerate and build**

Run:

```bash
xcodegen generate
xcodebuild build -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: `BUILD SUCCEEDED`.

---

### Task 4: Verify Rendered Branding and Commit

**Files:**
- Verify: all files changed in Tasks 1–3.

**Interfaces:**
- Consumes: the completed asset family and SwiftUI integration.
- Produces: evidence that the icon family is valid, visible, accessible, and buildable.

- [ ] **Step 1: Verify PNG metadata**

Run `sips -g pixelWidth -g pixelHeight -g hasAlpha` on all three app icon files and all six BrandMark files. Confirm the app icons are 1024 × 1024 with `hasAlpha: no`; confirm the in-app files are 128, 256, and 384 pixels with `hasAlpha: no`.

- [ ] **Step 2: Run the relevant unit test target**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests
```

Expected: `TEST SUCCEEDED` and a nonzero executed test count.

- [ ] **Step 3: Run onboarding accessibility coverage**

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogUITests/OnboardingAccessibilityTests/testWelcomeStepSpeaksNoSymbolNames \
  -only-testing:GetHogUITests/AccessibilityAuditTests/testOnboarding
```

Expected: two tests execute and pass. If a retained simulator credential prevents onboarding from appearing, report the environmental blocker rather than calling the UI verification green.

- [ ] **Step 4: Render onboarding and About**

Run the `GetHogScreenshots` scheme for `RootScreenshotTests/testOnboarding` and `StateScreenshotTests/testSettingsAbout` using the iPhone 17 destination. Inspect the produced images for correct light/dark artwork, rounded clipping, no seams, and legibility. Use only deterministic demo/onboarding data already supplied by the repository.

- [ ] **Step 5: Review the final diff**

Run `git diff --check`, confirm no unrelated files changed, and confirm the About footer still contains the existing independent-app and trademark disclosure.

- [ ] **Step 6: Commit the implementation**

```bash
git add GetHog.xcodeproj GetHog/Resources/Assets.xcassets \
  GetHog/Sources/Common/BrandMarkView.swift \
  GetHog/Sources/Onboarding/OnboardingView.swift \
  GetHog/Sources/Settings/AboutView.swift \
  GetHog/Tests/BrandMarkAssetTests.swift
git commit -m "Add Signal Hog app icon"
```
