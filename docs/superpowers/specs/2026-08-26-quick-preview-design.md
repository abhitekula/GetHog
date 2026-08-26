# Quick Preview Design

## Goal

Add a native, usefulness-first Quick Preview interaction to selected list-level
objects in GetHog. A preview must answer whether an object is worth opening
without turning into a second detail screen, spending the organisation-wide
request budget speculatively, or sending the user to PostHog's web console.

The first implementation covers list rows on these product surfaces:

- Dashboards;
- Events;
- Sessions;
- Flags;
- Errors;
- Insights;
- Tracing.

Support, LLM traces, Warehouse, Renders, Taxonomy, and heterogeneous Search
results are the next candidates after the first implementation is verified.
People, Replay Summaries, Health, Ingestion, Web Analytics, SQL, Settings, and
already-expanded detail rows do not receive Quick Preview because their current
rows already expose the decision payload or have no meaningful detail choice.

## Product Principle

Quick Preview exists to help GetHog complete a task itself. It does not contain
"Open in PostHog" or "Copy PostHog link" actions. On touched list rows, the new
menu replaces those external actions with in-app actions. Explicit web
fallbacks for content GetHog genuinely cannot render remain outside this
change.

The boundary is:

> Preview answers "Is this worth opening?" Detail proves what happened.

Normal row activation remains the primary, discoverable route to detail. Quick
Preview is an accelerator, never the only route to information or an action.

## Chosen Approach

Render an immediate feature-specific card from the row model, then optionally
enrich only Dashboards and Insights with one cached-result request. This keeps
the interaction instant on every surface while allowing the two objects whose
list payloads do not contain their decisive result to become useful.

Two alternatives were rejected:

1. A metadata-only system would be cheap but would leave Dashboard and Insight
   previews too close to their existing rows.
2. Reusing the full detail loader would duplicate navigation and could trigger
   request fan-out, replay blobs, WebKit construction, or result recomputation
   from a transient gesture.

## Interaction

On iPhone and iPad, touching and holding an eligible row presents the system
context menu with a custom preview. Secondary click presents the same menu on
iPad pointer configurations. visionOS uses the same system interaction; gaze
hover only highlights the row and never starts work.

The menu has an object-specific in-app action such as "Open Dashboard", "Open
Event", or "Open Session". A supported multiwindow shell may additionally show
"Open in New Window". The preview itself is read-only; it contains no tiny
buttons, toggles, destructive actions, or production mutations.

SwiftUI does not display a custom context-menu preview on macOS. Mac therefore
receives the improved in-app menu actions but no Force-click behavior, automatic
hover popover, or imitation of the iOS preview. tvOS, watchOS, widgets, and Top
Shelf remain unchanged.

There is no hardware-pressure dependency. The interaction is named Quick
Preview in code, tests, and user-facing accessibility text, never Force Touch.

## Shared Components

`GetHog/Sources/Common/QuickPreview.swift` owns two presentation primitives:

1. `QuickPreviewCard<Content>` supplies the common card ground, product mark,
   title, optional subtitle/status, readable width, Dynamic Type adaptation,
   and a feature-owned body.
2. A `quickPreview` view modifier attaches the native context menu, custom
   preview builder, and menu actions without owning navigation or networking.

The card reuses `Card`, `CardHeader`, `StatStrip`, `StatusPill`,
`FreshnessLabel`, `Theme`, and existing semantic status colors. It does not
introduce a second design-token register.

Domain content stays in its product directory. Each participating feature owns
a small preview view that maps its existing model into the shared card:

- `DashboardQuickPreview`;
- `EventQuickPreview`;
- `SessionQuickPreview`;
- `FlagQuickPreview`;
- `ErrorQuickPreview`;
- `InsightQuickPreview`;
- `TraceQuickPreview`.

There is deliberately no universal array of arbitrary labels and values. A
shared frame gives the interaction consistency, while feature-owned composition
keeps domain meaning, formatting, and tests close to their source models.

## Surface Content

### Dashboards

