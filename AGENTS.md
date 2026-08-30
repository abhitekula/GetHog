# Repository guidance

## Structure

GetHog is a native SwiftUI app for iPhone, iPad, Mac, Apple Vision Pro,
Apple TV, and Apple Watch with no backend.
`GetHogKit/` contains the UI-free authentication, networking, API-model,
insight-rendering, and replay-parsing package. App code lives in
`GetHog/Sources/`, the WidgetKit extension in `GetHogWidgets/`, and deterministic
demo data in `GetHog/Resources/DemoData/`. Widgets read the shared cache and do
not call PostHog directly.

The Mac is a second shell over the same screens, not a port: `GetHogMac/Sources/`
holds only what is Mac-shaped — the sidebar shell, the menu bar, the commands,
the Settings scene — and `GetHogMacWidgets/` is its widget extension. Anything
both platforms draw stays in `GetHog/Sources/` behind `#if os(macOS)`.

Vision is a spatial catalog over those shared screens; TV is a curated,
read-mostly focus shell; Watch is a glanceable metrics, flags, health, and
activity client with its own query budget. `GetHogUI/` holds presentation
primitives shared across shells. `GetHogVision/`, `GetHogTV/`, and
`GetHogWatch/` hold only platform-shaped roots and adaptations. Their widgets
and Top Shelf extension read the shared snapshot and never call PostHog.

`project.yml` is the source of truth; `GetHog.xcodeproj` is generated with
XcodeGen 2.46.0 or newer. Its guarded `postGenCommand` temporarily makes the
legacy watch embed configuration-aware (XcodeGen issue #1613): Debug uses
Xcode 26's local-install `PlugIns/` destination, while Release keeps the App
Store `Watch/` layout. If that guard fails, inspect the generated phase instead
of weakening the check or editing the project by hand. Tests
live beside each target, including `GetHogVision/{Tests,UITests}`,
`GetHogTV/{Tests,UITests}`, and `GetHogWatch/{Tests,UITests}`.

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
`GetHogScreenshots` scheme for visual sweeps. Do not pass `-derivedDataPath`.
Report nonzero executed test counts, not just exit status.

The new platform unit suites use their corresponding schemes and simulator
destinations. Their rendered UI suites go through the same count-checking
wrapper:

```bash
xcodebuild test -project GetHog.xcodeproj -scheme GetHogVision \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -only-testing:GetHogVisionTests
xcodebuild test -project GetHog.xcodeproj -scheme GetHogTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)' \
  -only-testing:GetHogTVTests
xcodebuild test -project GetHog.xcodeproj -scheme GetHogWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -only-testing:GetHogWatchTests
PLATFORM=vision scripts/run-ui-tests
PLATFORM=tv scripts/run-ui-tests
PLATFORM=watch scripts/run-ui-tests
```

The Vision, TV, and Watch unit targets use Swift Testing. Count the
`Test run with N tests` result; the adjacent `Executed 0 tests` is their empty
XCTest shell, just as it is for `GetHogMacTests`.

Serialize `xcodebuild` invocations in one checkout: the schemes share default
DerivedData and concurrent builds can lock its database. A WatchConnectivity
simulator pair does not prove delivery; the final hand-off and complication
check needs a paired physical Apple Watch. DEVELOPMENT.md carries the full
platform matrix, Release compile checks, and surface-specific traps.

The Mac builds and tests from the same generated project, and the third command
is the Release compile-check — the half no Debug build covers, and the only one
signing would otherwise gate:

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS'
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' \
  -only-testing:GetHogMacTests
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO
```

`GetHogMacTests` is Swift Testing, so its count is the `Test run with N tests`
line; the `Executed 0 tests` beside it is the empty XCTest shell around it and
is normal. `GetHogMacUITests` additionally needs an unlocked screen — a locked
one hands the automation layer nothing and fails every test at launch, before an
assertion. DEVELOPMENT.md carries the rest of the Mac-specific traps.

`xcrun simctl` is not a route to automated verification. Booting and mutating a
simulator out of band is how a run stops being reproducible, and the test
targets need none of it: `xcodebuild` manages the device lifecycle, and
anything a launch has to know travels in a target's `launchEnvironment`.

It **is** the route to authorized manual live testing, which needs a channel
the test targets do not have. Two facts leave no alternative: `GETHOG_API_KEY`
builds an `InMemoryTokenStore` that dies with the process, deliberately, so no
credential is persisted for a later launch to find; and the iOS Simulator MCP's
`launch` action accepts no arguments and no environment, so it cannot supply
one either. Driving a live, authenticated app — iPad multitasking and window
resizing especially, which no XCUITest can arrange — therefore starts with

```bash
SIMCTL_CHILD_GETHOG_API_KEY=$(grep GETHOG_API_KEY .env.local | cut -d= -f2-) \
  xcrun simctl launch <udid> app.gethog.GetHog
```

`SIMCTL_CHILD_`-prefixed variables are inherited through the shell into the
launched process, so the key never appears in `argv` and never reaches a
process listing. Read it from an untracked file — `.env*` and `*.pat` are
already ignored — and keep it out of logs, commits, and fixtures. Screenshots
of live data stay under `build/`, which is ignored; only synthetic images are
ever committed.

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
`scripts/run-ui-tests` prints both console formats as witnesses but takes its
authoritative pass, fail, skip, expected-failure, and total counts from the
xcresult summary. It rejects a missing, unreadable, internally inconsistent, or
zero-test result regardless of `xcodebuild`'s exit status; verified against
`-only-testing:` a suite that does not exist, where `xcodebuild` exits 0.

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
