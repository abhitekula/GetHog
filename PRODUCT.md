# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios, macos, visionos, tvos, watchos

## Users

PostHog users — product engineers, PMs, founders — with a question that cannot
wait: is the dashboard moving, what did this session do, is the flag on. They
arrive briefly, often mid-context, on iPhone, iPad, Mac, Vision Pro, Apple TV,
or Apple Watch, and they already
know PostHog's concepts; the app never has to teach analytics, only answer
fast.

## Product Purpose

A native iPhone, iPad, and Mac client for checking PostHog work wherever the
question arises: dashboards, events, people, sessions and web replay, feature
flags, and the long tail of secondary surfaces (errors, SQL, warehouse,
pipelines, and more). Deliberately narrow, cache-aware, and honest about
surfaces it does not yet render. Success is the two-minute check — finished,
trusted, and closed.

Mac is a first-class adaptive client, not an iPad port: its native source-list
shell adapts its detail content to the available window width, while Settings,
commands, menu-bar presence, and tear-off windows follow desktop conventions.
Vision is a spatial catalog over the same shared screens, TV is a curated
read-mostly shell for the living room, and Watch is a glanceable metrics,
flags, health, and activity client with its own query budget.

GetHog is publicly available for iPhone and iPad on the
[App Store](https://apps.apple.com/us/app/gethog/id6798921061) as an open-source,
unaffiliated community project. The Mac, Vision, TV, and Watch shells build
from the same source but are not App Store listed. The design bar is that a stranger assumes a
design team shipped it. Open source is a delivery constraint, not just a
licence: every committed asset — illustrations, marks, icons — ships in a
public repository and must be original work the project can licence.

## Positioning

The native, private, honest PostHog companion:

- **Native, not wrapped** — SwiftUI end to end, adaptive iPad and Mac split
  views, native Mac windows and commands, widgets, App Intents, Dynamic Type,
  VoiceOver. No web views except the replay renderer, which is offline-only by
  policy.
- **Private by architecture** — no backend, no telemetry of its own; the API
  key lives in the device Keychain (or in memory for a verification launch)
  and requests go only to the user's PostHog host.
- **Honest about limits** — rate budgets, unsupported insight kinds, missing
  scopes, and stale caches are explained on screen in plain language rather
  than hidden. The writing is a product asset, confirmed by two independent
  design reviews.
- **Deliberately third-party** — an independent community project. The accent
  is a deep teal chosen away from PostHog's blue/orange for trademark
  distance; the app must never read as first-party.

## Voice

Explanatory, honest, specific. Explains limitations instead of hiding them,
teaches a concept only where it is needed, and names the recovery path.
American English (matches the product it is a client of).

## Brand register

Confirmed: **quiet craft, warm details.** Operate-mode discipline — data stays
calm and scannable; personality lives in the marks, illustrations, motion, and
voice, never in the data's way. The incumbent visual world (warm cream ground,
near-white cards, deep teal accent, warm ink ramp, hedgehog-quill signal
grammar, drawn product marks, branded illustrations) is the identity to
complete, not replace.

## Durable constraints

- Swift 6 strict concurrency; `Theme` and `SeriesPalette` tokens instead of
  literal colors; feature code stays in its product directory.
- All committed fixtures, screenshots, and examples are synthetic; the fixture
  privacy gate enforces this. Live-data screenshots stay in ignored `build/`.
- Demo mode is deterministic and is the only data source for UI tests and
  screenshots.
- API respect: shared rate budgets are spent carefully (no per-keystroke
  server search, caches, single fetch per screen); writes to the live
  workspace are rare, explicit, and confirmed.
- Accessibility is load-bearing: Dynamic Type through AX5, VoiceOver rotors,
  measured contrast (the ink ramp exists because system labels failed
  measurement).
- Reduce Motion is honored wherever motion is added.

## Open decisions

- Marks for product areas outside the four PostHog families (warehouse, logs,
  pipelines…): none exist yet; treated as a design gap, not filled by
  stretching the existing four.
