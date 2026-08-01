# Signal Grammar final fix report

Date: 2026-08-01
Commit: `Harden Signal Grammar adaptive layouts`

## Outcome

Both final-review findings are resolved.

- `CardHeader` now treats the branded quill stitch as optional decoration. A
  long title at a narrow ordinary-size width receives the usable space first;
  the stitch remains at ordinary widths where both fit. The existing Theme
  tokens, title/subtitle limits, and accessibility representation are retained.
- Dashboard, Events, and Flags now opt into a vertical `StatStrip` reading order
  at accessibility Dynamic Type sizes. The default horizontal strip is
  unchanged for ordinary sizes and all non-opted-in call sites.
- Dedicated iPad Pro 11-inch AX5 UI assertions and screenshot cases cover all
  three overview scenes. Sessions was not duplicated because its accepted AX5
  topology coverage already exists.

## Evidence-led fix sequence

### CardHeader

The first rendered run executed 5 Swift Testing tests in the component suite and
reported 1 expected failure: the narrow branded and unbranded headers differed.
The ordinary-width preservation check already passed. After the fitting-priority
change, the same component suite executed 5 tests with 0 failures.

The final combined rendered regression run executed 11 tests in 2 suites with 0
failures. The parameterized object-glyph test expanded to 12 passing cases.

### Regular-width iPad AX5 overviews

The first three topology tests passed because they proved only section-level
vertical order. Visual inspection of their captures revealed the missing
assertion: the overview `StatStrip` children still shared one oversized row, so
Dashboard's trailing metrics and Events' trailing metrics were clipped at the
detail-pane edge.

The strengthened tests require every metric to follow the previous metric in
reading order. Before the product fallback, all 3 test cases failed as expected:
Dashboard failed at Computed and Generated, Events failed at Kinds, People, and
Reaching back, and Flags failed at Enabled. After the opt-in AX stack, the same
3 tests executed with 0 failures in 16.246 seconds.

The final screenshot run executed 3 tests with 0 failures in 16.697 seconds:

- `build/Screenshots/iPad Pro 11-inch (M5)/ax5/dashboards.png`
- `build/Screenshots/iPad Pro 11-inch (M5)/ax5/events.png`
- `build/Screenshots/iPad Pro 11-inch (M5)/ax5/flags.png`

All three images were inspected at original resolution. Their detail panes keep
identity, metrics, and following sections in a clear top-to-bottom order with no
overlap or right-edge metric clipping. The split-view master lists remain
independently scrollable and wrap heavily at AX5; this existing compact master
behavior was not changed.

## Verification

- `SignalGrammarComponentTests` plus `AccessibilitySizeFitTests`: 11 tests in 2
  suites, 0 failures, `TEST SUCCEEDED`.
- Focused Dashboard/Events/Flags iPad AX5 topology: 3 tests, 0 failures,
  `TEST SUCCEEDED`.
- Focused Dashboard/Events/Flags iPad AX5 captures: 3 tests, 0 failures,
  `TEST SUCCEEDED`.
- Minimal `GetHog` iPhone 17 simulator build: `BUILD SUCCEEDED`.
- `git diff --check`: clean.

## Files

- `GetHog/Sources/Common/Components.swift`
- `GetHog/Sources/Common/DesignKit.swift`
- `GetHog/Sources/Dashboards/ProjectOverview.swift`
- `GetHog/Sources/Events/EventsOverview.swift`
- `GetHog/Sources/Flags/FlagsOverview.swift`
- `GetHog/Tests/SignalGrammarComponentTests.swift`
- `GetHogUITests/SignalGrammarAccessibilityTests.swift`
- `GetHogUITests/Screenshots/Screenshot.swift`
- `GetHogUITests/Screenshots/RootScreenshotTests.swift`
- `.superpowers/sdd/2026-08-01-usefulness-first-signal-grammar/final-fix-report.md`

## Unresolved

No unresolved issue remains in the two requested findings. This pass did not
re-evaluate the separate retained-fixture privacy failure documented in the Task
9 report, and no fixture, demo-data, screenshot, or documentation payload from a
live PostHog environment was added.
