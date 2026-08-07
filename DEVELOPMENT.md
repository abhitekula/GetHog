# Development

## Prerequisites

- Xcode with the iOS, visionOS, tvOS, and watchOS simulator runtimes used by
  the commands below.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 or newer
  (`brew install xcodegen`; verify with `xcodegen --version`).
- Swift, included with Xcode.

## Build graph and local commands

`project.yml` is the source of truth. Generate `GetHog.xcodeproj` after a
change to it or after adding project files; do not edit the generated project.

Generation currently contains one guarded XcodeGen 2.46 workaround. XcodeGen
still emits the watch-app embed into the legacy `Watch/` destination; the
`postGenCommand` in `project.yml` verifies that exactly one legacy phase exists
and rewrites it to Xcode 26's `PlugIns/` destination. If generation stops with
an `XcodeGen#1613 patch` error, do not weaken the counts or hand-edit the
project: inspect the generated phase and remove or revise the workaround only
when XcodeGen's output has actually changed.

```bash
xcodegen generate
swift test --package-path GetHogKit
swift test --package-path GetHogUI
xcodebuild build -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogTests
xcodebuild test -project GetHog.xcodeproj -scheme GetHog \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GetHogUITests
scripts/verify-public-tree
```

Report the executed test count for each test command. A zero-test result is not
verification, even when `xcodebuild` exits successfully. Run the
`GetHogScreenshots` scheme when making a visual change and inspect its generated
output locally; only verified synthetic screenshots may be added to the repo.

`scripts/verify-public-tree` checks the complete publishable file inventory,
then runs the schema-aware fixture and source privacy suite. Its own unsafe
corpus can be exercised with `scripts/verify-public-tree --self-test`.

## Building the Mac app

The macOS target builds and tests from the same generated project:

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS'
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' \
  -only-testing:GetHogMacTests
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:GetHogMacUITests
```

`GetHogMacTests` is a Swift Testing bundle, so its result is the
`Test run with N tests in M suites passed` line. The `Executed 0 tests` line in
the same log is the empty XCTest shell around it and is normal — read the
Swift Testing line, not that one.

Two traps are worth knowing before either command confuses you.

**A stale LaunchServices record launches the Mac app windowless.** The iOS and
macOS apps deliberately share one bundle identifier, `app.gethog.GetHog`, so a
record registered against an iOS build can capture a macOS launch: the process
starts, takes no window, and looks like a hung app rather than a
misregistration. Re-register the built product and it goes away:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /path/to/Build/Products/Debug/GetHog.app
```

The same cache is why a freshly-changed app icon can keep showing the old one
in the Dock; `killall Dock` after the `lsregister` clears that half.

**The Mac UI suite needs an unlocked GUI session.** A locked screen composites
nothing and hands the automation layer no elements, so every test in
`GetHogMacUITests` fails identically at launch with

```
Failed to activate application 'app.gethog.GetHog …' (current state: Running Background)
```

before reaching a single assertion. That signature means the screen, not the
code — do not chase it through the queries. Unlock the machine and re-run.
Unit tests, builds, and `build-for-testing` are all unaffected by the lock.

`GetHogMacUITests/MacSurfaceSweepTests` walks every sidebar screen and attaches
a full-screen photograph of each. Its narrow and wide passes are off by default;
turn them on with `TEST_RUNNER_GETHOG_SWEEP_SIZES=all` and export the images
from the result bundle with `xcrun xcresulttool export attachments`.

## Building the Vision, TV, and Watch apps

The three purpose-built shells use the same generated project and shared
packages as iOS and macOS. These destinations match the simulator models used
by the repository's visual sweeps:

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

The wrapper's xcresult summary is the authoritative UI-test count. A missing,
unreadable, or zero-test result bundle is a failure even if `xcodebuild` exits
successfully. Use `DESTINATION_NAME` to exercise the 40mm watch or another
installed runtime without changing the script.

