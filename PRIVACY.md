# GetHog privacy policy

**Effective: August 5, 2026**

GetHog is a native iPhone and iPad client for PostHog, published by
Automorphism, LLC. It is an independent community project and is not
affiliated with, endorsed by, or maintained by PostHog. This policy describes
what the app does with data, which is short to describe because the app is
built not to have any of it.

## What GetHog collects

Nothing. GetHog has no backend, no analytics, no telemetry, no crash
reporting, no advertising, and no tracking of any kind. Automorphism, LLC
operates no servers for this app and receives no data from it — not your API
key, not your analytics data, not even the fact that you installed it.

## Where your data goes

When you connect your own PostHog account, the app talks directly from your
device to the PostHog instance you chose — PostHog Cloud US, PostHog Cloud EU,
or your self-hosted deployment — over HTTPS. Nothing passes through anyone
else. What PostHog does with your account and its data is governed by your
agreement with PostHog, described in the
[PostHog privacy policy](https://posthog.com/privacy).

## Your API key

Your PostHog personal API key is stored in your device's Keychain and never
leaves the device except as the authorization header on requests to the
PostHog host you chose. Revealing the stored key in Settings can be gated
behind Face ID; the Face ID check happens entirely on the device, as it always
does. Signing out deletes the key from the Keychain along with every cache
the app has written.

## Data kept on the device

To make screens fast and to render widgets, the app caches responses from
your PostHog instance on the device, including a small shared snapshot that
home screen widgets read. These caches exist only on your device, are
readable only by GetHog, and are deleted when you sign out.

## Demo mode

"Explore the demo" runs the app on fictional, hand-authored data bundled with
it. Demo mode makes no network requests and stores no credential.

## Children

GetHog is a professional tool for inspecting product analytics and is not
directed at children.

## Changes

If a future version of the app changes what this policy describes, the policy
will change with it in the same repository, where its full history is
public: <https://github.com/abhitekula/GetHog>.

## Contact

Questions about this policy can be raised as an issue at
<https://github.com/abhitekula/GetHog/issues>, or sent to
<support@automorphism.app>.
