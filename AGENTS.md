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

## Standards

Use Swift 6 strict concurrency and four-space indentation. Keep feature code
in its product directory, use `Theme` and `SeriesPalette` instead of literal
colors, and write behavior-focused Swift Testing or XCTest coverage.

All committed fixtures, demo data, screenshots, examples, and documentation
must be synthetic. Never commit credentials, customer data, or copied API
payloads. Preserve unrelated worktree changes and keep commits focused.
