# Repository guidance

## Structure

GetHog is a native SwiftUI app for iPhone and iPad with no backend.
`GetHogKit/` contains the UI-free authentication, networking, API-model,
insight-rendering, and replay-parsing package. App code lives in
`GetHog/Sources/`, the WidgetKit extension in `GetHogWidgets/`, and deterministic
demo data in `GetHog/Resources/DemoData/`. Widgets read the shared cache and do
not call PostHog directly.

`project.yml` is the source of truth; `GetHog.xcodeproj` is generated. Tests
live in `GetHogKit/Tests/`, `GetHog/Tests/`, and `GetHogUITests/`.

## Commands

```bash
xcodegen generate
swift test --package-path GetHogKit
xcodebuild build -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests
```

Use `-only-testing:GetHogUITests` for rendered accessibility behavior and the
`GetHogScreenshots` scheme for visual sweeps. Do not use `xcrun simctl` or pass
`-derivedDataPath`. Report nonzero executed test counts, not just exit status.

For the UI target, prefer the wrapper — it runs across simulator clones and
checks the count for you:

```bash
scripts/run-ui-tests                                    # whole UI target
scripts/run-ui-tests GetHogUITests/TabBarCustomisationTests
WORKERS=1 scripts/run-ui-tests                          # serial, for reading a failure in order
DESTINATION_NAME='iPad Air 11-inch (M4)' scripts/run-ui-tests
```

**Parallel testing changes the log format, and the count rule above does not
survive it.** Measured on a 14-core machine, iPhone 17, the whole UI target:
**576s serially against 230s with four workers**, the same 73 test cases, and no
`ExclusiveRun` collisions — that lock keys on `SIMULATOR_UDID` and each clone
gets its own. But the output changes from

    Test Case '-[GetHogUITests.FooTests testBar]' passed (1.234 seconds).
    Executed 78 tests, with 5 tests skipped and 0 failures ...

to

    Test case 'FooTests.testBar()' passed on 'Clone 1 of iPhone 17 - ...'

with **no `Executed N tests` line emitted at all**. Every count grep written for
the serial format silently reports zero, which is indistinguishable from a
filter that named nothing — the exact failure the count rule exists to catch.
`scripts/run-ui-tests` counts both formats and fails on zero regardless of
`xcodebuild`'s exit status; verified against `-only-testing:` a suite that does
not exist, where `xcodebuild` exits 0.

Compilation is not the bottleneck: an incremental `build-for-testing` is ~2s,
against ~8–9s per UI test, which is app-launch dominated. Wait on conditions
with `DemoLaunch.wait(for:)` or `DemoLaunch.wait(until:)` rather than sleeping
through them with `pause` — though measure before claiming a saving, since most
of the wait is work that has to happen either way.

## Standards

Use Swift 6 strict concurrency and four-space indentation. Keep feature code
in its product directory, use `Theme` and `SeriesPalette` instead of literal
colors, and write behavior-focused Swift Testing or XCTest coverage.

All committed fixtures, demo data, screenshots, examples, and documentation
must be synthetic. Never commit credentials, customer data, or copied API
payloads. Preserve unrelated worktree changes and keep commits focused.
