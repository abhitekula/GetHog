# Task 9 — Quick Preview interaction verification

Date: 2026-08-27
Reviewed base: `6a2fff58a0bb352ae283439d6eb81a36881ac18d`
Scope: tests and test helpers only; no production feature or demo-transport fixture was changed.

## Owned result

- `GetHogUITests/QuickPreviewInteractionTests.swift` covers Dashboard, Insight, Event, Session, Flag, Error, and the fixture-gated Trace journey. Each runnable journey long-presses a real row, verifies the system Preview host and semantic card fact, verifies the object-specific in-app action, excludes actionable Open in PostHog/Copy link controls, dismisses to the same list, and proves ordinary activation still opens in-app detail.
- Sessions cover the already-loaded Replay Vision digest and the unplayable mobile recording.
- `GetHogUITests/DemoLaunch.swift` adds prefix/semantic row queries and the measured iOS 26.5 Preview-host fallback.
- `GetHog/Tests/QuickPreviewRenderingTests.swift` renders Dashboard and Insight loading, loaded, unavailable, and stale states, plus Event, Session, Flag, Error, and Trace metadata cards. It exercises 320pt/520pt, light/dark, accessibility5, and deliberately long fictional content; Dashboard/Insight AX5 geometry is taller than ordinary type at 320pt.
- `GetHogMac/UITests/MacNavigationTests.swift` preserves Dashboard row tear-off, replaces recording Copy-link coverage with Open Session/Open in new window and external-action absence, and adds Event, Dashboard, and Insight menu assertions. It does not require a custom Mac preview.
- No fixture, `project.yml`, or generated-project change is included. `xcodegen generate` completed successfully and left generated files clean.

## RED → GREEN evidence

Focused REDs were captured before the corresponding test harness changes:

1. The initial interaction suite did not compile because `DemoLaunch.element(in:identifierStartingWith:)` did not exist (exit 65, 0 tests). The helper was then added.
2. Dashboard executed 1 test and failed because the authored preview identifier was not exposed by the iOS 26.5 context-menu host. AX/video evidence showed a generic `Preview` host, the complete combined semantic card label, and `Open Dashboard`. A second RED showed a status-bar coordinate did not dismiss. The semantic-host fallback and dimmed-list dismissal made the isolated Dashboard run GREEN: 1/1.
3. The initial rendering test did not compile because `QuickPreviewRenderingTests.render` did not exist (exit 65). After adding the ImageRenderer harness and the remaining concrete states/cards, the focused suite was GREEN: `Test run with 3 tests in 1 suite passed`.
4. Event initially did not compile because the semantic row helper did not exist (exit 65, 0 tests). After adding it, Event was GREEN: 1/1.
5. Sessions executed 1 test and failed only while returning from `Alex Example`; video showed the iPhone back control was icon-only. The corrected navigation helper made Sessions GREEN: 1/1, including loaded digest and unplayable mobile coverage.
6. Flags executed 1 test and failed at the list title (`Feature Flags` versus authored `Flags`). The corrected expectation made Flags GREEN: 1/1.
7. Tracing executed 1 test and failed exactly at `The demo Tracing list offered no real trace row.` The journey now skips only when the authored `No spans in the last 24 hours` terminal state is present, and will run automatically when a deterministic trace fixture exists.
8. The first installed-iPad run executed 7 tests and exposed three test-driver REDs: regular-width Flag/Error split selection consumed the first long press, the detail toolbar's obscured PostHog control polluted an app-global absence query, and Sessions selected Share instead of returning to a list that was already visible. Video/AX evidence drove test-only fixes. Flag, Error, and Sessions then passed 1/1 individually, and the complete installed-iPad run passed.

No product defect requiring production-source modification was found.

## Verification matrix

Commands were serialized and used shared DerivedData (no `-derivedDataPath`).

### Rendered suite

```text
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/QuickPreviewRenderingTests
```

Result: PASS — Swift Testing `3 tests in 1 suite`, 0 failures.

### iPhone 17 UI wrapper

```text
WORKERS=1 scripts/run-ui-tests GetHogUITests/QuickPreviewInteractionTests
```

