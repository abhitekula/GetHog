# Usefulness-First Signal Grammar Design

## Objective

Make GetHog feel authored, recognizable, and specific without weakening its value as a fast native PostHog client. The redesign brands the existing working interface rather than adding a decorative layer before it.

The primary measure of success is not how much illustration appears. It is whether a user can move through Dashboards, Events, Sessions, and Feature Flags with the same or better speed while every surface feels like it belongs to the same intentionally designed product.

This design extends the approved Signal Hog identity and Layered Signature System. It does not replace those systems. Full mascot illustrations remain state-level storytelling; Signal Grammar supplies the quieter product language used while real data is present.

## Approved Direction

The approved direction is **Signal Grammar** with a strict **usefulness-first** boundary:

> Brand the interface, not the space above it.

GetHog keeps its current navigation, information architecture, controls, charts, and task flow. Brand identity comes from a small vocabulary of original product marks, quill-derived details, semantic card anatomy, useful summary compositions, and restrained state transitions. Layout and density may change when the change makes project state easier to understand; they are not frozen merely to preserve the current footprint.

The Core Four receive the richest populated-state treatment:

1. Dashboards
2. Events
3. Sessions
4. Feature Flags

Dashboard work is the implementation pilot, not a higher visual tier. Events, Sessions, and Flags receive the same degree of design care, adapted to their actual jobs rather than forced into a shared screen template.

## Governing Principles

### Useful information owns the first screenful

A populated root or overview may lead with a designed summary scene when it answers an immediate product question with real, correctly scoped data. Dense detail and execution screens still lead with their primary control or data object. No screen gains an ornamental hero, portal, masthead, duplicated metric strip, or invented introductory copy.

The test is whether the added footprint reduces cognitive work. A useful synthesis may move the first list or card lower; branding alone may not.

### Brand details must have a job

Every new detail must do at least one of the following:

- identify a product family or object kind;
- strengthen grouping and scanning;
- make state changes feel deliberate;
- establish project context;
- create continuity with the Signal Hog illustration language.

Decoration without one of these roles does not ship.

### One grammar, four compositions

The Core Four share line weight, quill angle, corner language, palette, and motion timing. They do not share a generic hero or identical overview card. Each surface uses the grammar according to its task:

- Dashboards emphasize comparison and visual hierarchy.
- Events emphasize temporal scanning and event kind.
- Sessions emphasize playback, friction, and progression.
- Flags emphasize state, branching, and rollout decisions.

### Native behavior remains visible

System controls retain familiar shape, labels, focus behavior, pointer behavior, keyboard behavior, and accessibility semantics. A custom mark may identify an object, but it never substitutes for a control whose behavior is already communicated by a standard symbol.

### Authorship comes from restraint

The system uses a repeated, hand-tuned vocabulary instead of generated-looking novelty. It explicitly avoids arbitrary blobs, decorative gradients, glass-on-glass layering, pill-shaped containers for ordinary text, floating cards without hierarchy, fake editorial copy, excessive rounding, and one-off icon styles.

## Earned-Footprint Contract

Signal Grammar may change layout, vertical rhythm, and the amount of space devoted to hierarchy when that space earns its place through synthesis, orientation, or a clearer next decision.

- Existing navigation titles and subtitles remain the project and screen context.
- Existing toolbars, search bars, filters, segmented controls, and live controls retain their behavior and prominence, though their surrounding composition may be tuned responsively.
- Existing sections may replace a generic passive symbol with a brand mark, but do not gain a second header.
- Existing cards may refine their current spine or header chrome, but do not become nested cards.
- Existing rows may replace a decorative leading SF Symbol with a semantic brand glyph. Row rhythm may be tuned when it improves scanning, but useful trailing information and touch targets remain intact.
- Existing charts, axes, legends, series colors, value labels, and interaction targets are never covered by brand decoration.

Additional footprint is acceptable only when it presents unique, truthful information or creates a materially clearer hierarchy. If a proposed treatment merely restates a value, shortens a useful label, competes with a chart, or adds scrolling without reducing cognitive work, it is removed at that size.

## Signal Summary Scenes

A Signal Summary Scene is a branded composition of real project information, not an illustration placed above the product. It may recompose an existing overview header, `StatStrip`, scope note, and one high-value finding into a more distinctive whole.

Summary scenes are eligible when all of the following are true:

- the screen is a root overview, regular-width empty detail selection, or meaningful project landing state;
- all displayed values are already loaded or deliberately fetched under the screen's existing cost contract;
- every value is correctly scoped and labeled;
- the composition helps answer “what is happening here?” or “what deserves attention?”;
- the same information is not repeated immediately below;
- the scene adapts into a tighter linear composition at compact widths and accessibility sizes.

A summary scene may use product marks, Signal Rules, asymmetrical grouping, oversized truthful figures, a small chart or diagram derived from actual data, and direct navigation into the most relevant existing item. It may not use decorative fake data, generic motivational copy, remote artwork, looping motion, or a mascot performing an unrelated activity.

The current `ProjectOverview`, `EventsOverview`, `SessionsOverview`, and `FlagsOverview` are the preferred first placements. Their existing summaries already establish data scope and cost, so the redesign should recompose those useful facts rather than add a second summary layer.

## Visual Language

Signal Grammar uses the established GetHog palette through `Theme` tokens:

- deep teal `#0B6E75` for primary brand chrome;
- warm paper `#F2EFE9` for grounded surfaces;
- coral `#D76032` for a rare signal point or quill detail;
- tan `#C78E67` for secondary product distinctions;
- near-black ink `#252023` for structure;
- warm hairline `#DDD6C9` for grouping.

`SeriesPalette` remains reserved for encoded data. Brand chrome never borrows a series color merely to make a screen more colorful, because that would imply a relationship to the data.

No new gradient is introduced. Existing type styles, spacing tokens, radii, elevation, and light/dark surface behavior remain authoritative.

## Shared Brand Primitives

### Project Stamp

A small, original hog-snout stamp replaces the generic `building.2` artwork inside the existing `ProjectSwitcher` menu label. The control, placement, menu behavior, accessibility label, accessibility hint, and always-visible navigation subtitle remain unchanged.

The stamp is a compact outline-and-fill mark, not a mascot face. It remains recognizable at toolbar scale in light and dark appearances and contains no text.

### Core Four Product Marks

Create four deterministic SwiftUI vector marks:

| Product | Visual construction | Semantic use |
| --- | --- | --- |
| Dashboards | two rising quill strokes crossing a stable baseline | dashboard collections and insight groups |
| Events | a pulse crossing a compact signal diamond | event streams and time buckets |
| Sessions | a field-reel circle with three chapter points | replay groups and recording context |
| Flags | one stem branching into a cut flag edge | rollout and variant groups |

The marks share rounded heavy-ended strokes, a consistent optical box, and the Signal Hog quill angle. They are not mini illustrations and contain no face.

Product marks are eligible in passive section labels, object-type glyphs, and project overview structure. They do not replace tab-bar destinations, navigation back buttons, play controls, toggles, menus, disclosure indicators, retry buttons, or destructive-action symbols.

### Signal Rule

The Signal Rule is a two-point structural line ending in three short coral cuts at the Signal Hog quill angle. It may be integrated into an existing `SectionLabel` or equivalent divider when it improves grouping.

It does not create a separate row. It appears at most once per section and never runs behind text. At accessibility sizes or constrained widths, the coral cuts disappear before the label or count is compressed.

### Working Surface

Existing `Card` anatomy remains the basis for populated containers. Signal Grammar refines it through two optional elements:

- the existing four-point semantic accent spine;
- a three-cut quill stitch in otherwise unused trailing header space.

The stitch is decorative, accessibility-hidden, and omitted whenever the header has an action, status, disclosure control, or insufficient room. It never appears on generic forms, alerts, sheets, settings groups, or nested cards.

### Object Glyphs

`RowGlyph` gains a controlled way to render a brand product mark or a small product-specific object glyph while preserving its current size, background treatment, and accessibility-neutral role.

Object glyphs identify stable kinds, not transient states. Status remains written as text and, where already used, reinforced by a status color. No status is communicated by glyph shape or color alone.

### Motion Signature

Motion is a brief response attached to an existing state transition:

- refresh completion;
- successful selection or project switch;
- successful save or flag update;
- first appearance of an eligible state illustration.

Populated-state motion uses one directional quill sweep, pulse, or settle lasting 160–240 milliseconds. It plays once, never loops, never delays data, never changes layout, and never owns product state. With Reduce Motion enabled, the final frame appears immediately.

There is no ambient motion, parallax, scroll choreography, mascot idle loop, animated chart decoration, sound, or haptic added by this pass.

## Richness Budget

The following budget prevents the system from becoming noisy:

### Populated compact screens

- no full mascot illustration;
- one useful summary scene is permitted on a root or overview when it replaces scattered summary content rather than duplicating it;
- dense detail screens keep the primary control or data object ahead of brand expression;
- one Core Four mark per visible section header at most;
- one semantic leading glyph per data row where the row already reserves that space;
- one optional quill stitch per primary working card;
- coral used as a small accent, not a fill for large populated regions;
- no simultaneous entrance animation across a list of rows.

### Populated regular-width screens

Regular width may use a more expressive summary composition because the overview is already the useful content of the unselected detail pane. It may combine scoped figures, one real finding or preview, and a passive product mark into an asymmetric scene. It cannot reduce the number of useful working columns after selection or change selection behavior.

### Empty, all-clear, and onboarding states

The existing Layered Signature rules remain authoritative. Full Signal Hog vignettes are eligible only for successfully loaded, unfiltered screen-level absence, genuine positive all-clear states, onboarding, About, and rare completion moments. They remain ineligible for errors, permission failures, filters, searches, selection placeholders, compact notices, charts, toolbars, or populated working screens.

## Core Four Treatment

### Dashboards

Dashboards establish the implementation pattern because they contain the densest mixture of navigation, controls, cards, charts, and interaction states.

Keep unchanged:

- dashboard list structure, pinning, search, and selection;
- inline navigation title and project subtitle;
- saved and relative range controls;
- comparison control;
- masonry behavior and card sizing;
- chart type, axes, legend, series color, freshness, loading, empty, stale, and error semantics;
- drill-down and accessibility behavior.

Add selectively:

- a Signal Summary Scene in `ProjectOverview` that recomposes the existing project identity, dashboard/computed/generated counts, and pinned-dashboard preview without repeating them below;
- the dashboard product mark in existing dashboard section labels and passive overview structure;
- semantic accent spines using existing insight-kind chrome colors, never data series colors;
- an optional quill stitch in `CardHeader` trailing space when no useful accessory occupies it;
- product-specific object glyphs for dashboard collection rows where a leading glyph already exists.

The populated detail grid receives no mascot, no metric restatement, and no decorative background behind charts.

### Events

Keep unchanged:

- search tokens and filters;
- live-tail control and behavior;
- event order, pagination, time bucket meaning, timestamps, person context, property counts, and row actions;
- event payload and detail disclosure;
- loading, error, locked, empty, and filtered-state distinctions.

Add selectively:

- a Signal Summary Scene in `EventsOverview` using the already-loaded events, kinds, people, reach, and feed scope; the most useful frequency finding may be promoted when it is not repeated below;
- the event pulse mark inside existing time-bucket or section-header space;
- stable object glyph variants for a small closed set of event kinds such as screen, exception, feature-flag call, and general capture;
- the Signal Rule only where it replaces an existing divider rather than adding one.

The event name and timestamp remain visually stronger than the glyph. Live-tail state remains explicit text and standard control state, never an animation alone.

### Sessions

Keep unchanged:

- recording search and filter behavior;
- worth-watching and friction classification;
- person, path, platform, duration, error, and playback information;
- playback controls and replay availability semantics;
- session ordering and navigation.

Add selectively:

- a Signal Summary Scene in `SessionsOverview` using the already-loaded recording count, errors, total time, not-playable count, and explicit page scope;
- the session reel mark inside existing section labels;
- a restrained chapter rhythm derived from the reel mark where the current session timeline already exists;
- a session product glyph for non-interactive row identification without replacing the play control;
- coral as a small friction accent only when the same friction state is also written in text.

Timeline decoration never implies exact event position unless it is derived from actual replay data. Synthetic visual rhythm is limited to passive icon construction, not data encoding.

### Feature Flags

Keep unchanged:

- flag list grouping, search, filtering, and selection;
- enabled state, rollout percentage, variants, conditions, and targeting language;
- switches, editors, confirmation flows, and destructive actions;
- exact status words and accessibility values.

Add selectively:

- a Signal Summary Scene in `FlagsOverview` using true project totals for flags, enabled state, multivariate flags, and one rollout finding derived from the existing store;
- the branching flag mark inside existing rollout and status section labels;
- a custom flag object glyph where a leading row glyph already exists;
- quill-derived branch geometry in passive overview diagrams or existing progress chrome.

The branch motif cannot replace a numerical rollout, variant label, condition, switch, or status word. Percentage bars continue to encode actual values with their current accessible labels.

