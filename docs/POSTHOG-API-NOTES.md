# PostHog API notes

This note records stable integration contracts used by GetHog. The app's
deterministic fixtures exercise these shapes; for service behavior and current
endpoint details, consult the [official PostHog API documentation](https://posthog.com/docs/api).

## Authentication and scope

GetHog connects with a user's personal API key. The app verifies the required
scopes during onboarding and presents a specific missing-permission state
instead of treating every authorization failure as a generic network error.

## Response shapes

- Collection endpoints can be paginated or can return a bare array. Decode each
  endpoint's documented shape rather than assuming one shared envelope.
- Insight query results are polymorphic. Dispatch rendering from the declared
  query kind instead of inferring it only from similarly shaped fields.
- Optional and nullable fields are part of the contract. Preserve the
  distinction between an absent value, `null`, and a present empty collection.
- Session replay data is isolated behind its own loader. If its format cannot
  be parsed, the session timeline remains available and the UI shows a clear
  fallback state.

## Client behavior

Network calls are cache-aware and rate-limit conscious. Treat server-provided
pagination and truncation signals as part of rendering correctness; do not
silently present a partial result as a complete one. Keep any new contract in a
synthetic fixture and add decoding coverage before depending on it in the UI.