Result: PASS — authoritative xcresult total 7; 6 passed, 1 skipped, 0 failed. The skip is the demonstrated Trace fixture gap.
Bundle: `build/TestResults/GetHogUITests-20260827-052932.RnY2zM/Test.xcresult`

### Required iPad Air 11-inch (M4) wrapper

```text
DESTINATION_NAME='iPad Air 11-inch (M4)' WORKERS=1 scripts/run-ui-tests GetHogUITests/QuickPreviewInteractionTests
```

Environment failure: Xcode exit 70, authoritative total 0. The requested simulator is not installed. Xcode listed iPad Pro 13-inch (M5) as the only available iPad destination.
Bundle: `build/TestResults/GetHogUITests-20260827-051913.6dMIzU/Test.xcresult`

Supplemental installed-iPad proof:

```text
DESTINATION_NAME='iPad Pro 13-inch (M5)' WORKERS=1 scripts/run-ui-tests GetHogUITests/QuickPreviewInteractionTests
```

Result: PASS — authoritative xcresult total 7; 6 passed, 1 skipped, 0 failed.
Bundle: `build/TestResults/GetHogUITests-20260827-053109.AYBv3h/Test.xcresult`

### Shared-platform builds

```text
xcodebuild build -project GetHog.xcodeproj -scheme GetHogVision -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
xcodebuild build -project GetHog.xcodeproj -scheme GetHogTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)'
```

Result: PASS — `BUILD SUCCEEDED` for visionOS and tvOS.

### Focused Mac UI suite

```text
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' -only-testing:GetHogMacUITests/MacNavigationTests
```

Environment failure before test launch: 0 tests executed. Xcode reports `GetHogMac has entitlements that require signing with a development certificate`. This is a signing gate, not a locked-screen pass or a test result. The unrelated dirty entitlement files were preserved and not staged. A non-signing compile check completed with `TEST BUILD SUCCEEDED`:

```text
xcodebuild build-for-testing -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Scoped Trace fixture gap

The actual Tracing UI reaches its documented empty state because `DemoTransport` returns empty `columns` and `results` for `PostHogAPI.traceSpans`, query kind `TraceSpansQuery`; `DemoTransportTests.refusedQueryKindIsEmpty` currently pins that behavior. Consequently there is no real row to long-press on either phone or tablet.

Smallest proposed separately owned change: add one deterministic fictional `TraceSpansQuery` response routed by `DemoTransport`, with columns `uuid`, `trace_id`, `span_id`, `parent_span_id`, `name`, `service_name`, `status_code`, `timestamp`, `end_time`, `duration_nano`, `is_root_span`, `matched_filter`, and `attributes`; then update the transport contract test to prove that exact query resolves only that trace fixture. No such change was made in this task.

## Ruling candidate — iOS 26.5 context-menu accessibility

Observed on iOS 26.5: SwiftUI's context-menu host can replace the preview subtree in XCUITest with a system element labelled `Preview` and one child carrying the card's complete combined semantic label. The stable authored `gethog.quick-preview.*` identifier is then not observable through UI automation even though the card and menu are visibly present. The interaction suite therefore asserts the generic Preview host, complete object semantics, and object-specific action. Authored identifiers remain covered by adapter/rendering/lifecycle tests. This is platform hosting behavior, not a production workaround.

On regular-width iPad, an unselected NavigationLink can also consume the first deliberate long press as split-view selection; the row remains visible and a second deliberate long press opens the same authored context menu. The test driver permits that single measured retry and uses no timing sleeps.

## Privacy and scope review

- All new data is deterministic and fictional (`example.com`, fictional people, observatories, and synthetic identifiers).
- Tests use condition polling; the only fixed duration is the deliberate 1.0-second long press.
- No credentials, customer payloads, network fixtures, production feature source, `project.yml`, or generated project file changed.
- Unrelated pre-existing edits were preserved: `GetHog/Tests/AnnotationComposerTests.swift`, `GetHogMac/Support/GetHogMac-Distribution.entitlements`, and `GetHogMac/Support/GetHogMac.entitlements`.
