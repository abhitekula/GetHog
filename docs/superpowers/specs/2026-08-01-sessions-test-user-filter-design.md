# Sessions Test-User Filter Design

## Context

GetHog's Sessions screen already sends a `SessionRecordingFilter` to PostHog for each first page and subsequent page. PostHog's session-recordings endpoint also accepts `filter_test_accounts`, which applies the project's configured internal and test-user definitions. GetHog currently documents that field but does not model or send it.

The PostHog web console exposes this behavior as “Filter out internal and test users.” GetHog should expose the same server-side narrowing without attempting to reproduce PostHog's project configuration locally.

## Goals

- Add an off-by-default Sessions toggle that excludes internal and test users when enabled.
- Keep the result correct across first loads, pagination, filter changes, clearing, and saved-filter application.
- Make the active narrowing visible in the filter badge and summary.
- Preserve the existing unfiltered request when the toggle is off.

## Non-goals

- Editing the project's test-account definitions from GetHog.
- Guessing whether a recording belongs to a test user from its email or other client-visible properties.
- Persisting this toggle as an app preference independently of the current Sessions filter state.
- Adding the toggle to replay collections, whose contents are fixed rather than query-backed.

## Filter Model and API Contract

`SessionRecordingFilter` gains a Boolean state named `filterTestAccounts`, defaulting to `false`.

When the value is `true`, `queryItems` emits:

```text
filter_test_accounts=true
```

When it is `false`, the query item is omitted. This keeps an untouched filter byte-identical to the existing request and avoids sending a redundant false value.

The enabled value counts as one active narrowing. `isNarrowed` therefore becomes true, `clear()` restores the value to false through the existing whole-filter reset, and the filter's query items automatically change `SessionsStore.requestSignature`. The current `.task(id:)` path will then cancel the previous first-page load and replace the paging state with results for the new filter. `loadMore` will carry the same query item through the existing shared filter.

## User Interface

The existing `SessionFilterSheet` gains a People section containing a native SwiftUI toggle labeled:

> Filter out internal and test users

The section footer explains that the definitions come from the project's PostHog settings. The control binds directly to `filter.filterTestAccounts`; it owns no duplicate view state and introduces no separate persistence.

This placement keeps all Sessions narrowings in one mobile-appropriate surface. It avoids crowding the already populated toolbar and follows the sheet's existing `Form` and `Section` conventions. The native toggle provides the expected switch semantics and accessibility behavior without custom styling.

When enabled, `ActiveFilterSummary` includes the concise clause “excluding test users.” It participates in the existing three-clause cap, so accessibility text sizes do not produce an unbounded summary above the first row.

## Saved Filters

`SessionRecordingPlaylist.recordingFilter` reads the web console's legacy stored shape. It will translate `"filter_test_accounts": "true"` into `filterTestAccounts = true`. The string `"false"`, a missing value, and unrelated values leave the default false state unchanged.

Applying a saved filter continues to replace the Sessions filter as a whole. Query-backed saved filters therefore preserve their test-account choice; fixed collections continue to bypass `SessionRecordingFilter` entirely.

## Errors and Empty Results

No new error state is needed. The existing Sessions loading path already clears stale rows when a narrowed request fails and exposes the server error. A successful empty response uses the existing “No matching sessions” state because the enabled toggle makes the filter narrowed.

## Verification

Test-first coverage will prove these observable behaviors:

- An untouched filter remains silent and off by default.
- Enabling the option emits exactly `filter_test_accounts=true`.
- The option increments the active count, appears in the summary, and is removed by `clear()`.
- A saved filter containing the string `"true"` translates to the enabled model state and emitted query item; `"false"` remains disabled.
- `SessionsStore` sends the query item to the server and changes its request signature when the toggle changes.
- Existing package and Sessions screen tests remain green with nonzero executed test counts.

All test inputs and retained artifacts remain deterministic and synthetic.
