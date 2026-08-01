# GetHog

The PostHog companion I wanted on my phone, built during a weekend that got slightly out of hand.

> GetHog is an independent community project. It is not affiliated with, endorsed by, or maintained by PostHog.

## Why this exists

I wanted to check a dashboard, inspect a replay, or sanity-check a flag without
opening a laptop. The sensible answer was probably “use the website.” The
weekend-project answer was “build the native app I want to use myself,” and here
we are.

**Warning:** side projects may expand when exposed to SwiftUI, analytics APIs,
and the dangerous thought, “replay parsing can’t be *that* much work.”

## What it does

GetHog is a native iPhone and iPad client for checking the PostHog work that
cannot wait for a laptop: dashboards, events, sessions and replay, and feature
flags. It keeps the app deliberately narrow, cache-aware, and honest about
surfaces it does not yet render.

- Browse saved dashboards and their supported insights.
- Inspect events, people, sessions, and web-session replay.
- Review feature flags and change a flag only after confirmation.
- Connect to PostHog US Cloud, EU Cloud, or a self-hosted instance.

## See it without an API key

Demo mode uses deterministic, hand-authored fictional data. It is the data
source for UI tests and screenshots, so you can explore the app or work on its
interface without a PostHog account, project, or credential.

## Getting started

Get Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), then generate
the project from its source of truth:

```bash
brew install xcodegen
xcodegen generate
open GetHog.xcodeproj
```

To connect your own account, create a PostHog [personal API key](https://posthog.com/docs/api/personal-api-keys)
with the scopes shown in onboarding. GetHog stores it in the device Keychain;
it has no backend. See [DEVELOPMENT.md](DEVELOPMENT.md) for builds, tests, demo
mode, and credential handling.

## Architecture

```text
GetHogKit/          UI-free Swift package: auth, networking, API models,
                    insight rendering, and replay parsing
GetHog/Sources/     SwiftUI application, organized by product surface
GetHogWidgets/      WidgetKit extension using the shared cache only
GetHog/Resources/   Deterministic demo resources and bundled replay player
```

`project.yml` is authoritative; `GetHog.xcodeproj` is generated. The app keeps
networking and decoding in `GetHogKit` so those contracts can be verified apart
from the UI.

## Project status

GetHog is a community project under active development. The core dashboard,
event, session, replay, and flag workflows are present; unsupported insight
types fall back to clear guidance rather than pretending to be complete.

It is not a replacement for the PostHog web app. Some API surfaces are still
unimplemented, replay availability depends on the source recording, and a phone
is not the right place for every analytics task. See [ROADMAP.md](ROADMAP.md)
for current limits and directions.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md),
[DEVELOPMENT.md](DEVELOPMENT.md), and the [Code of Conduct](CODE_OF_CONDUCT.md)
before opening a change. Examples, fixtures, screenshots, and attachments must
be synthetic and privacy-safe.

## License

GetHog is available under the [MIT License](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependencies.

<!-- PostHog folks: if you made it this far, I accept feature requests and suspiciously well-timed job interviews. My calendar can probably survive one. -->