## App-Wide Placement Matrix

| Surface | Treatment | Richness |
| --- | --- | --- |
| Project switcher | Project Stamp inside existing menu label | low, universal |
| Core Four overview states | useful Signal Summary Scenes built from existing scoped data | highest expressive tier |
| Core Four populated roots/details | product marks, object glyphs, Signal Rule, working-surface details | highest working tier |
| Search family sections | existing passive family emblems aligned to Signal Grammar stroke and optical rules | medium |
| Approved empty/all-clear states | existing Signal Hog vignettes | story tier |
| Connecting and onboarding | existing restrained quill and mascot motion | story/accent tier |
| Secondary product roots | passive family or product mark only where an existing header already accepts it | low |
| Widgets | no new treatment in this pass | none |
| Settings, privacy, account, forms | Project Stamp only when already in shared toolbar | minimal |
| Errors, locked states, permissions | exact semantics and native actions; no friendly mascot | none |
| Tab bar and sidebar destinations | retain current system symbols and navigation behavior | unchanged |

This matrix is comprehensive by rule rather than by placing an asset on every screen. Repetition is intentional only where it improves recognition.

## Component Architecture

### `BrandProductMark`

Define a closed enum for `dashboard`, `event`, `session`, `flag`, and `projectStamp`. The enum identifies semantic products; it does not contain screen-specific colors or state.

### `BrandProductMarkView`

Render each mark as deterministic SwiftUI geometry in a shared optical box. The view accepts a semantic tint and size, is accessibility-hidden by default, has no gesture, and does not animate itself.

### `SectionLabel`

Generalize the existing optional emblem support so callers may supply either an existing `BrandEmblem` or a `BrandProductMark`. Preserve the current text, uppercase treatment, accessibility label, spacing, and SF Symbol fallback. Do not create a second branded section-header component.

### `RowGlyph`

Add a closed glyph source that supports the existing system image path and the new brand product/object path. Preserve the existing initializer where practical so unrelated call sites remain unchanged. Maintain the same optical frame, Dynamic Type behavior, background, and accessibility hiding.

### `CardHeader`

Add an optional passive signature slot with a default of absent. The signature is hidden when the header has an existing useful trailing accessory or when measured width cannot preserve the title and subtitle. Existing callers render identically until they opt in.

### Summary composition ownership

Do not build one generic “branded hero” and feed four sets of labels into it. Each overview continues to own its semantic content, scope language, loading cost, ordering, and navigation. A small shared `SignalSummaryLayout` may provide adaptive spacing, alignment, product-mark placement, and compact/regular-width reflow, but it contains no metrics, copy, or business logic.

`ProjectOverview`, `EventsOverview`, `SessionsOverview`, and `FlagsOverview` each compose their own scene from existing data and reusable primitives such as `MetricTile`, `FreshnessLabel`, product marks, and real preview content. This preserves consistency without making the four products look templated.

### `ProjectSwitcher`

Change only the visible menu-label artwork from `building.2` to `BrandProductMarkView(.projectStamp)`. Preserve `spokenLabel`, hint, menu content, toolbar placement, tap target, and multi-organization behavior verbatim.

### Motion ownership

Motion is applied by the view that already observes the relevant state change. Brand mark views never create independent timers, loops, tasks, networking, or state machines.

## Accessibility and Responsive Behavior

- Product marks, stitches, and rules are decorative and accessibility-hidden when adjacent text already names the object.
- No text is baked into an asset or vector.
- ProjectSwitcher retains its current explicit accessibility label and hint.
- Status, rollout, error, freshness, and friction remain readable as text.
- Differentiate Without Color remains satisfied because brand color never carries state alone.
- At accessibility sizes, decoration disappears before text wraps poorly or controls shrink.
- At narrow widths, trailing stitches disappear before a title is truncated.
- Summary scenes reflow into a logical linear reading order; the visual and accessibility orders remain identical.
- Oversized figures scale down before labels clip, and scope notes remain adjacent to the values they qualify.
- Large Content Viewer, pointer, keyboard, Voice Control, Switch Control, and VoiceOver behavior remain owned by the existing control.
- Reduce Motion resolves every transition to a static final state.
- Light and dark appearances use `Theme` tokens; vectors do not embed appearance-specific literal colors.

## Originality and Production Rules

The Core Four marks and object glyphs are authored as deterministic vectors rather than generated raster icons. This keeps them crisp, consistent, testable, and unmistakably part of the SwiftUI interface.

