# GetHog support

GetHog is a native iPhone and iPad client for checking PostHog dashboards,
events, sessions and replay, and feature flags. It is an independent
community project, not affiliated with or endorsed by PostHog.

## Getting help

- **Bugs and feature requests** — open an issue at
  <https://github.com/abhitekula/GetHog/issues>. Please include what you
  expected, what happened, and your device and iOS version. **Never include
  your PostHog API key**, and check screenshots for real project data before
  attaching them.
- **Questions about the app** — the [README](README.md) covers what the app
  does and how to connect; [DEVELOPMENT.md](DEVELOPMENT.md) covers building it
  yourself.
- **Email** — <support@automorphism.app>, for anything that does not fit a
  public issue.

## Common questions

**The app asks for an API key. Where do I get one?**
Create a PostHog [personal API key](https://posthog.com/docs/api/personal-api-keys)
with the scopes listed in the app's onboarding. GetHog stores it in your
device's Keychain and talks only to the PostHog host you choose.

**Can I try the app without a PostHog account?**
Yes — "Explore the demo" on the welcome screen runs the whole app on bundled
fictional data, with no account and no network requests.

**A screen says my key is missing a scope.**
The screen names the scope it needs. Add it to your personal API key in
PostHog's settings, then pull to refresh.

**Something in PostHog isn't shown in the app.**
GetHog is deliberately narrow and honest about surfaces it does not yet
render; [ROADMAP.md](ROADMAP.md) tracks current limits and directions.

## Privacy

The app collects nothing and has no backend; see the
[privacy policy](PRIVACY.md).
