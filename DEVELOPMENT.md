# Development

## Prerequisites

- Xcode with an iOS simulator installed.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Swift, included with Xcode.

## Build graph and local commands

`project.yml` is the source of truth. Generate `GetHog.xcodeproj` after a
change to it or after adding project files; do not edit the generated project.

```bash
xcodegen generate
swift test --package-path GetHogKit
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

## Architecture

`GetHogKit/` is the UI-free Swift package for authentication, networking,
PostHog API models, insight render models, and replay parsing. `GetHog/`
contains the SwiftUI app and local demo resources. `GetHogWidgets/` reads the
shared cache and must not call PostHog directly.

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
for UI tests, screenshot generation, and public examples. Fixture updates must
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
