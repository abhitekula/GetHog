# Session Replay Interactions Design

## Goal

Make GetHog's session replay useful as a primary mobile experience rather than
only as a compact preview. A viewer can expand the replay, generate the same
kind of AI summary available in PostHog, see the summary's key moments on the
scrubber, and move through a recording without the current delayed response.

The work covers four outcomes:

1. Tapping the replay stage, or its explicit expand control, opens an in-app
   full-screen player.
2. A session without a stored AI summary offers an action to generate one.
3. Summary key events appear as semantic markers on the replay scrubber, like
   the supplied PostHog reference.
4. Scrubbing gives responsive preview feedback and begins buffering a remote
   target while the drag is still in progress.

## Constraints

- `project.yml` remains the project source of truth.
- Swift 6 strict concurrency and the existing `Theme` palette apply.
- Replay assets remain offline. The embedded player must not fetch scripts,
  styles, or page resources at runtime.
- Replay and summary data remain in memory only. No response body, recording,
  identifier, or generated summary is written to fixtures, screenshots,
  documentation, logs, or other retained artifacts.
- Every new committed fixture and UI-test value is deterministic and synthetic.
- The existing timeline, console, and network panes remain usable if either the
  replay renderer or summary generation fails.
- PostHog's API is authoritative for generation. GetHog does not run an LLM or
  construct summary prose locally.

## Chosen Approach

Keep the native SwiftUI transport and layer semantic markers over its existing
slider. This preserves the current native accessibility, speed, skip-inactive,
and playback behavior. Replacing the slider with a custom gesture control would
provide more styling freedom but would recreate focus, keyboard, VoiceOver, and
scroll-gesture behavior. Restoring rrweb's web controller would most closely
copy PostHog's desktop UI, but would undo the existing boundary in which WebKit
only renders replay pixels and SwiftUI owns interaction.

Full-screen playback uses a second, short-lived renderer booted from an
in-memory replay archive. A SwiftUI full-screen cover cannot move the existing
`WKWebView` safely between view hierarchies, and a fresh renderer cannot boot
from `ReplayLoader.pending` because pending events are deliberately drained.
Retaining decoded events for the lifetime of the session detail screen provides
one source from which the expanded renderer can start without a second network
download. The compact renderer pauses while the expanded renderer is active.

## Components

### Replay event archive

`ReplayLoader` retains each parsed `SnapshotEvent` in chronological order in
addition to its existing pending queue. The archive is read-only outside the
loader and is cleared by `reset` or when the detail screen is released. It is
never persisted or logged.

The compact player continues to drain pending batches as it does today. The
full-screen player receives a snapshot of the archive when presented and then
tracks an archive cursor so it can submit each later suffix exactly once as the
loader advances; it does not compete for the compact player's pending queue. It
starts at the compact player's current time and speed. On dismissal, the compact
player seeks to the expanded player's final time and restores the pre-expansion
playing state.

### Full-screen presentation

The replay stage becomes a button-like element with the accessibility hint
"Opens the replay full screen." An expand button remains visible in the replay
header so the action is discoverable without relying on the stage tap. Both
routes present the same full-screen cover.

The cover contains the replay stage, the native transport, current buffering
state, and a clear Close button. It does not duplicate the summary, event
timeline, console, or network panes. Rotation and iPad resizing call the
existing rrweb resize bridge. Dismissing the cover tears down only its web view
and controller.

### AI summary generation

`PostHogAPI` adds a typed request for:

`POST /api/projects/{project_id}/session_summaries/create_session_summaries_individually/`

with the JSON body `{ "session_ids": [sessionID] }`. This is the documented
individual-generation endpoint and accepts a personal API key with
`session_recording:read`. The team summary configuration is optional server
context, so GetHog does not need to retrieve or edit it.

`SessionSummaryStore.State` gains a generating state distinct from loading an
already stored summary. In the absent state, the card shows "Generate AI
summary." A tap starts one generation request, disables duplicate submission,
and explains that PostHog is generating the result. When the request succeeds,
the store reloads the canonical single-session summary endpoint rather than
trusting a second response shape as the durable record.

Generation errors remain inside the summary card and offer Retry. Permission,
availability, payment, rate-limit, and ordinary HTTP failures use the existing
`PostHogError` descriptions. Leaving the screen cancels the client task; the
documented endpoint does not expose cancellation of server work to PAT clients,
so the UI does not claim that server-side generation was cancelled.

Demo transport answers the generation request with a synthetic success for the
known no-summary recording, then serves a deterministic generated-summary
fixture through the existing detail route. Production and demo behavior use the
same store state machine.

### Key-event markers

A small pure model converts `SessionSummaryDetail.chapters.flatMap(\.events)`
into sorted replay markers. Each marker contains a stable event identifier, a
replay-relative offset, a short label from the model's event description, and a
semantic kind:

