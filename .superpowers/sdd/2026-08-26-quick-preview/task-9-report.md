# Task 9 — Quick Preview interaction verification

Date: 2026-08-27
Fix-round base: `1b0e17e1260c20d711adcd9917608f33f6c55105`

## Result

- Dashboard, Insights, Events, Sessions, Flags, Errors, and Tracing now execute as seven required synthetic demo journeys on iPhone and regular-width iPad; none is skipped.
- Every journey long-presses a real row, accepts the authored preview identifier or the measured iOS 26.5 `Preview` host, verifies object semantics and an object-specific in-app Open action, proves zero `Open in PostHog` and `Copy link` controls inside the presented menu, dismisses to the same list, then relaunches cleanly and proves ordinary activation opens the target detail.
- Dashboard verifies enriched `7 tiles` and `Example weekly engagement pulse` facts. Insight verifies the enriched `Cached line chart, 2 series` fact.
- Sessions verify the already-loaded Alex Example Replay Vision digest and the unplayable Riley Example mobile recording. Ordinary activation requires the matching person navigation title as well as `gethog.session-detail-primary`, so an already-present generic detail cannot satisfy the test.
- The new deterministic `TraceSpansQuery` fixture produces one fictional three-span trace with one error. The exact route precedes the generic `TracesQuery` fallback, and its contract decodes through `TraceSpan` into the expected `TraceGroup`.
- Rendering coverage pins Dashboard/Insight loading, loaded, unavailable, and stale states plus representative metadata cards at 320pt/520pt, light/dark, accessibility5, and long fictional text. A compact long-content AX5 card must grow taller than a short ordinary card.
- All seven exact authored `gethog.quick-preview.*` identifiers are independently checked from constructed SwiftUI accessibility modifier graphs; no source grep is used.
- Mac test source was not changed in this fix round. The existing reviewed Dashboard tear-off, Session Open/Open in New Window, forbidden-action absence, and representative metadata/Dashboard/Insight menu assertions remain intact.
- `xcodegen generate` completed after adding the resource. Neither `project.yml` nor generated project files changed.

## RED to GREEN evidence

1. **Trace fixture contract:** the focused 70-test DemoTransport run executed the new contract and failed with empty columns, zero spans, and zero groups (exit 65). After adding `trace_spans.json` and routing exact `"kind":"TraceSpansQuery"` before `TracesQuery`, the same suite passed 70/70.
2. **Scoped forbidden actions:** Dashboard initially failed to compile because `DemoLaunch.contextMenu` did not exist (exit 65, zero tests). The helper now selects the system collection containing the object-specific action; both forbidden labels are asserted to have exactly zero matching buttons in that collection. Dashboard then passed 1/1.
3. **Authored-or-system host:** the first gate change failed to compile because `DemoLaunch.previewHost` did not exist (exit 65, zero tests). The helper now prefers an exposed authored identifier and otherwise returns the generic iOS 26.5 host.
4. **Enrichment facts:** Insight first executed and failed against an incorrect one-series expectation; the exposed semantic result was `Cached line chart, 2 series`. The corrected focused journey passed 1/1. Dashboard's enriched tile count/title focused journey also passed 1/1.
5. **Genuine ordinary activation:** the first clean-state assertion failed to compile because `DemoLaunch.relaunch` did not exist (exit 65, zero tests). The helper preserves demo arguments/environment while discarding split selection. Every journey now proves its target detail is absent before tapping and present afterward.
6. **All seven authored identifiers:** the new unit contract first failed to compile without its harness, then a hosted UIKit accessibility-tree attempt executed four tests and failed all seven identifiers because iOS returned an empty local AX tree. The final behavior contract evaluates each concrete view body and checks the authored accessibility modifier value; the focused rendering suite passed all identifier cases.
7. **Long-content growth:** the geometry case initially failed to compile because the short ordinary fixture did not exist. After adding the fictional short event, the rendering suite passed 5/5, including the height-growth assertion.
8. **Trace journey:** removing the former skip made Tracing a required interaction. With the exact fixture in place, its focused UI run passed 1/1 with `3 spans`, `1 error`, `Open Trace`, dismissal, and target-specific activation.
9. **Regular-width Insight semantics:** the first full installed-iPad run executed all seven and finished 6 passed/1 failed because the iOS 26.5 host froze Insight's initial summary label. A captured host tree proved enrichment was absent rather than mis-scoped. The condition-based remount reads the completed store state; focused Insight then passed 1/1 and the full iPad suite passed 7/7.

No production Quick Preview feature source was changed.

## Verification matrix

All commands were serialized and used shared DerivedData; none used `-derivedDataPath`.

### DemoTransport contract

```text
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/DemoTransportTests
```

PASS — Swift Testing `Test run with 70 tests in 1 suite passed` after the final catalog-owned UUID normalization.
Result: `~/Library/Developer/Xcode/DerivedData/GetHog-fjvkqllynybffkfvdazvsxihaaib/Logs/Test/Test-GetHog-2026.08.27_06-35-00-+0200.xcresult`

### Rendering and identifier contracts

```text
xcodebuild test -project GetHog.xcodeproj -scheme GetHog -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GetHogTests/QuickPreviewRenderingTests
```

PASS — the controller completed the exact post-normalization command with exit 0 and `TEST SUCCEEDED`; Swift Testing reports `Test run with 5 tests in 1 suite passed`, 0 failures.
Result: `~/Library/Developer/Xcode/DerivedData/GetHog-fjvkqllynybffkfvdazvsxihaaib/Logs/Test/Test-GetHog-2026.08.27_06-42-06-+0200.xcresult`

