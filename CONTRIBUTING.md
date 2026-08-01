# Contributing to GetHog

Thanks for helping make a useful phone companion for PostHog.

## Before you start

Open an issue before beginning a large feature, architectural change, or new
API surface. A short discussion prevents duplicated work and gives maintainers
a chance to agree on scope. Small, self-contained bug fixes and documentation
improvements can usually go straight to a pull request.

Read [DEVELOPMENT.md](DEVELOPMENT.md) and follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Making a change

- Keep commits focused and use clear, imperative subjects.
- Use Swift Testing for package and unit coverage; use XCTest for rendered UI
  and accessibility behavior.
- Add a regression test for a bug or a contract-changing behavior when practical.
- Run the relevant commands and report their nonzero executed test counts in
  the pull request.
- Run `scripts/verify-public-tree` before asking for review.
- Include a privacy-safe screenshot for a UI change when it improves review.

`project.yml` is authoritative. Regenerate the Xcode project instead of
hand-editing it.

## Privacy and examples

Every committed example must be synthetic: fixtures, demo data, test output,
screenshots, issue attachments, and documentation alike. Do not commit API
keys, access tokens, customer identifiers, raw account exports, or screenshots
that show real analytics data. Use reserved example domains in fabricated URLs.

If an API contract needs investigation, record only the stable shape needed by
the app and cover it with fictional fixture data.

## Pull requests

Use the pull request template. Explain the user-visible effect, risks, request
cost when applicable, tests and counts, and any follow-up work. Keep unrelated
cleanup out of the change so it is easier to review and revert.
