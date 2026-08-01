# Signal Hog App Icon Design

## Objective

Replace GetHog's generic rising-chart icon with an original, memorable app icon that combines a friendly hedgehog mascot with an analytics signal. The mark should feel warm and approachable like the supplied MiniHog reference and energetic like the supplied PostHog illustration, without reproducing either logo, wordmark, silhouette, or signature character details.

The same brand mark will appear on the first-run welcome screen and the About screen so the installed icon and the app's identity agree.

## Approved Direction

The approved direction is **Signal Hog — Editorial Vector**.

The icon is a close, face-first hedgehog portrait on a deep teal field. Large coral quills form a subtle rising movement across the top of the silhouette. A warm-paper face, tan snout, near-black outline, and simple expression provide high contrast and warmth. The artwork uses bold geometry, human curves, restrained depth, and no text.

The primary palette is:

- Deep teal: `#0B6E75`
- Warm paper: `#F2EFE9`
- Coral: `#D76032`
- Tan: `#C78E67`
- Near-black ink: `#252023`

The dark appearance may use GetHog's existing dark accent and surface values, including `#3EC5CE` and `#091B1D`, while preserving the same silhouette and hierarchy. The tinted appearance is a high-contrast monochrome interpretation rather than a separate drawing.

## Originality Boundaries

The final mark must remain recognizably GetHog and must not imply that the app is first-party PostHog software.

- Do not include the PostHog wordmark, official hedgehog silhouette, yellow face, blue square, flame-like red crest, crown, or other copied logo geometry.
- Do not reproduce the presenter scene, clothing, chart easel, foliage, or exact line treatment from the supplied references.
- Use the references only for the broad ideas of a friendly hedgehog and analytics energy.
- Keep the existing independent-app and trademark disclosures unchanged.

## Candidate Generation and Selection

Use the current built-in image generator at its highest available quality. Treat both supplied images as style and subject references, not edit targets.

Generate three polished candidates within the approved Editorial Vector direction:

1. A centered, nearly symmetrical face with the rising movement carried by the quill crest.
2. A slight three-quarter face with a sweeping quill line that reads as a trend without drawing a literal chart.
3. A maximally simplified badge with the fewest interior details and the strongest small-size silhouette.

All three candidates must keep the approved palette, large facial shapes, generous edge padding, thick outline, friendly expression, and clear trademark distance. Show the candidates together at full size and at representative small icon sizes. The user selects the final candidate before any project asset is replaced.

If generation introduces text, watermarking, extra limbs or props, copied logo geometry, inconsistent eyes, muddy edges, or detail that disappears at small sizes, reject or regenerate that candidate.

## Asset Deliverables

Replace the existing files in `GetHog/Resources/Assets.xcassets/AppIcon.appiconset/`:

- `icon-light.png`: 1024 × 1024, RGB, opaque, full-color light appearance.
- `icon-dark.png`: 1024 × 1024, RGB, opaque, full-color dark appearance.
- `icon-tinted.png`: 1024 × 1024, RGB, opaque, monochrome tinted appearance with clear luminance separation.

Add `GetHog/Resources/Assets.xcassets/BrandMark.imageset/`, derived from the same selected master. It contains opaque light and dark PNGs at 128, 256, and 384 pixels for the 1x, 2x, and 3x scales. SwiftUI references the set as `BrandMark`, and its artwork remains visually identical to the installed icon at equivalent size. The artwork is synthetic and contains no customer or PostHog API data.

## App Integration

Replace the generic `chart.xyaxis.line` brand glyph in two places:

- The 104-point welcome mark in `OnboardingView`.
- The brand header in `AboutView`.

Both placements use the new in-app image asset, clip it with a continuous rounded rectangle appropriate to its rendered size, and remain accessibility-hidden because adjacent text already announces the app name. Functional chart symbols elsewhere in the app are not brand marks and remain unchanged. Widgets and system surfaces inherit the application icon through the app bundle; their data UI does not gain decorative mascot artwork.

## Validation

Before completion:

1. Inspect each 1024 × 1024 source and confirm dimensions, RGB color, and no alpha channel.
2. Review a contact sheet at 1024, 180, 60, 40, and 29 points to confirm silhouette, expression, and contrast remain legible.
3. Inspect light, dark, and tinted appearances for consistent geometry and sufficient foreground/background separation.
4. Regenerate `GetHog.xcodeproj` from authoritative `project.yml` if project structure changes.
5. Build the GetHog scheme for the configured iPhone 17 Simulator without `-derivedDataPath` or `xcrun simctl`.
6. Run the relevant app tests and report nonzero executed test counts.
7. Render or exercise onboarding and About in the simulator, checking the new mark in light and dark appearances and confirming adjacent accessibility labels remain correct.

## Out of Scope

This change does not redesign navigation, charts, widgets, app tint, typography, marketing pages, or the PostHog independence disclosures. It does not add a wordmark or animate the mascot.