Generated raster artwork remains limited to the already-approved mascot vignette tier and follows the highest-quality image-generation workflow defined in the Layered Signature spec. No new raster art is needed for populated Core Four screens.

To avoid a generic or AI-generated appearance:

- use one shared stroke family and optical grid;
- tune each mark by eye at its actual 12–32 point use sizes;
- preserve slight quill-derived asymmetry without random wobble;
- use the three-cut stitch consistently instead of inventing new flourishes;
- avoid clip-art metaphors, emoji geometry, copied SF Symbol silhouettes, and logo-like badges for every noun;
- keep naming and copy factual and product-specific;
- remove any detail whose only rationale is “more branded.”

The marks must remain independent from PostHog trademark geometry. Do not reproduce the PostHog wordmark, official hedgehog silhouette, yellow face, blue square, flame-like crest, crown, or copied logo construction. Existing independent-app and trademark disclosures remain unchanged.

## Implementation Sequence

Implementation follows four bounded checkpoints after this design and its implementation plan are approved:

1. Shared vector contract, optical tests, Project Stamp, and backward-compatible component hooks.
2. Dashboard pilot: `ProjectOverview` summary composition, populated detail, dashboard collections, responsive and chart-integrity verification.
3. Events treatment: `EventsOverview`, time buckets, and event object kinds, followed by Sessions treatment: `SessionsOverview`, replay grouping, and timeline integrity.
4. `FlagsOverview` and populated Flags treatment, app-wide low-richness placements, motion/accessibility sweep, and visual consistency cleanup.

Each checkpoint must build and pass focused tests before the next begins. If the Dashboard pilot reveals that a primitive reduces clarity or density, revise the primitive before propagating it rather than compensating screen by screen.

## Testing and Verification

Before completion:

1. Add behavior-focused contract tests for every `BrandProductMark` case and object-glyph mapping.
2. Verify existing `SectionLabel`, `RowGlyph`, `CardHeader`, and `ProjectSwitcher` call sites render and behave unchanged without opt-in.
3. Test the ProjectSwitcher accessibility label, hint, menu action, and multi-organization context.
4. Test Core Four summary compositions, rows, and headers at compact width, regular width, and accessibility Dynamic Type sizes.
5. Verify status and data meaning do not depend on color or decoration.
6. Render representative Core Four screenshots in light and dark appearances, standard and accessibility text sizes, and Reduce Motion.
7. Visually compare populated first screenfuls before and after. Any added footprint must expose unique synthesis or clearer hierarchy, and the primary working path must remain obvious in a squint test.
8. Confirm charts, axes, legends, series colors, replay timelines, event ordering, and flag rollouts remain semantically accurate.
9. Regenerate `GetHog.xcodeproj` from authoritative `project.yml` if files are added.
10. Run `swift test --package-path GetHogKit` where package scope changes.
11. Build GetHog for the configured iPhone 17 Simulator without `-derivedDataPath` or `xcrun simctl`.
12. Run `GetHogTests` and targeted `GetHogUITests`, reporting nonzero executed test counts rather than exit status alone.

All retained screenshots, fixtures, examples, and demo states remain deterministic and synthetic. No live PostHog values, credentials, customer data, or copied API payloads may enter the repository.

## Acceptance Criteria

The design is complete when:

- a user reaches the same useful data with no additional navigation, and any added scrolling is justified by unique synthesis rather than decoration;
- populated compact screens contain no full mascot or purely ornamental branded opening;
- each overview summary scene answers an immediate product question with correctly scoped real data and does not repeat the same summary below;
- Dashboards, Events, Sessions, and Flags each feel distinct in a task-appropriate way while sharing one visual grammar;
- brand additions never obscure controls, charts, timestamps, state words, or values;
- empty and error semantics remain correct;
- accessibility, Dynamic Type, Reduce Motion, light/dark appearance, keyboard, and pointer behavior remain intact;
- the interface reads as deliberately authored GetHog rather than a collection of generic dashboard patterns.

## Out of Scope

This pass does not change navigation, information architecture, data fetching, authentication, caching, filtering, search semantics, chart computation, replay parsing, feature-flag editing behavior, widget networking, error classification, permissions, product copy meaning, or user-facing theme controls. It does not add remote assets, new metrics, sound, haptics, ambient animation, a custom icon font, or a full bespoke replacement for standard system controls.