`GetHogVisionTests`, `GetHogTVTests`, and `GetHogWatchTests` are Swift Testing
bundles, just like `GetHogMacTests`. Their nonzero count is the
`Test run with N tests in M suites passed` line; an `Executed 0 tests` line is
the empty XCTest shell and is not the target's count.

Do not run these `xcodebuild` commands concurrently in one checkout. They share
Xcode's default DerivedData database, and overlapping builds can fail with a
database lock before testing the app. This is why the final matrix is serial.

The WatchConnectivity simulator pair is useful for inspecting support,
pairing, activation, and queued-transfer state, but it is not acceptance
evidence for delivery. Complete the credential hand-off and complication
finale on a paired physical Apple Watch. A key waiting in WatchConnectivity's
durable outbox can briefly exist outside the Keychain; re-send and sign-out
cancel the old queued transfer before rotating or deleting the phone key.

Three visual acceptance limits are hardware-only. The Vision simulator cannot
prove Optic ID, and `XCUIScreen.main` currently produces a 1 x 1 black image
there; use the external simulator screenshot command for a sighted sweep rather
than attaching that black pixel as evidence. The TV simulator cannot prove a
physical Siri Remote or Type with iPhone. The Watch simulator cannot prove the
phone-to-watch delivery or a real complication refresh. Record those as
hardware gaps instead of translating simulator process launch into a pass.

Top Shelf intentionally returns no dynamic content before the TV app has
written a shared snapshot, allowing the system's static Top Shelf image to be
honest. Watch widgets and Top Shelf read the shared cache; neither surface calls
PostHog directly.

Release compile checks for every app shell require no signing identity:

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHog \
  -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -configuration Release CODE_SIGNING_ALLOWED=NO
xcodebuild build -project GetHog.xcodeproj -scheme GetHogVision \
  -destination 'generic/platform=visionOS' -configuration Release CODE_SIGNING_ALLOWED=NO
xcodebuild build -project GetHog.xcodeproj -scheme GetHogTV \
  -destination 'generic/platform=tvOS' -configuration Release CODE_SIGNING_ALLOWED=NO
xcodebuild build -project GetHog.xcodeproj -scheme GetHogWatch \
  -destination 'generic/platform=watchOS' -configuration Release CODE_SIGNING_ALLOWED=NO
```

## Architecture

`GetHogKit/` is the UI-free Swift package for authentication, networking,
PostHog API models, insight render models, and replay parsing. `GetHogUI/`
contains cross-platform presentation primitives without owning a platform
shell. `GetHog/` contains the shared SwiftUI product surfaces and local demo
resources. `GetHogMac/`, `GetHogVision/`, `GetHogTV/`, and `GetHogWatch/` are
native shells shaped for their platforms. Their widget and Top Shelf
extensions read the shared cache and must not call PostHog directly.

Saved event filters are user-authored and therefore not size-bounded. TV omits
that authoring surface: tvOS persists only about 500 KB of preferences, while
its other local storage is purgeable and cannot be the sole copy of user data.
Keep new unbounded content out of the TV defaults domain.

The app, package, widgets, fixtures, and UI tests intentionally stay in one
repository. They change as one product and share a single synthetic-data
contract, so splitting them would add versioning and coordination without an
independent release boundary. If `GetHogKit` later becomes a separately released
library with its own consumers and compatibility policy, that is the point to
reconsider a split.

Keep product-specific views and models in their feature directory. Use `Theme`
and `SeriesPalette` instead of literal colors. Swift uses strict concurrency;
make ownership and actor boundaries explicit rather than suppressing warnings.

## Demo mode and fixtures

Demo mode is deterministic and entirely fictional. It is the only data source
for UI tests, screenshot generation, and public examples, and it ships in
Release: "Explore the demo" on the welcome screen enters it at runtime
(`AppModel.enterDemo()`), which is how App Review and the curious see the app
without a PostHog credential. A runtime demo session never touches the
Keychain, the widget snapshot, or pending intent work — those belong to the
user's real workspace. Fixture updates must
preserve the declared catalog and include privacy regression coverage. Do not
add customer data, copied response bodies, credentials, non-reserved domains,
or personal details to fixtures, screenshots, test names, or documentation.

## Credentials and network access

Normal development and automated tests require no credential. For a manual
connection, enter your own PostHog personal API key through onboarding; it is
stored in the device Keychain and must never be committed or placed in a
screenshot. Keep local environment files and one-off probes untracked. When
investigating an API behavior, retain only durable field, type, nullability,
pagination, or enum contracts in a synthetic fixture or public note.

For a verification session against a real project, `GETHOG_API_KEY` and
`GETHOG_REGION` in the launch environment put a DEBUG build straight past
onboarding without storing anything: the credential goes into an in-memory
store and dies with the process. Supply them through a UI test's
`launchEnvironment`, or through `SIMCTL_CHILD_`-prefixed variables when the app
has to be driven by hand — see AGENTS.md for why that is the one sanctioned use
of `xcrun simctl`. `GETHOG_REGION` also accepts a full URL, so pointing it at an
unroutable address is how offline and connection-failure behavior gets
exercised without touching the simulator's network settings.

## App Store archive and signing

`DEVELOPMENT_TEAM` is deliberately empty in `project.yml`: this is a public
repository and a team id is an account detail, not a project fact. Supply it
on the command line at archive time instead — it never gets committed:

```bash
xcodebuild archive -project GetHog.xcodeproj -scheme GetHog \
  -destination 'generic/platform=iOS' \
  -archivePath build/GetHog.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<team id>