Immediate content: title, description when present, pinned/template state, and
last refresh. Enriched content: tile count plus at most three textual tile
summaries in dashboard order. An insight tile shows its title and cached
headline when the existing render model exposes one; otherwise it shows title
and display kind. Text, button, widget, and unknown tiles contribute to the
count but are not previewed as results. The list endpoint does not return
tiles, so the base card never invents a count. The preview does not attempt to
reproduce a dashboard grid or make individual tiles interactive.

### Events

Event name, timestamp, distinct identity, current URL when present, and a small
set of at most four scalar properties already carried by the event row model.
The selection follows the existing event-detail property ordering after
removing values already shown in the header. Large objects and arrays are
described by shape rather than recursively rendered. Sensitive-looking
property keys follow the same display/redaction policy as the existing event
detail.

### Sessions

Person or distinct identity, start path, relative time, duration versus active
time, clicks, keypresses, console errors, web/mobile source, playability, and
the existing one-line Replay Vision digest or friction/outcome signal when it
has already been loaded.

Quick Preview never requests snapshot sources, replay blobs, event timelines,
diagnostics, or summary generation. It never constructs `ReplayLoader`,
`ReplayPlayerController`, or a WebKit view.

### Flags

Flag key/name, enabled or archived state, rollout percentage, condition-set
count, variant count, and multivariate state already present in the list model.
The preview is strictly read-only. It cannot toggle a flag, change rollout, or
expose a shortcut around the existing confirmation boundary.

### Errors

Issue name/message, active/resolved/suppressed state, user/session/occurrence
counts, last seen, and assignment/release/environment when the list model has
them. Resolve, suppress, and assignment mutations remain in the issue detail.

### Insights

Immediate content: title, description, saved-query kind, display type,
favorite/dashboard membership, modification time, and current cache state.
Enriched content is one semantic summary of the existing cached result. A
headline result shows its formatted value, a chart shows display kind and
series count, and a table shows row and column counts. Empty, pending, and
unsupported results state that condition without inventing a value. Quick
Preview never calls the blocking compute endpoint and never polls `lazy_async`
recomputation.

### Tracing

Trace identifier, operation, service, duration, status/error, and span count
from the list payload. Span trees and attributes remain in detail.

## Request and Cache Policy

Five surfaces make no preview request: Events, Sessions, Flags, Errors, and
Tracing.

Dashboards may make exactly one
`PostHogAPI.dashboard(projectID:dashboardID:refresh: false)` request. Insights
may make exactly one
`PostHogAPI.insight(projectID:insightID:refresh: false)` request. Both routes ask
PostHog for cached results and pass through GetHog's existing `ResponseCache`.
They never use `lazy_async`, `blocking`, or a follow-up polling request.

The feature root owns each enrichment store so structural remounts can reuse a
completed value or join the same in-flight load. Store identity includes:

- PostHog host/region;
- project ID;
- authentication session ID;
- object kind;
- object ID.

Each load receives a generation token. A changed project, credential, object,
or newer activation invalidates the old generation, and a late response cannot
publish into the current preview. Repeated activation of the same scoped object
joins the existing flight. Activating a different object cancels the previous
wait. Cancellation is a normal lifecycle event and is not shown as an error.

The base card is independent of enrichment state and appears immediately.
Completed responses remain useful to the existing detail route through
`ResponseCache`, so preview followed by open does not knowingly pay twice.

No request starts from row creation, scrolling, `onHover`, gaze, pointer
movement, search result creation, or speculative prefetching.

## State and Failure Behavior

The card has one stable outer composition. Only its enrichment section changes:

- **Base:** immediate row-derived content.
- **Loading:** base content plus a small "Loading cached details…" status.
- **Loaded:** base content plus cached-result enrichment and honest freshness.
- **Unavailable:** base content plus a quiet "More details unavailable" line.
- **Stale:** last successful enrichment remains visible with its last-updated
  time and a refresh-failed label.

A preview failure never becomes an alert, full-card error, navigation blocker,
or automatic retry loop. The in-app Open action remains available. Closing and
reopening may retry under the feature store's ordinary cache and flight rules.