- exception: critical tint;
- confusion or abandonment: warm accent;
- other key action: regular accent.

Absolute key-event timestamps are rebased against `ReplayLoader.replayStart`.
`milliseconds_since_start` is only the fallback, matching the existing chapter
seek rule. Events without either usable time are omitted. Duplicate event IDs
are collapsed, offsets are clamped to the playable duration, and ordering is
stable.

The transport draws thin marker ticks inside the scrubber track. The most
recent marker at or before the playhead is active until the next marker; its
label appears in a compact, line-limited callout above the track. Markers are
supplementary to the accessible chapter and key-moment content already below
the player. The ticks do not become overlapping tiny buttons. The slider's
accessibility value includes the active key-event label, and custom accessibility
actions move to the previous and next marked moment.

No summary means no markers. Generating or loading a summary updates the marker
layer without rebuilding the replay renderer.

### Responsive scrubbing

The current transport changes `scrubPosition` during a drag but calls rrweb
only after the drag ends. That makes the stage appear frozen, while a target
beyond the initial buffer does not even request coverage until release.

A dedicated scrub coordinator isolates high-frequency gesture state from the
large replay detail view. On drag start it records whether playback was active
and pauses once. During the drag it:

- updates the native thumb immediately;
- coalesces preview seeks to at most one every 120 milliseconds;
- previews only positions already covered by the replay buffer;
- calls `ensureCoverage` immediately when the thumb moves beyond that buffer;
- never resumes playback for an intermediate preview.

On release it performs one exact seek. If the target is buffered, it restores
the pre-drag play/pause state. If the target is still remote, the thumb and
callout remain at the requested position, the transport reports buffering, and
the exact seek occurs as soon as coverage arrives. A new drag supersedes an
older pending target.

The implementation will measure fetch, parse, WebKit append, and rrweb seek
latencies separately before changing chunk sizes or prefetch policy. Those
policies remain unchanged unless evidence identifies them as an additional
bottleneck.

## Data Flow

1. `SessionDetailView` concurrently loads the event timeline, stored summary,
   and initial replay coverage.
2. `ReplayLoader` parses snapshot ranges off the main actor, appends them to its
   in-memory archive, and publishes pending batches to the compact player.
3. A stored or newly generated `SessionSummaryDetail` produces marker values
   from key events and the replay origin.
4. `PlayerTransportBar` reads duration, buffered coverage, current/pending
   position, and marker values. Drag events go to the scrub coordinator.
5. Expansion pauses the compact controller, boots the expanded controller from
   the archive, and seeks it to the compact playhead.
6. Dismissal copies the expanded playhead back, tears down the expanded web
   view, and restores the prior playback state.

## Error Handling

- Missing replay assets, mobile-only recordings, empty snapshots, and streaming
  failures retain the existing notices and PostHog escape hatch.
- Full-screen presentation is available only after the compact player is ready.
  A renderer failure closes the cover with an explanation while preserving the
  session screen.
- A generation failure never replaces an existing summary. Duplicate taps are
  ignored while one request is active.
- Marker derivation tolerates missing timestamps, missing descriptions, and
  malformed ordering by omitting unusable markers and sorting the rest.
- A seek beyond available data has a visible buffering state and is not silently
  clamped to the end of the current buffer.

## Testing and Verification

Test-first coverage will include:

- endpoint method, path, body, category, and PAT-compatible request shape;
- summary store transitions for absent, generating, generated-and-reloaded,
  permission failure, rate limit, and retry;
- deterministic demo generation without any live retained value;
- marker timestamp rebasing, fallback offsets, semantic kinds, deduplication,
  clamping, active-marker selection, and empty-summary behavior;
- scrub coalescing, pause/resume preservation, immediate coverage requests,
  pending-target replacement, and exact final seek;
- replay archive ordering, reset behavior, full-screen boot snapshot, and
  compact/expanded playhead handoff;
- accessibility labels/actions and minimum hit targets for expand and close;
- an XCUITest journey that generates a summary in demo mode, observes markers,
  expands the replay, scrubs it, closes it, and confirms the compact playhead
  retained the full-screen position.

Verification will run `xcodegen generate` if project membership changes, the
focused GetHogKit and app-unit tests with nonzero executed counts, focused replay
UI tests on iPhone 17, and `git diff --check`. A broader suite will be reported
separately if any pre-existing fixture-privacy failure remains.

## Out of Scope

- Editing PostHog's session-summary configuration or custom tags.
- Group summaries, focus-area prompts, feedback, or training-data enrollment.
- Persisting replay snapshots or AI summaries outside PostHog.
- Replacing the event timeline, console, or network diagnostics.
- Changing organisation-wide rate-limit budgets without measured evidence.