### iPhone 17 UI wrapper

```text
WORKERS=1 scripts/run-ui-tests GetHogUITests/QuickPreviewInteractionTests
```

PASS — authoritative xcresult: 7 passed, 0 failed, 0 skipped, total 7; elapsed 127s.
Result: `build/TestResults/GetHogUITests-20260827-062354.BWKJa3/Test.xcresult`

### Installed regular-width iPad Pro M5 UI wrapper

```text
DESTINATION_NAME='iPad Pro 13-inch (M5)' WORKERS=1 scripts/run-ui-tests GetHogUITests/QuickPreviewInteractionTests
```

PASS — authoritative xcresult: 7 passed, 0 failed, 0 skipped, total 7; elapsed 155s.
Result: `build/TestResults/GetHogUITests-20260827-062108.tAFwNi/Test.xcresult`

The requested `iPad Air 11-inch (M4)` was not installed; Xcode listed the installed regular-width destination as `iPad Pro 13-inch (M5)`, which is the destination used above.

### Resource-membership builds

```text
xcodebuild build -project GetHog.xcodeproj -scheme GetHogVision -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
xcodebuild build -project GetHog.xcodeproj -scheme GetHogTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)'
```

PASS — `BUILD SUCCEEDED` for both Vision and TV with the generated trace resource membership.

### Focused Mac UI suite

Exact command:

```text
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' -only-testing:GetHogMacUITests/MacNavigationTests
```

ENVIRONMENT FAILURE — exit 65 before test execution because `GetHogMac` has entitlements requiring a development certificate.
Result: `~/Library/Developer/Xcode/DerivedData/GetHog-fjvkqllynybffkfvdazvsxihaaib/Logs/Test/Test-GetHogMac-2026.08.27_06-27-50-+0200.xcresult`

Permitted nonpersistent fallback:

```text
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' -only-testing:GetHogMacUITests/MacNavigationTests CODE_SIGN_ENTITLEMENTS=/tmp/gethog-task9-empty-entitlements.plist CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

ENVIRONMENT FAILURE — the empty temporary entitlement/ad-hoc override built and launched `GetHogMacUITests-Runner`, but UI automation initialization failed with `System authentication is running`, `Authentication canceled` (exit 65, zero executed-test proof). This is a locked/authentication desktop failure, not a pass and not compile-only execution proof.
Result: `~/Library/Developer/Xcode/DerivedData/GetHog-fjvkqllynybffkfvdazvsxihaaib/Logs/Test/Test-GetHogMac-2026.08.27_06-28-20-+0200.xcresult`

The user-owned entitlement files were neither changed by this task nor staged.

### Remaining iPad Air M4 gap

`iPad Air 11-inch (M4)` remains unavailable. The prior exact wrapper attempt exited 70 with authoritative total zero, and current Xcode destinations still list only the iPad Pro 13-inch M5. No simulator was created or mutated out of band.

## Privacy conformance

The ownership expansion authorized the evidence-backed catalog edit. The four added suffixes map to deterministic fictional Quick Preview tests: 710 is the default Insight preview authority; 711 and 712 are the old/new authority-fencing scopes; and 720 is the cached-detail boundary request scope. `trace_spans.json` is now declared as a demo-only fixture.

The real package privacy suite was then rerun:

```text
swift test --package-path GetHogKit --filter FixturePrivacyTests
```

PASS — `Test run with 25 tests in 1 suite passed`, 0 failures.

The dedicated catalog suite also passed:

```text
swift test --package-path GetHogKit --filter SyntheticFixtureCatalogTests
```

PASS — `Test run with 2 tests in 1 suite passed`, 0 failures.

## Ruling candidate — iOS 26.5 context-menu accessibility

Observed on iOS 26.5: SwiftUI's context-menu host can replace the authored preview subtree in XCUITest with a system element labelled `Preview`. The stable `gethog.quick-preview.*` identifier is then absent from remote UI automation even though the semantic card and menu are visible. UI tests therefore require either the authored identifier or this generic host, prefer the authored element when exposed, and independently assert complete card semantics plus the object-specific action. Exact authored identifier contracts remain pinned in behavior-level rendering tests.

On regular-width iPad, the system host can freeze Insight's first summary-only semantic snapshot while its cache request completes. A condition-gated remount exposes the completed enrichment without changing production behavior. An unselected split-view NavigationLink can also consume the first deliberate long press as selection; the test permits one measured retry while the row remains visible. These are platform-host behaviors, not production workarounds.

## Privacy and scope review

- `trace_spans.json` contains only deterministic fictional UUIDs, services, routes, timestamps, attributes, and synthetic concepts. No customer data, credential, or copied payload is present.
- Test data is likewise fictional (`example.com`, fictional people, observatories, and synthetic identifiers).
- New waits are condition polls. The only deliberate fixed interaction duration is the 1.0-second long press.
- Exact owned repo paths are `GetHogUITests/QuickPreviewInteractionTests.swift`, `GetHogUITests/DemoLaunch.swift`, `GetHog/Tests/QuickPreviewRenderingTests.swift`, `GetHog/Resources/DemoData/trace_spans.json`, `GetHog/Sources/App/DemoTransport.swift`, `GetHog/Tests/DemoTransportTests.swift`, and `GetHogKit/Tests/GetHogKitTests/Support/SyntheticFixtureCatalog.swift`; this report is also updated.
- Unrelated edits remain preserved and unstaged: `GetHog/Tests/AnnotationComposerTests.swift`, `GetHogMac/Support/GetHogMac-Distribution.entitlements`, and `GetHogMac/Support/GetHogMac.entitlements`.
