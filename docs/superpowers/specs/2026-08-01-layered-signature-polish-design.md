# Layered Signature Polish Design

## Objective

Extend GetHog's approved Signal Hog identity into a restrained in-app visual system. The app should feel original, polished, and professional without making its analytics surfaces less legible or replacing familiar controls with decorative art.

This pass adds branded empty-state illustrations, passive product-family emblems, and limited decorative motion. It does not change navigation, data loading, filtering, state classification, actions, or accessibility semantics.

## Approved Direction

The approved direction is **Layered Signature System** with **Mascot Vignettes** as its most expressive tier.

Brand expression scales with available space and informational density:

1. **Story:** a full Signal Hog vignette for a meaningful, screen-level state.
2. **Emblem:** an original vector badge for a passive product-family heading or educational card.
3. **Accent:** a quill curve, warm field, or subtle decorative transition around existing content.

Dense data, charts, lists, filters, controls, tab bars, sidebar destinations, menus, error semantics, and widgets retain their current native visual language.

## Visual Language

All new artwork must remain consistent with the approved app icon:

- Deep teal: `#0B6E75`
- Warm paper: `#F2EFE9`
- Coral: `#D76032`
- Tan: `#C78E67`
- Near-black ink: `#252023`
- Dark accent: `#3EC5CE`
- Dark ground: `#091B1D`

The Signal Hog keeps the app icon's warm-paper face, horizontal tan hog snout with two nostrils, coral quills, thick near-black outline, friendly expression, and simple editorial-vector geometry. Vignettes may show a compact full character, but must not add clothing, scenery, wordmarks, or visual details that become muddy at small sizes.

Each vignette contains one character action, one product metaphor, and one soft backing shape. It contains no text, watermark, customer data, copied API content, or PostHog logo geometry.

## Story Tier: Mascot Vignettes

Create six reusable, transparent, full-color illustration assets. Each asset has one canonical name and a narrow semantic role:

| Asset | Scene | Eligible states |
| --- | --- | --- |
| `BrandEmptyDashboard` | Signal Hog arranging a small ascending stack of dashboard cards | Unfiltered, successfully loaded project with no dashboards |
| `BrandEmptyInsights` | Signal Hog scouting a clean signal line with a small lens | Unfiltered, successfully loaded project with no saved insights |
| `BrandEmptySessions` | Signal Hog reviewing a compact session-film strip | Unfiltered, successfully loaded project with no session recordings |
| `BrandEmptyExperiment` | Signal Hog planting a small coral experiment flag beside a simple clipboard | Unfiltered, successfully loaded empty states in Flags, Experiments, Surveys, and Early Access |
| `BrandEmptyWorkspace` | Signal Hog organizing a notebook, note card, and saved tile | Unfiltered, successfully loaded collection states in Notebooks, Annotations, and Dashboard Templates |
| `BrandAllClear` | Signal Hog beside a clean shield and tiny check signal | Positive, successfully loaded states such as no errors in the chosen period, clean ingestion, and no instrumentation health issues |

The first three assets are dedicated to GetHog's primary product surfaces. The latter three are deliberately reusable by meaning so the app gains consistency without accumulating a bespoke illustration for every screen.

### Eligibility Rules

An illustration appears only when the state is:

- screen-level or the empty detail column of the same screen;
- successfully loaded;
- unfiltered and unsearched beyond the screen's required project or time-window scope;
- a genuine absence of project data, or a positive all-clear result;
- large enough to keep the title, message, and action fully visible at accessibility sizes.

An illustration never appears for:

- load failures or retry states;
- missing permissions or locked capabilities;
- search, filter, or narrowing results;
- "pick an item" selection placeholders;
- compact section-level empty notices;
- truncated or partial results that cannot support a project-wide claim;
- embedded cards, widgets, menus, toolbars, buttons, or charts.

This distinction is semantic, not cosmetic. Existing conditionals remain authoritative; the polish pass only assigns artwork to already-correct branches.

## Emblem Tier: Passive Product-Family Marks

Create five original, single-color vector emblems for the existing product families:

- Analyze: rising signal bars.
- Monitor: a guarded pulse.
- Data: three connected data tiles.
- Experiment: a branching trial mark.
- Workspace: stacked saved pages.

The emblems use the Signal Hog's quill angle and rounded, heavy-ended line language without drawing a mascot face at icon size. They appear in passive family headings, beginning with `ScreenIndexSections` on compact-width Search. They do not replace `AppTab.systemImage`, tab-bar icons, sidebar destination icons, row affordances, or action icons.

Each emblem has a stable accessibility-neutral role. The heading text names the section, so the image is decorative and hidden from accessibility.

## Accent Tier and Motion

Motion is ornamental and state-independent.

### Empty-State Entrance

When a branded illustration first appears, it fades from zero to full opacity while rising 8 points and scaling from 0.98 to 1.0 over 350 milliseconds. It plays once per view appearance and never loops.

### Connecting Accent

The app's initial `Connecting…` phase keeps its native `ProgressView` and label. A small three-quill accent rises by 4 points in a staggered 1.2-second ease-in-out loop while that already-existing loading phase is active. The accent cannot delay the phase, replace progress semantics, or own animation state that outlives the view.

### Onboarding Brand Moment

The welcome screen's existing brand mark gives one short spring from 0.96 to full scale when it first appears. Onboarding has no success screen—the app transitions directly to ready after a valid key—so this pass does not invent a delayed success step or overlay. Navigation and button availability remain driven by the current onboarding state, not animation completion.

