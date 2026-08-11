# Sessions Project Preferences and Filter Summary Alignment Design

## Context

The Sessions screen exposes a useful project-defined exclusion for internal and
test users, but the choice currently lives only in `SessionsStore.filter`. It is
lost when the app closes and is also carried indiscriminately while the same
screen instance switches projects. The active-filter summary has a separate
visual defect: its normal-size layout top-aligns a multi-line sentence with a
44-point Clear button, so the button's visible label sits below the sentence's
first line.

This design updates the earlier Sessions test-user-filter decision. Persistence
was explicitly out of scope there; it is now an approved requirement.

A whole-codebase state-lifetime audit covered all 326 Swift source files across
the app, shared packages, widgets, Watch, TV, Mac, and Vision targets. Of those,
115 own local or persisted state and 23 use a persistence primitive. The audit
found that the summary alignment defect is isolated, but it also established an
important storage rule: a numeric project id is not a complete namespace.
Project ids can repeat across US Cloud, EU Cloud, and self-hosted PostHog
instances. Every project-owned preference must therefore include both the
canonical PostHog host and project id.

## Goals

- Align the normal-size Clear label with the first text baseline of the active
  filter sentence without shrinking its hit target.
- Persist the Sessions choices that represent stable viewing preferences:
  internal/test-user exclusion, playable-only recordings, and sort order.
- Restore those choices independently for each PostHog host and project.
- Clear transient investigation state at a project boundary so a query from one
  project is never silently applied to another.
- Introduce a reusable, tested project-preference scope for later local
  preferences.
- Degrade safely when stored data is missing, malformed, or written by another
  app version.

## Non-goals

- Persisting person or URL searches, signal, date, duration, distinct ids, or
  clauses inherited from a saved filter. These describe a particular
  investigation rather than how the person generally wants Sessions displayed.
- Synchronizing preferences through iCloud, the App Group, widgets, Watch, or
  another device. No process outside the main app consumes these choices.
- Changing the server-side definitions of internal or test users.
- Folding unrelated storage migrations into this change. The audit follow-ups
  are recorded below.
- Persisting selected recordings, sheet presentation, expansion state, loading
  state, errors, or results.

## Persistence Scope

A small `ProjectPreferenceScope` value will contain:

- `projectID`
- `PostHogRegion`, whose resolved `host` distinguishes US, EU, and self-hosted
  installations

Its versioned key component will percent-encode the host using the same rule as
`FlagQuickToggle`, then append the numeric project id. Organization id is not
needed because PostHog project ids are instance-wide. `authSessionID` is
deliberately excluded: replacing or rotating a credential must not erase a
person's viewing preferences for the same host and project.

`ProjectPreferenceScope` will be app-local and reusable. It is not write
authority and must not be substituted for `FlagWriteScope`, which correctly
includes the authentication epoch for live mutations.

## Stored Sessions Value

`SessionsPreferences` will use injected `UserDefaults`, defaulting to
`.standard`, and store one versioned record per `ProjectPreferenceScope`. The
record contains only:

- `filterTestAccounts: Bool`, default `false`
- `playableOnly: Bool`, represented in the request filter as `source == .web`,
  default `false`
- `order`, default `.startTime`

The stored representation will use optional/version-tolerant fields. A missing
field receives its current default. An unknown order raw value defaults only the
order field rather than discarding valid Boolean choices. An unreadable record
defaults the complete value. Reading corrupt data must never trap or prevent the
Sessions screen from loading.

There is no legacy Sessions preference to migrate. The existing in-memory
filter remains an input only for the current process and is not copied into a
new project's stored value.

## State Ownership and Project Changes

`SessionsStore` remains the single owner of the effective
`SessionRecordingFilter`. It receives an injectable preferences store for
tests. One scope-activation operation will run synchronously before a request is
constructed:

1. If the scope is unchanged, keep the current transient investigation state.
2. If the scope changed, reset the whole filter, then apply the target scope's
   three durable choices.
3. Clear old rows and paging state using the existing project-boundary behavior.
4. Build the request signature and request from the now-correct effective
   filter.

