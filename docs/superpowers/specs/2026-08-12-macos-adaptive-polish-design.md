# GetHog macOS Adaptive Hardening — Design

**Date:** 2026-08-12
**Status:** Approved by delegated product/design authority
**Scope:** The macOS app shell, every shared screen as rendered on macOS,
replay expansion, native window behavior, Settings, and macOS widgets.

## Problem statement

The current Mac shell treats every window as regular width and nests each
screen's navigation inside a `TabView(.sidebarAdaptable)` sidebar. Live CUA
verification at 640×480, 800×600, 1,000×700, 1,280×820, and 2,048×1,280 found
that this creates three systemic failures:

1. narrow windows retain sidebar + list + detail simultaneously and crush the
   work area instead of drilling into detail;
2. all tab roots remain modifier owners, allowing toolbar and search state to
   leak from one destination to another and confusing the native sidebar
   command; and
3. the shared macOS shims turn list spacing into a no-op and replay expansion
   into a tiny sheet.

Native full screen itself works through the green control and View menu, but
the layout merely stretches. Window restoration can also place a previously
saved frame beyond a changed display's visible bounds.

## Product and visual direction

GetHog remains a quiet, warm, data-first native analytics client. This is an
Operate surface: hierarchy, scanability, native behavior, and truthful state
outrank visual novelty. The existing cream ground, near-white surfaces, ink
ramp, deep-teal accent, SF Symbols, and shared `Theme` tokens remain the visual
world. The redesign removes structural and density mistakes rather than
rebranding the app.

The Mac is a second shell over shared screens, not a scaled iPad. At narrow
widths it behaves as a focused Mac window: one work pane at a time, native Back
navigation, keyboard/menu routes, and an optional source-list sidebar. At wide
widths it uses list/detail and multi-column arrangements. Full screen increases
usable measure and card width before increasing item count.

## Approaches considered

### 1. Native source-list shell with adaptive screen topology — selected

Replace only `MacRootView`'s `.sidebarAdaptable` `TabView` with one outer
`NavigationSplitView`. Its sidebar is a native source list grouped by the five
`AppTab.sections`; only the selected destination is mounted. Measure the actual
detail-column width and inject `.compact` below 720 pt and `.regular` at or
above 720 pt into the shared roots. Their existing compact push navigation and
regular split layouts remain the implementation authority.

This removes nested sidebar ownership, stale toolbar/search modifiers, and the
forced-regular lie while retaining shared behavior and selection state through
`OpenDetails`. It is the smallest root-cause fix that is genuinely Mac-shaped.

### 2. Patch the existing `TabView`

Keep `.sidebarAdaptable`, inject width, clear search opportunistically, and
work around sidebar commands. This preserves SwiftUI's tab customization but
keeps all destination roots alive and leaves modifier ownership nondeterministic.
Rejected because it treats each observed symptom separately.

### 3. Enforce a large minimum window

Keep the current three-column topology and prevent widths below roughly
1,100 pt. Rejected because it directly conflicts with ordinary macOS windowing,
split-screen use, smaller displays, and the user's request.

## 1. Shell and navigation

`MacRootView` owns one `NavigationSplitView` with a 190–260 pt source-list
sidebar. Search is a utility row above the product sections. Analyze and
Monitor start expanded; Data, Experiment, and Workspace are collapsible and
their expansion state persists. All 34 product destinations remain reachable
from the sidebar and the Go menu; Settings remains exclusively in the Settings
scene.

Only `selectedTab`'s content is present. This gives toolbar, title, and
`.searchable` ownership to the visible screen and makes switching screens a
deterministic state transition. The selected destination persists with
`@SceneStorage`. Go-menu and deep-link routing continue to write that same
selection.

The detail host reads its actual width:

- **compact:** less than 720 pt — list/detail roots use their existing
  in-window push topology and Back button;
- **regular:** 720 pt or wider — roots that own a split container keep their
  list/detail presentation; other roots remain in a `NavigationStack`.

The threshold is based on content measure, not total window width or device.
With the source list visible, an 800 pt window therefore gets a focused compact
screen; hiding the sidebar can make the same window regular when the content
truly has room. Width changes preserve `OpenDetails` selection. Opening a
dashboard or recording in a separate window remains an explicit secondary
command, never the default narrow-width behavior.

## 2. List density and visual rhythm

Mac list cards receive a real 6 pt visual gap (3 pt inset on each adjoining
row background), while iOS/iPadOS retain their current denser inset. This is a
shared modifier so Events, People, Sessions, Insights, Errors, Notebooks, Max,
Renders, and long-tail row libraries cannot drift back to touching cards.