### Motion Accessibility

Every brand animation reads `accessibilityReduceMotion`. With Reduce Motion enabled, the final static frame appears immediately. No empty state contains continuous motion. No animation conveys information, changes hit targets, intercepts interaction, or alters layout after the content becomes available.

## Component Architecture

### `BrandIllustration`

Define a closed enum for the six semantic illustrations. It owns the asset-name mapping, not screen code. This makes missing assets and accidental renames testable.

### `BrandIllustrationView`

Render one `BrandIllustration` at a caller-provided size. The view:

- uses a local asset-catalog image;
- adds the shared soft backing shape with `Theme` colors so one transparent illustration works in light and dark appearances;
- applies the one-shot entrance motion;
- hides the artwork from accessibility;
- never handles taps or gestures.

### `EmptyStateView`

Add an optional `illustration: BrandIllustration?` parameter with a default of `nil`. When supplied, the illustration replaces only the large decorative SF Symbol above the title. The existing title, message, action, button style, app ground, and accessibility behavior remain unchanged. Existing call sites compile and render exactly as before until they explicitly opt in.

### `BrandEmblemView`

Render one of the five product-family emblems as a deterministic SwiftUI vector. The emblem accepts a size and semantic tint, has no gesture, and is accessibility-hidden. Passive header components may opt in without changing navigation rows.

### `BrandConnectingAccent`

Render the decorative quill accent beside the existing app-loading `ProgressView`. It reads Reduce Motion and has no state or callback of its own.

## Asset Production

Use the current built-in image generator at its highest available quality. The approved app icon is the character reference, not an edit target. Generate each vignette as an original editorial-vector scene on a perfectly flat removable chroma-key field, then remove the field locally and validate the alpha matte.

Use the same structured character description, palette, outline weight, face geometry, snout, and scale across all six prompts. Each prompt changes only the pose and single product metaphor. Reject outputs with text, extra characters, inconsistent facial features, more than one prop cluster, detailed scenery, shadows that require a floor plane, copied logo geometry, or weak separation at small sizes.

Store final project assets in `GetHog/Resources/Assets.xcassets/` as named image sets. Provide 1x, 2x, and 3x PNGs sized for a 160-point maximum rendering target: 160, 320, and 480 pixels. Preserve alpha and validate transparent corners, subject coverage, clean outlines, and no chroma fringe.

Vector emblems are deterministic SwiftUI shapes rather than generated raster images. They follow the same palette and line language but remain crisp at Dynamic Type and Retina scales.

All retained artwork and screenshots are synthetic.

## Accessibility and Layout

- No text is baked into artwork.
- Adjacent SwiftUI text remains the sole accessible description of each state.
- Illustrations and emblems are accessibility-hidden.
- At accessibility text sizes, artwork may shrink before text or actions are compressed.
- Titles and messages retain unlimited wrapping.
- Actions retain their current labels, targets, and ordering.
- The backing shape uses `Theme` colors with sufficient separation in light and dark appearances.
- Reduce Motion resolves every brand animation to a static final frame.
- Differentiate Without Color remains satisfied because artwork never carries state meaning on its own.

## Testing and Verification

Before completion:

1. Add a failing asset-contract test for all six illustration names before adding assets.
2. Verify each 1x, 2x, and 3x PNG exists, decodes, has the expected dimensions, contains alpha, has transparent corners, and has non-empty subject coverage.
3. Add behavior-focused tests for the closed illustration-to-asset mapping and product-family emblem mapping.
4. Confirm every untouched `EmptyStateView` call site still uses its current SF Symbol fallback.
5. Regenerate `GetHog.xcodeproj` from authoritative `project.yml` after file additions.
6. Build the GetHog scheme for the configured iPhone 17 Simulator without `-derivedDataPath` or `xcrun simctl`.
7. Run `GetHogTests` and report a nonzero executed-test count.
8. Run targeted UI accessibility tests for onboarding and branded empty states.
9. Render light, dark, accessibility-size, and Reduce Motion screenshots for representative story, emblem, connecting, and onboarding placements.
10. Visually confirm that controls, navigation, charts, error states, locked states, filtered states, and widget behavior are unchanged.

## Rollout Order

Implement in four bounded checkpoints within the same polish pass:

1. Shared illustration contract and the three primary vignettes for Dashboards, Insights, and Sessions.
2. Experiment, Workspace, and All Clear vignettes at explicitly eligible states.
3. Five product-family emblems in passive headings.
4. Connecting and welcome-screen motion, followed by the full visual and accessibility sweep.

Each checkpoint must compile and pass its focused tests before the next begins. Asset generation may happen together to preserve character consistency, but code integration follows the checkpoints above.

## Originality and Trademark Boundaries

The artwork remains recognizably GetHog and must not imply that the app is first-party PostHog software.

- Do not include the PostHog wordmark, official hedgehog silhouette, yellow face, blue square, flame-like red crest, crown, or copied logo geometry.
- Do not reproduce supplied reference scenes, clothing, props, foliage, or exact line treatment.
- Preserve the existing independent-app and trademark disclosures verbatim.

## Out of Scope

This pass does not redesign navigation, replace action or destination icons, alter charts or data encoding, add sound or haptics, change copy semantics, add remote assets, animate widgets, modify networking, change cache behavior, or add user-facing theme controls.