Permission failures use the same quiet unavailable state; Quick Preview does
not instruct the user to change credentials for information that remains
available in the normal detail flow.

## Accessibility and Layout

- The source row remains a normal `NavigationLink` or existing selection
  control with its current hit target and label.
- No essential information or action exists only in Quick Preview.
- Preview content exposes a concise combined accessibility label in logical
  reading order; menu actions have object-specific labels.
- Dynamic Type through AX5 changes horizontal facts into a vertical flow and
  allows meaningful text to wrap rather than truncate.
- Long identifiers and paths use the existing monospaced, middle-truncating or
  wrapping conventions appropriate to their feature.
- Status is always stated in text; color is supplementary.
- The system context-menu transition supplies motion. GetHog adds no preview
  animation, and Reduce Motion receives no custom transition.

## Data Flow

1. A main feature list loads its ordinary rows exactly as it does today.
2. The row constructs its feature-owned preview from the already loaded model.
3. An intentional context-menu activation mounts the preview card.
4. Events, Sessions, Flags, Errors, and Tracing stop there.
5. Dashboard or Insight preview asks its root-owned store to load the scoped
   object with `refresh: false`.
6. The store returns a completed scoped value, joins an in-flight request, or
   starts one cache-aware request.
7. The preview updates only its enrichment section if the response still owns
   the active generation.
8. Choosing Open routes through the screen's existing in-app selection or
   navigation model. No parallel router is introduced.

## Testing and Verification

Test-first coverage will include:

- shared card content order, status text, long-value formatting, and Dynamic
  Type layout decisions;
- one pure content-adapter suite for each of the seven first-wave surfaces;
- request-spy proof that Events, Sessions, Flags, Errors, and Tracing issue zero
  preview requests;
- endpoint, category, and `refresh: false` proof for Dashboard and Insight;
- one-request behavior, same-scope flight joining, completed-value reuse,
  cancellation, project/auth/object invalidation, and stale-response rejection;
- Dashboard and Insight loading, loaded, unavailable, and stale states while
  base content remains visible;
- Sessions proof that preview activation never reaches snapshot sources, replay
  blobs, timeline queries, summary generation, or WebKit construction;
- Flags proof that preview exposes no mutation action;
- row-menu proof that touched surfaces expose in-app Open and omit PostHog web
  actions;
- deterministic synthetic demo content for every preview state;
- focused iPhone and iPad XCUITest journeys for long-press, preview content,
  dismissal, and subsequent ordinary in-app navigation;
- rendered compact/regular-width, light/dark, AX5, long-text, loading, failure,
  unplayable-session, and stale-cache states;
- Mac proof that the custom preview is absent while in-app context actions
  remain available.

After source or project membership changes, run `xcodegen generate`. Serialize
Xcode commands in the checkout, report nonzero executed test counts, and run
the focused unit and UI suites before the complete affected app gate. Run
`git diff --check` and the public-tree privacy gate before committing the
implementation. All fixtures, screenshots, identifiers, and documentation
examples remain deterministic and fictional.

## Success Criteria

- Every eligible preview displays useful base content immediately.
- Only Dashboard and Insight can spend a request, with at most one cached-result
  request for one deliberate activation.
- Preview followed by detail reuses cached data where the existing client cache
  permits it.
- No preview triggers recomputation, polling, replay data, WebKit, or a write.
- All preview actions stay inside GetHog.
- Existing tap, selection, navigation, split-view, new-window, and accessibility
  behavior remains intact.
- Pages whose current row is already the decision surface remain unchanged.

## Out of Scope

- A universal preview on every row, card, tile, or nested detail item.
- Hover-triggered, gaze-triggered, or speculative network activity.
- Hardware Force Touch or 3D Touch behavior.
- An interactive replay thumbnail or miniature detail screen.
- Production mutations from a preview, including flag, issue, survey, or
  experiment changes.
- Removing every web fallback from GetHog; this change removes external actions
  only from the list-row menus it replaces.
- watchOS, tvOS, widgets, complications, Top Shelf, and App Intents.
- The second-wave candidate surfaces until the first-wave interaction has
  passed rendered and behavioral verification.