The load identity and store's loaded scope will include the complete
host/project preference scope, not only the numeric project id. This keeps the
ordering invariant explicit even if a future authentication flow can replace a
region without reconstructing the screen.

Edits to the three durable controls are written immediately through the store;
edits to all other filter fields remain memory-only. Applying a saved playlist
is an explicit filter choice, so its test-user, playable-only, and sort values
become the active project's durable values while its other clauses remain
transient.

## Clear Semantics

"Clear" means clear constraints, not restore every Sessions control to factory
defaults. All three Clear entry points—the active summary, filter sheet, and
filtered-empty state—will:

- reset all narrowing fields, including the persisted test-user and
  playable-only choices;
- write those two disabled values for the current scope;
- preserve the current sort order and its stored value, because sorting does
  not narrow the answer and is intentionally excluded from `activeCount`.

This avoids a hidden reset of a control that the UI does not describe as an
active filter.

## Filter Summary Layout

At non-accessibility Dynamic Type sizes, the outer summary row will use
`.firstTextBaseline` alignment, following the existing `SectionEmptyState`
sentence/action pattern. The sentence's icon stays aligned to its first line,
the Clear button keeps `.minimumHitTarget()`, and the sentence continues to wrap
rather than truncate.

At accessibility sizes, the existing leading-aligned vertical stack remains.
Clear follows the complete sentence with normal spacing so a long explanation
does not wrap beneath a floating action. Accessibility labels and the
three-clause summary cap remain unchanged.

## Failure and Concurrency Behavior

Preference reads and writes are local and synchronous; they introduce no new
loading state. A defaults write failure cannot block a request—the current
in-memory choice remains effective for the running process.

Project activation must happen before the first suspension in a load. Existing
generation checks continue rejecting stale pages and first-page responses. The
generation's ownership comparison will use complete scope so a response from a
previous host/project cannot mutate the new scope's rows, loading flags, or
paging state.

## Verification

Implementation will be test-first and use isolated `UserDefaults` suites.
Coverage will prove:

- default values and round-trip restoration;
- independence between two project ids on one host;
- independence between the same project id on two hosts;
- credential/auth-session changes do not change the preference namespace;
- missing, unknown, and corrupt stored fields fall back safely;
- project activation clears transient fields and applies only the destination
  scope's durable values before a request is built;
- changing each durable control writes immediately, while transient controls do
  not write;
- applying a saved playlist updates only its durable projection in storage;
- all three Clear paths disable durable narrowings, clear transient
  constraints, and preserve sort order;
- the rendered normal-size summary aligns its sentence and Clear action while
  retaining at least a 44-by-44-point Clear hit target;
- the accessibility-size summary remains vertically ordered and untruncated;
- focused package, app, and UI tests finish with nonzero executed counts.

All fixtures and retained artifacts remain deterministic and fictional.

## Audit Follow-ups

The audit found three existing project-owned values whose current namespace is
too broad. They should be handled as a separate hardening change because each
needs its own migration and product semantics:

1. `SavedEventFilterStore` keys only by numeric project id. A legacy value
   cannot be copied to every host safely because its originating host is
   unknowable; migration needs a one-time ownership rule.
2. SQL Console history is global. Project-specific schema and query text can
   appear under another project and be rerun there.
3. Watch and Mac headline metric selections are global. Validation prevents
   most invalid displays, but it does not remember independent choices per
   project and equal ids can select unrelated metrics.

Several screens also have stable in-memory viewing choices that may benefit
from opt-in persistence: Error Tracking order/window/status, Heatmaps
window/lens, LLM Analytics range, Web Analytics window/breakdown/vital display,
Logs window/problems-only, Tracing window/errors-only, Ingestion Warnings
window/category, and Renders display filter. These should be designed
screen-by-screen. Free text, selected details, replay-local controls, composer
drafts, and one-off investigative filters should remain transient.

This Sessions change establishes the scoping primitive and lifetime rule those
follow-ups can reuse without broadening the current implementation.
