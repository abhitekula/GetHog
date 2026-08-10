# Responsive wide-layout composition design

## Purpose

Use wide Apple-platform canvases to advance the user's primary task instead of reserving a tall column for a small amount of metadata. The immediate defect is the Dashboard hub on visionOS: its project summary occupies the entire leading column while four pinned charts are confined to the two columns beside it. The same class of issue must be searched for across every shared and platform-shaped root.

## Approved direction

For the Dashboard hub, replace the tall leading project-summary column with a compact, full-width Project signal band. Place the pinned preview directly underneath in exactly two equal chart columns. The band carries the project name and dashboard, computed, and generated counts; it does not become another card. The pinned section keeps its authored chart cards and two-column reading order.

Regular-width iPadOS, macOS, and visionOS share this composition through `DashboardHub` and `ProjectOverviewContent`. At a width where two readable preview columns no longer fit, the preview becomes one column. Compact iPhone keeps its existing list-to-detail route and does not inherit the wide hub.

## Alternatives considered

1. Keep a narrower permanent summary rail. This reduces but does not remove the empty vertical column and still makes the charts secondary to metadata.
2. Put the project summary into the first grid card. This produces an uneven first grid row and incorrectly presents metadata as a peer dashboard tile.
3. Use the selected full-width band followed by the two-column preview. This preserves hierarchy, gives the charts the full canvas, and uses existing responsive SwiftUI primitives without custom geometry.

The third approach is selected.

## Cross-platform composition sweep

Inspect every root and platform adaptation for the same objective failure class:

- A leading or trailing column contains only a short heading, count, filter, or explanatory block while dense primary content is restricted beside it.
- A metadata region reserves full viewport height even though its content would fit in a compact band above the primary material.
- The same destination roster or navigation hierarchy is shown twice at the same width, reducing usable content width.
- A regular-width screen leaves most of the canvas inert while its primary cards, charts, or rows remain unnecessarily narrow.
- A layout remains fixed at three or more columns when two wider columns would improve readability and use the vertical canvas naturally.

Do not flatten intentional master-detail layouts, contextual inspectors, comparison views, or sidebars whose persistent context changes the primary content. Each correction must name the user task it improves and have a rendered geometry or semantic oracle that fails on the prior composition.

## General layout-quality sweep

The sweep also evaluates every deterministic page for broader layout defects, not only sparse columns:

- Weak hierarchy where the primary answer competes with navigation, filters, or metadata.
- Controls crowded into a toolbar or row when secondary actions belong in a labelled overflow.
- Text clipped, ellipsized, or stretched beyond a readable measure at supported widths and Dynamic Type sizes.
- Cards or rows using rigid dimensions where natural reflow would preserve identity and action labels.
- Empty, loading, error, or locked states that are visually detached from the controls and context that produced them.
- tvOS focus order that opens on navigation instead of the first meaningful reading or hides a valid action from the Siri Remote.
- Repeated decorative containers or generic empty treatments that weaken the established quiet-craft hierarchy without adding information.
- Large canvases that leave room unused when one adjacent, task-relevant question can be answered from already-loaded data.

Every proposed change must be tied to a reproducible screenshot, geometry, focus, overflow, or content-state failure. Pure preference differences remain documented critique choices rather than automatic code changes. Accessibility is not a separate audit in this loop, but existing semantic labels and test selectors must not regress while visible layout changes.

## Responsive behavior

- Prefer semantic size classes, container-relative fitting, `ViewThatFits`, and adaptive grids over device-name or platform-name branches.
- Two chart columns require both columns to stay above the existing measured chart minimum; otherwise use one.
- Summary metadata may wrap or stack internally at accessibility sizes without reinstating a full-height metadata column.
- Preserve one scroll owner for the loaded Dashboard hub and preserve selection, search, refresh, error, empty, and loading behavior.
- Keep the existing quiet-craft palette, typography, signal rule, section labels, and chart cards. This is a composition correction, not a new visual language.

## Verification

Fresh rendered screenshots and measured geometry are the primary acceptance evidence for this visual work. Add focused rendered tests where they protect a load-bearing responsive rule, but do not manufacture a failing test for every visual adjustment. The verification set should prove:

- Project signal spans the hub's content width above the pinned preview rather than occupying a peer column.
- Two pinned chart cards share the first preview row at wide Vision, iPad, and Mac widths.
- The chart grid collapses without clipping at the narrow regular-width boundary.
- The hub remains exactly one scroll surface and its collection remains reachable.

For every additional issue found by the composition sweep, capture the prior and corrected layout at the affected widths. Add the smallest behavior or rendered geometry test only when the rule is stable and regression-prone. Run focused platform checks first, then the complete affected UI targets during final integration.

## Boundaries

- No live customer data, new fixtures, decorative filler, or duplicated summary cards.
- No change to compact iPhone Dashboard navigation.
- No change to platform shells unless the same measured composition defect is present.
- Mac rendered acceptance remains blocked when LocalAuthentication or foreground-window ownership prevents a test method from entering; source and unit checks do not substitute for that evidence.