```

`-allowProvisioningUpdates` lets automatic signing register the four iOS
archive bundle ids — phone app, phone widget, Watch app, and Watch widget —
plus the `group.app.gethog` App Group and shared keychain access group under
that team on first archive. Upload the archive from Xcode's Organizer or with
`xcodebuild -exportArchive`.

### The Mac app's two entitlements files

`GetHogMac` cannot use one entitlements file, and the reason is the empty team
above. Either the App Group or the shared keychain access group, **alone**,
makes a macOS target refuse to build without a development certificate —
measured by adding each separately and building, and the failure comes before
any source is compiled:

```
error: "GetHogMac" has entitlements that require signing with a development
certificate.
```

iOS never met this because a Simulator build is not signed against a profile;
a macOS build always is. So the entitlements split along the axis the
constraint runs on, and `project.yml` selects by configuration:

| Configuration | File | Carries |
|---|---|---|
| Debug | `GetHogMac/Support/GetHogMac.entitlements` | sandbox, network client |
| Release | `GetHogMac/Support/GetHogMac-Distribution.entitlements` | the above plus the App Group and the shared keychain group |

A fresh clone builds and runs Debug with no certificate at all; Release is only
ever built with a team supplied on the command line, exactly as the archive
above does, so it carries both group memberships **by construction** rather
than by anybody remembering to add them back. Nothing in a Debug run misses
them: `KeychainTokenStore` defaults to no access group and `SharedSnapshotStore`
falls back to the app's own container.

To compile-check the Release half without a certificate — which is what CI and
a local sanity pass want, since signing is the only part that needs the team:

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO
```

The macOS App Group is spelled `$(TeamIdentifierPrefix)group.app.gethog`, with
the prefix that iOS forbids; `SharedSnapshotStore.appGroupIdentifier(teamIDPrefix:)`
is where that rule lives, so the two platforms name one container.

The upload-facing compliance lives in the repository already:
`GetHog/Resources/PrivacyInfo.xcprivacy` declares the required-reason APIs the
app uses, and `ITSAppUsesNonExemptEncryption` in `project.yml` answers the
export question (TLS only, exempt). If a change starts using a new
required-reason API — disk space, active keyboards, or another category — the
manifest must grow with it, or the upload is rejected with ITMS-91053. The
current file-timestamp declaration covers only app-container cache eviction;
disk-space or active-keyboard access would still require its own category and
approved reason.