Rows retain their information hierarchy and semantic colors. No new nested
cards are introduced. Template cards use a larger Mac minimum width so full
screen produces fewer, more readable columns rather than six narrow tiles.
Wide overview pages cap prose-like measure or form balanced columns when their
content supports it; they do not simply stretch text and whitespace.

Mac controls use desktop control sizing. The 44×44 pt fingertip floor remains
on iOS/visionOS/tvOS, while macOS gets a 28×28 pt pointer target unless a
specific control is intentionally larger.

## 3. Replay expansion

On macOS, “Expand replay” opens a dedicated, resizable native replay window at
1,100×760 pt with a 640×480 minimum. The window supports minimize, zoom, the
green full-screen control, View → Enter Full Screen, and normal red-button
closure. It hosts the existing `ExpandedReplayView` and the same in-memory
`ReplayLoader`, so no duplicate API request is introduced.

Playback position, speed, and playing/paused intent hand off into the window
and back to the inline player exactly once on every close path. iOS and
visionOS retain their immersive cover. The macOS `fullScreenCover`→`sheet`
compatibility shim is removed so no future call can silently recreate the
470×147 failure.

## 4. Native window behavior

The main window defaults to 1,200×780 pt and remains freely resizable down to
560×420 pt. The app does not solve layout by locking a large minimum.

At launch, when a window becomes main, and when display parameters change, an
AppKit placement policy clamps ordinary windows into the nearest screen's
visible frame. It preserves size when possible, shrinks only when the window is
larger than the display, and never moves a native full-screen window. This
prevents restored windows from becoming partially unreachable after resolution
or monitor changes.

Native File → New Window, Close, Minimize, Zoom, Move & Resize, Return to
Previous Size, sidebar toggle, toolbar customization, Settings, About, and
dashboard/recording tear-offs remain first-class acceptance paths.

## 5. Settings and sidebar preferences

Settings keeps its four native panes and shared section content. The obsolete
“Reset Sidebar Arrangement” control is replaced by “Reset Sidebar Sections,”
which restores the default expanded/collapsed groups for the new source list.
The Settings window must remain usable at its system-managed size; text and
forms use native control sizing and avoid expanding empty panes merely to fill
the window.

## 6. Widgets

The Metric, Health, and Feature Flag widgets keep their existing families:
three Metric, three Health, and two Flag variants. They remain snapshot-only;
the widget extension carries no network-client entitlement. Gallery previews,
real installation, native size changes, edit/configuration, deep-link opening,
fresh/stale/never-synced states, empty-project state, and unshared Debug state
are acceptance paths.

The teamless ad-hoc Debug build is expected to say that it cannot share data.
Signed Distribution verification must prove that the app and extension resolve
the same App Group and that a refreshed app snapshot appears in an installed
widget. Distribution entitlement correctness is an acceptance gate, not
something demo previews can prove.

## 7. Accessibility, keyboard, and hardening

- Every sidebar row exposes its title and selected state to VoiceOver.
- Tab order traverses sidebar, toolbar, visible content, and detail without
  entering hidden destinations.
- Back, Escape, Command-W, Command-N, Command-comma, Command-R, Command-1…9,
  sidebar toggle, and replay Space/arrow shortcuts are verified.
- Long synthetic names, emoji, CJK/RTL text, empty collections, no matches,
  loading, network failure, unauthorized/forbidden, rate-limited, and stale
  states are exercised through deterministic launch environments or unit
  seams. Live PAT verification remains read-only.
- Light, dark, increased contrast, Reduce Motion, keyboard-only, and VoiceOver
  names are checked in the final rendered pass.

## 8. Verification contract

Implementation uses red/green tests for every defect class. Completion needs
all of the following current-state evidence:

1. nonzero `GetHogMacTests`, `GetHogMacUITests`, `GetHogTests`, and
   `GetHogKit` test counts with zero failures;
2. Debug and unsigned Release macOS builds;
3. privacy and fixture gates plus XcodeGen regeneration when project metadata
   changes;
4. deterministic CUA screenshots of every Mac destination at 640×480,
   800×600, 1,000×700, 1,280×820, and native full screen on the normal VM
   resolution;
5. live PAT smoke coverage of every destination without persisting or logging
   the credential;
6. native window/menu/replay/Settings/tear-off behavior; and
7. all eight widget gallery variants plus installed-widget resize, edit,
   deep-link, honest unshared state, and signed shared-data behavior when a
   valid signing identity is available.

Live screenshots remain under ignored `build/`. Only deterministic synthetic
artifacts may be committed.
